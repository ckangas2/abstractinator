"""Tests for tracker/snapshot_trials.py, with a fake API (no network)."""

import copy
import gzip
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import snapshot_trials as snap  # noqa: E402

snap.PAUSE_SECONDS = 0


def study(nct, status="RECRUITING", enrol=40, other_names=("Pexa-Vec",), pmids=(), verified="2026-10",
          updated="2026-10-01", locations=None):
    """A study shaped like a ClinicalTrials.gov API v2 record."""
    return {
        "protocolSection": {
            "identificationModule": {"nctId": nct, "briefTitle": "A  trial of JX-594"},
            "statusModule": {
                "overallStatus": status,
                "statusVerifiedDate": verified,
                "startDateStruct": {"date": "2024-03", "type": "ACTUAL"},
                "primaryCompletionDateStruct": {"date": "2027-01", "type": "ESTIMATED"},
                "completionDateStruct": {"date": "2028-01", "type": "ESTIMATED"},
                "studyFirstPostDateStruct": {"date": "2024-02-01"},
                "lastUpdatePostDateStruct": {"date": updated},
            },
            "sponsorCollaboratorsModule": {
                "leadSponsor": {"name": "SillaJen, Inc.", "class": "INDUSTRY"},
                "collaborators": [{"name": "B Org"}, {"name": "A Org"}],
            },
            "designModule": {"studyType": "INTERVENTIONAL", "phases": ["PHASE2", "PHASE1"],
                             "enrollmentInfo": {"count": enrol, "type": "ESTIMATED"}},
            "armsInterventionsModule": {"interventions": [
                {"type": "DRUG", "name": "Cemiplimab", "description": "x"},
                {"type": "BIOLOGICAL", "name": "Pexastimogene devacirepvec",
                 "otherNames": list(other_names), "description": "long text"},
            ]},
            "conditionsModule": {"conditions": ["Renal Cell Carcinoma", "Kidney Cancer"]},
            "outcomesModule": {"primaryOutcomes": [{"measure": "Safety", "timeFrame": "1 year"}]},
            "contactsLocationsModule": {
                "centralContacts": [{"name": "Jane Doe", "email": "jane@example.org"}],
                "locations": locations if locations is not None else [
                    {"facility": "Hospital A", "country": "United States",
                     "contacts": [{"name": "Site Lead", "phone": "555-0100"}]},
                    {"facility": "Hospital B", "country": "Korea, Republic of"},
                ],
            },
            "referencesModule": {"references": [{"pmid": p, "type": "RESULT", "citation": "c"} for p in pmids]},
        },
        "hasResults": False,
    }


class FakeAPI:
    """Serves pages per query; records calls. reject_fields mimics an API that refuses the field list."""

    def __init__(self, by_query, page_size=2, reject_fields=False, fail=()):
        self.by_query, self.page_size = by_query, page_size
        self.reject_fields, self.fail, self.calls = reject_fields, set(fail), []

    def __call__(self, params):
        self.calls.append(dict(params))
        q = params["query.term"]
        if q in self.fail:
            raise RuntimeError("HTTP 503 from ClinicalTrials.gov")
        if self.reject_fields and "fields" in params:
            raise snap.FieldsRejected("bad field")
        items = self.by_query.get(q, [])
        start = int(params.get("pageToken") or 0)
        page = items[start:start + self.page_size]
        out = {"studies": copy.deepcopy(page), "totalCount": len(items)}
        if start + self.page_size < len(items):
            out["nextPageToken"] = str(start + self.page_size)
        return out


def db_rows(db, sql, *args):
    con = sqlite3.connect(db)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


