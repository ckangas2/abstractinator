"""Tests for tracker/snapshot_trials.py, with a fake API (no network)."""

import copy
import gzip
import json
import os
import shutil
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


def slurp(*parts, mode="r"):
    with open(os.path.join(*parts), mode) as fh:
        return fh.read()


def read_snapshot(out, day):
    with gzip.open(os.path.join(out, day, "trials.jsonl.gz"), "rt", encoding="utf-8") as fh:
        recs = [json.loads(l) for l in fh if l.strip()]
    with open(os.path.join(out, day, "manifest.json"), encoding="utf-8") as fh:
        return recs, json.load(fh)


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
        self.out = tempfile.mkdtemp()
        self.scope = [("onc", "oncolytic"), ("kras", "KRAS")]
        self.logs = []

    def tearDown(self):
        shutil.rmtree(self.out)

    def run_snap(self, api, day="2026-11-15", **kw):
        return snap.take_snapshot(self.out, self.scope, today=day, get=api, log=self.logs.append, **kw)

    def test_full_run(self):
        api = FakeAPI({"oncolytic": [study("NCT03"), study("NCT01"), study("NCT02")],
                       "KRAS": [study("NCT02"), study("NCT04")]})
        self.assertEqual(self.run_snap(api), 0)
        recs, m = read_snapshot(self.out, "2026-11-15")
        self.assertEqual([r["nct_id"] for r in recs], ["NCT01", "NCT02", "NCT03", "NCT04"])
        self.assertEqual(recs[1]["matched_queries"], ["kras", "onc"])
        self.assertTrue(m["complete"])
        self.assertEqual(m["n_trials"], 4)
        self.assertEqual(m["queries"][0]["pages"], 2)                    # paging followed
        self.assertTrue(all("fields" in c for c in api.calls))
        self.assertEqual(m["n_new_raw_versions"], 4)
        self.assertFalse([d for d in os.listdir(self.out) if d.endswith(".tmp")])

    def test_existing_snapshot_is_never_overwritten(self):
        api = FakeAPI({"oncolytic": [study("NCT01")], "KRAS": []})
        self.run_snap(api)
        first = slurp(self.out, "2026-11-15", "manifest.json")
        calls = len(api.calls)
        self.assertEqual(self.run_snap(api), 0)
        self.assertEqual(len(api.calls), calls)                          # didn't even fetch
        self.run_snap(api, force=True)
        kept = [d for d in os.listdir(self.out) if d.startswith("2026-11-15.replaced-")]
        self.assertEqual(len(kept), 1)
        self.assertEqual(slurp(self.out, kept[0], "manifest.json"), first)

    def test_raw_archive_only_when_content_changes(self):
        self.run_snap(FakeAPI({"oncolytic": [study("NCT01")], "KRAS": []}), day="2026-11-15")
        _, m = read_snapshot(self.out, "2026-11-15")
        self.assertEqual(m["n_new_raw_versions"], 1)
        # A bookkeeping-only edit: no new raw version.
        self.run_snap(FakeAPI({"oncolytic": [study("NCT01", updated="2026-11-20")], "KRAS": []}), day="2026-11-22")
        _, m = read_snapshot(self.out, "2026-11-22")
        self.assertEqual(m["n_new_raw_versions"], 0)
        # A real change: archived.
        self.run_snap(FakeAPI({"oncolytic": [study("NCT01", status="TERMINATED")], "KRAS": []}), day="2026-11-29")
        _, m = read_snapshot(self.out, "2026-11-29")
        self.assertEqual(m["n_new_raw_versions"], 1)
        self.assertEqual(len(os.listdir(os.path.join(self.out, "raw", "NCT01"))), 2)

    def test_same_content_same_bytes(self):
        api = lambda: FakeAPI({"oncolytic": [study("NCT02"), study("NCT01")], "KRAS": []})
        self.run_snap(api(), day="2026-11-15")
        self.run_snap(api(), day="2026-11-22")
        a = slurp(self.out, "2026-11-15", "trials.jsonl.gz", mode="rb")
        b = slurp(self.out, "2026-11-22", "trials.jsonl.gz", mode="rb")
        self.assertEqual(a, b)

    def test_failed_query_marks_snapshot_incomplete(self):
        api = FakeAPI({"oncolytic": [study("NCT01")]}, fail={"KRAS"})
        self.assertEqual(self.run_snap(api), 3)
        recs, m = read_snapshot(self.out, "2026-11-15")
        self.assertEqual(len(recs), 1)
        self.assertFalse(m["complete"])
        self.assertIn("503", m["queries"][1]["error"])

    def test_nothing_fetched_writes_nothing(self):
        self.assertEqual(self.run_snap(FakeAPI({}, fail={"oncolytic", "KRAS"})), 1)
        self.assertEqual(os.listdir(self.out), [])

    def test_field_list_fallback(self):
        api = FakeAPI({"oncolytic": [study("NCT01")], "KRAS": [study("NCT02")]}, reject_fields=True)
        self.assertEqual(self.run_snap(api), 0)
        _, m = read_snapshot(self.out, "2026-11-15")
        self.assertFalse(m["used_field_list"])
        self.assertEqual(m["n_trials"], 2)

    def test_status(self):
        out = []
        self.assertEqual(snap.status(self.out, today="2026-11-15", log=out.append), 1)
        self.run_snap(FakeAPI({"oncolytic": [study("NCT01")], "KRAS": []}))
        self.assertEqual(snap.status(self.out, today="2026-11-20", log=out.append), 0)
        self.assertEqual(snap.status(self.out, today="2026-12-01", log=out.append), 1)   # stale

    def test_scope_file(self):
        rows = snap.read_scope(snap.DEFAULT_SCOPE)
        ids = [q for q, _ in rows]
        self.assertEqual(ids, ["oncolytic", "car_t", "kras"])


if __name__ == "__main__":
    unittest.main()