class Canonical(unittest.TestCase):
    def test_fields(self):
        r = snap.canonical(study("NCT01", pmids=("222", "111")))
        self.assertEqual(r["nct_id"], "NCT01")
        self.assertEqual(r["brief_title"], "A trial of JX-594")          # whitespace squeezed
        self.assertEqual(r["phases"], ["PHASE1", "PHASE2"])              # sorted
        self.assertEqual(r["enrollment_count"], 40)
        self.assertEqual(r["collaborators"], ["A Org", "B Org"])
        self.assertEqual(r["conditions"], ["Kidney Cancer", "Renal Cell Carcinoma"])
        self.assertEqual([i["name"] for i in r["interventions"]], ["Cemiplimab", "Pexastimogene devacirepvec"])
        self.assertEqual(r["interventions"][1]["other_names"], ["Pexa-Vec"])
        self.assertEqual(r["countries"], ["Korea, Republic of", "United States"])
        self.assertEqual(r["n_locations"], 2)
        self.assertEqual([x["pmid"] for x in r["references"]], ["111", "222"])
        self.assertEqual(r["primary_completion_date_type"], "ESTIMATED")
        self.assertFalse(r["has_results"])
        self.assertEqual(len(r["content_hash"]), 64)

    def test_no_contact_details(self):
        text = json.dumps(snap.canonical(study("NCT01")))
        for private in ("Jane", "jane@example.org", "555-0100", "Site Lead"):
            self.assertNotIn(private, text)
        raw = json.dumps(snap.strip_contacts(study("NCT01")))
        for private in ("jane@example.org", "555-0100", "Site Lead"):
            self.assertNotIn(private, raw)
        self.assertIn("Hospital A", raw)

    def test_hash_ignores_order_and_bookkeeping(self):
        a = study("NCT01")
        b = study("NCT01", verified="2026-11", updated="2026-11-05")
        ivs = b["protocolSection"]["armsInterventionsModule"]["interventions"]
        ivs.reverse()
        b["protocolSection"]["conditionsModule"]["conditions"].reverse()
        self.assertEqual(snap.canonical(a)["content_hash"], snap.canonical(b)["content_hash"])

    def test_hash_sees_real_changes(self):
        base = snap.canonical(study("NCT01"))["content_hash"]
        for changed in (study("NCT01", status="TERMINATED"), study("NCT01", enrol=80),
                        study("NCT01", other_names=("Pexa-Vec", "JX-594")), study("NCT01", pmids=("1",)),
                        study("NCT01", locations=[])):
            self.assertNotEqual(snap.canonical(changed)["content_hash"], base)

    def test_sparse_record(self):
        r = snap.canonical({"protocolSection": {"identificationModule": {"nctId": "NCT09"}}})
        self.assertEqual(r["nct_id"], "NCT09")
        self.assertIsNone(r["overall_status"])
        self.assertEqual(r["interventions"], [])
        self.assertEqual(r["n_locations"], 0)


class Snapshot(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = os.path.join(self.dir, "snap", "trials.sqlite")
        self.scope = [("onc", "oncolytic"), ("kras", "KRAS")]
        self.logs = []

    def tearDown(self):
        shutil.rmtree(self.dir)

    def run_snap(self, api, day="2026-11-15"):
        return snap.take_snapshot(self.db, self.scope, today=day, get=api, log=self.logs.append)

    def test_full_run(self):
        api = FakeAPI({"oncolytic": [study("NCT03"), study("NCT01"), study("NCT02")],
                       "KRAS": [study("NCT02"), study("NCT04")]})
        self.assertEqual(self.run_snap(api), 0)
        obs = db_rows(self.db, "SELECT nct_id, matched_queries FROM observation ORDER BY nct_id")
        self.assertEqual([o[0] for o in obs], ["NCT01", "NCT02", "NCT03", "NCT04"])
        self.assertEqual(json.loads(obs[1][1]), ["kras", "onc"])
        (complete, n, new, manifest), = db_rows(self.db, "SELECT complete, n_trials, n_new_versions, manifest FROM snapshot")
        self.assertEqual((complete, n, new), (1, 4, 4))
        self.assertEqual(json.loads(manifest)["queries"][0]["pages"], 2)  # paging followed
        self.assertTrue(all("fields" in c for c in api.calls))
        # The stored record is the tracked fields, and hashes to its content_hash.
        (nct, h, rec, raw), = db_rows(self.db, "SELECT nct_id, content_hash, record, raw FROM trial_version WHERE nct_id='NCT01'")
        self.assertEqual(snap.content_hash(json.loads(rec)), h)
        self.assertNotIn("last_update_post_date", json.loads(rec))
        raw = snap.decompress(raw)
        self.assertEqual(raw["protocolSection"]["identificationModule"]["nctId"], "NCT01")
        self.assertNotIn("centralContacts", raw["protocolSection"]["contactsLocationsModule"])

    def test_a_date_is_written_once(self):
        api = FakeAPI({"oncolytic": [study("NCT01")], "KRAS": []})
        self.run_snap(api)
        calls = len(api.calls)
        self.assertEqual(self.run_snap(api), 0)
        self.assertEqual(len(api.calls), calls)                          # didn't even fetch
        self.assertEqual(db_rows(self.db, "SELECT count(*) FROM snapshot"), [(1,)])

    def test_versions_stored_once_and_changes_found(self):
        self.run_snap(FakeAPI({"oncolytic": [study("NCT01"), study("NCT02")], "KRAS": []}), day="2026-11-15")
        # Bookkeeping-only edit to NCT01, real change to NCT02: one new version.
        self.run_snap(FakeAPI({"oncolytic": [study("NCT01", updated="2026-11-20"),
                                             study("NCT02", status="TERMINATED")], "KRAS": []}), day="2026-11-22")
        self.assertEqual(db_rows(self.db, "SELECT n_new_versions FROM snapshot WHERE snapshot_date='2026-11-22'"), [(1,)])
        self.assertEqual(db_rows(self.db, "SELECT count(*) FROM trial_version"), [(3,)])
        self.assertEqual(db_rows(self.db, "SELECT count(*) FROM observation"), [(4,)])
        con = sqlite3.connect(self.db)
        changed = con.execute(snap.CHANGES_SQL, {"a": "2026-11-15", "b": "2026-11-22"}).fetchall()
        con.close()
        self.assertEqual([c[0] for c in changed], ["NCT02"])
        # The bookkeeping date is still recorded, per observation.
        self.assertEqual(db_rows(self.db, "SELECT last_update_post_date FROM observation WHERE nct_id='NCT01' "
                                          "ORDER BY snapshot_date"), [("2026-10-01",), ("2026-11-20",)])

    def test_failed_query_marks_snapshot_incomplete(self):
        api = FakeAPI({"oncolytic": [study("NCT01")]}, fail={"KRAS"})
        self.assertEqual(self.run_snap(api), 3)
        (complete, manifest), = db_rows(self.db, "SELECT complete, manifest FROM snapshot")
        self.assertEqual(complete, 0)
        self.assertIn("503", json.loads(manifest)["queries"][1]["error"])

    def test_nothing_fetched_writes_nothing(self):
        self.assertEqual(self.run_snap(FakeAPI({}, fail={"oncolytic", "KRAS"})), 1)
        self.assertEqual(db_rows(self.db, "SELECT count(*) FROM snapshot"), [(0,)])

    def test_failure_while_storing_leaves_no_partial_snapshot(self):
        api = FakeAPI({"oncolytic": [study("NCT01"), study("NCT02")], "KRAS": []})
        real = snap.strip_contacts
        calls = []

        def boom(s):
            calls.append(1)
            if len(calls) == 2:
                raise RuntimeError("disk full")
            return real(s)
        snap.strip_contacts = boom
        try:
            with self.assertRaises(RuntimeError):
                self.run_snap(api)
        finally:
            snap.strip_contacts = real
        for table in ("snapshot", "trial_version", "observation"):
            self.assertEqual(db_rows(self.db, "SELECT count(*) FROM %s" % table), [(0,)], table)

    def test_field_list_fallback(self):
        api = FakeAPI({"oncolytic": [study("NCT01")], "KRAS": [study("NCT02")]}, reject_fields=True)
        self.assertEqual(self.run_snap(api), 0)
        (manifest,), = db_rows(self.db, "SELECT manifest FROM snapshot")
        self.assertFalse(json.loads(manifest)["used_field_list"])

    def test_status(self):
        out = []
        self.assertEqual(snap.status(self.db, today="2026-11-15", log=out.append), 1)
        self.run_snap(FakeAPI({"oncolytic": [study("NCT01")], "KRAS": []}))
        self.assertEqual(snap.status(self.db, today="2026-11-20", log=out.append), 0)
        self.assertEqual(snap.status(self.db, today="2026-12-01", log=out.append), 1)   # stale

    def test_scope_file(self):
        rows = snap.read_scope(snap.DEFAULT_SCOPE)
        self.assertEqual([q for q, _ in rows], ["oncolytic", "car_t", "kras"])


class ImportLegacy(unittest.TestCase):
    """Snapshots written by script version 1 load into the database unchanged."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.legacy = os.path.join(self.dir, "legacy")
        self.db = os.path.join(self.dir, "trials.sqlite")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write_legacy(self, day, studies, drop_raw=None, tamper=None):
        recs = []
        for s in studies:
            rec = snap.canonical(s)
            rec["matched_queries"] = ["onc"]
            recs.append(rec)
            if rec["nct_id"] != drop_raw:
                path = os.path.join(self.legacy, "raw", rec["nct_id"], rec["content_hash"][:16] + ".json.gz")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with gzip.open(path, "wt", encoding="utf-8") as fh:
                    json.dump(snap.strip_contacts(s), fh)
        if tamper:
            recs[0]["overall_status"] = tamper
        os.makedirs(os.path.join(self.legacy, day))
        with gzip.open(os.path.join(self.legacy, day, "trials.jsonl.gz"), "wt", encoding="utf-8") as fh:
            for r in recs:
                fh.write(json.dumps(r) + "\n")
        with open(os.path.join(self.legacy, day, "manifest.json"), "w") as fh:
            json.dump({"snapshot_date": day, "started_at": "2026-11-11T06:30:00+00:00",
                       "finished_at": "2026-11-11T06:32:00+00:00", "script_version": "1",
                       "complete": True, "n_trials": len(recs), "queries": []}, fh)

    def test_import(self):
        self.write_legacy("2026-11-11", [study("NCT01"), study("NCT02")])
        logs = []
        self.assertEqual(snap.import_legacy(self.db, self.legacy, log=logs.append), 0)
        self.assertEqual(db_rows(self.db, "SELECT snapshot_date, n_trials, n_new_versions, complete FROM snapshot"),
                         [("2026-11-11", 2, 2, 1)])
        (raw,), = db_rows(self.db, "SELECT raw FROM trial_version WHERE nct_id='NCT02'")
        self.assertEqual(snap.decompress(raw)["protocolSection"]["identificationModule"]["nctId"], "NCT02")
        # Running it again changes nothing.
        self.assertEqual(snap.import_legacy(self.db, self.legacy, log=logs.append), 0)
        self.assertEqual(db_rows(self.db, "SELECT count(*) FROM observation"), [(2,)])
        # A later live snapshot of unchanged trials adds no new versions.
        api = FakeAPI({"oncolytic": [study("NCT01"), study("NCT02")]})
        snap.take_snapshot(self.db, [("onc", "oncolytic")], today="2026-11-15", get=api, log=logs.append)
        self.assertEqual(db_rows(self.db, "SELECT n_new_versions FROM snapshot WHERE snapshot_date='2026-11-15'"), [(0,)])

    def test_refuses_missing_raw_or_bad_hash(self):
        self.write_legacy("2026-11-11", [study("NCT01"), study("NCT02")], drop_raw="NCT02")
        with self.assertRaises(SystemExit):
            snap.import_legacy(self.db, self.legacy, log=lambda m: None)
        self.assertEqual(db_rows(self.db, "SELECT count(*) FROM snapshot"), [(0,)])
        shutil.rmtree(self.legacy)
        self.write_legacy("2026-11-11", [study("NCT01")], tamper="TERMINATED")
        with self.assertRaises(SystemExit):
            snap.import_legacy(self.db, self.legacy, log=lambda m: None)


if __name__ == "__main__":
    unittest.main()
