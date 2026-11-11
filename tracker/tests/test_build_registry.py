"""Tests for tracker/build_registry.py: links, change events, digest page."""

import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
import build_registry as br  # noqa: E402
import snapshot_trials as snap  # noqa: E402
from test_snapshot import FakeAPI, study  # noqa: E402

snap.PAUSE_SECONDS = 0
REPO_REGISTRY = os.path.join(os.path.dirname(os.path.dirname(HERE)), "registry")


def trial(nct, name, other=(), title="A study", posted=None, **kw):
    s = study(nct, other_names=other, **kw)
    if posted:
        s["protocolSection"]["statusModule"]["studyFirstPostDateStruct"]["date"] = posted
    s["protocolSection"]["armsInterventionsModule"]["interventions"] = [
        {"type": "BIOLOGICAL", "name": name, "otherNames": list(other)}]
    s["protocolSection"]["identificationModule"]["briefTitle"] = title
    return s


def rows(db, sql, *args):
    con = sqlite3.connect(db)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


class Matching(unittest.TestCase):
    def test_window_keys(self):
        keys = br.window_keys("Phase 1 of MRTX 1133 (Mirati)")
        self.assertIn("MRTX1133", keys)
        self.assertIn("MIRATI", keys)
        self.assertNotIn("MRTX1133MIRATIX", keys)

    def test_links(self):
        alias = lambda axp, name, typ="code", amb=0: {"axp_id": axp, "alias": name, "alias_key": br.reg.alias_key(name),
                                                      "alias_type": typ, "ambiguous": amb}
        idx = br.AliasIndex([alias("AXP1", "pexastimogene devacirepvec", "preferred"), alias("AXP1", "Pexa-Vec", "synonym"),
                             alias("AXP1", "JX-594"), alias("AXP2", "RP1", amb=1),
                             alias("AXP3", "MRTX1133", "preferred"), alias("AXP4", "H101", "preferred"),
                             alias("AXP5", "AUTO1"), alias("AXP6", "Imlygic", "brand")])
        rec = lambda name, other=(), title="": {"interventions": [{"name": name, "other_names": list(other)}],
                                                 "brief_title": title}
        l = br.link_trial(rec("Pexa Vec"), idx)                      # spelling variant: exact key
        self.assertEqual((l["AXP1"]["method"], l["AXP1"]["status"]), ("intervention_name", "auto"))
        l = br.link_trial(rec("pexastimogene devacirepvec 1e9 pfu"), idx)  # a name inside a longer one
        self.assertEqual((l["AXP1"]["method"], l["AXP1"]["status"]), ("intervention_text", "auto"))
        l = br.link_trial(rec("Biological: JX-594 low dose"), idx)  # a code inside: review it
        self.assertEqual((l["AXP1"]["method"], l["AXP1"]["status"]), ("intervention_text", "candidate"))
        l = br.link_trial(rec("AUTO1/22"), idx)                     # a different product containing a code
        self.assertEqual(l["AXP5"]["status"], "candidate")
        l = br.link_trial(rec("Imlygic injection"), idx)
        self.assertEqual(l["AXP6"]["status"], "auto")
        l = br.link_trial(rec("Oncolytic virus H101 injection"), idx)  # short key: candidate only
        self.assertEqual(l["AXP4"]["status"], "candidate")
        l = br.link_trial(rec("RP1"), idx)                          # ambiguous name: candidate only
        self.assertEqual(l["AXP2"]["status"], "candidate")
        l = br.link_trial(rec("Placebo", title="MRTX1133 in pancreatic cancer"), idx)
        self.assertEqual((l["AXP3"]["method"], l["AXP3"]["status"]), ("title", "candidate"))
        l = br.link_trial(rec("Placebo", other=["MRTX-1133"], title="MRTX1133 study"), idx)
        self.assertEqual(l["AXP3"]["method"], "intervention_name")  # best evidence wins
        self.assertEqual(br.link_trial(rec("Radiotherapy", other=["Radiotherapy"]), idx), {})


class Diff(unittest.TestCase):
    def rec(self, **kw):
        base = snap.canonical(study("NCT01"))
        base.update(kw)
        return base

    def types(self, a, b):
        return {e[0]: e for e in br.diff_records(a, b)}

    def test_events(self):
        a = self.rec()
        t = self.types(a, self.rec(overall_status="TERMINATED", why_stopped="Sponsor decision"))
        self.assertEqual(t["trial.status_changed"][1:], ("major", "overall_status", "RECRUITING", "TERMINATED (Sponsor decision)"))
        self.assertEqual(self.types(a, self.rec(overall_status="ENROLLING_BY_INVITATION"))["trial.status_changed"][1], "minor")
        self.assertIn("trial.phase_changed", self.types(a, self.rec(phases=["PHASE3"])))
        self.assertIn("trial.results_posted", self.types(a, self.rec(has_results=True)))
        self.assertIn("trial.enrollment_changed", self.types(a, self.rec(enrollment_count=60)))
        self.assertNotIn("trial.enrollment_changed", self.types(a, self.rec(enrollment_count=44)))
        self.assertIn("trial.enrollment_changed", self.types(a, self.rec(enrollment_count=38, enrollment_type="ACTUAL")))
        self.assertIn("trial.completion_slipped", self.types(a, self.rec(primary_completion_date="2027-06")))
        self.assertNotIn("trial.completion_slipped", self.types(a, self.rec(primary_completion_date="2027-02")))
        self.assertIn("trial.sponsor_changed", self.types(a, self.rec(lead_sponsor="Other Co")))
        ivs = a["interventions"] + [{"type": "DRUG", "name": "Nivolumab", "other_names": []}]
        self.assertEqual(self.types(a, self.rec(interventions=ivs))["trial.intervention_added"][4], '["Nivolumab"]')
        self.assertEqual(br.diff_records(a, self.rec(n_locations=9)), [])   # tracked but not an event


class Build(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.snapdb = os.path.join(self.dir, "trials.sqlite")
        self.out = os.path.join(self.dir, "registry", "registry.sqlite")
        self.page = os.path.join(self.dir, "www", "changes.html")
        self.logs = []

    def tearDown(self):
        shutil.rmtree(self.dir)

    def take(self, day, trials, fail=()):
        api = FakeAPI({"oncolytic": trials}, fail=fail)
        snap.take_snapshot(self.snapdb, [("onc", "oncolytic")], today=day, get=api, log=self.logs.append)

    def build(self):
        br.build(REPO_REGISTRY, self.snapdb, self.out, today="2026-11-22", log=self.logs.append)
        br.write_page(self.out, self.page, log=self.logs.append)

    def test_programs_only_without_snapshots(self):
        self.build()
        programs, _ = br.reg.read_tsv(os.path.join(REPO_REGISTRY, "programs.tsv"), br.reg.PROGRAM_COLUMNS)
        (viruses, _), _ = br.reg.read_optional(REPO_REGISTRY)
        active = sum(1 for p in programs if p["status"] == "active")
        self.assertEqual(rows(self.out, "SELECT count(*) FROM program"), [(len(programs),)])
        self.assertEqual(rows(self.out, "SELECT count(*) FROM virus"), [(len(viruses),)])
        # every active program's preferred name is a name, and keys are filled
        self.assertEqual(rows(self.out, "SELECT count(*) FROM alias WHERE alias_type='preferred'"), [(active,)])
        self.assertEqual(rows(self.out, "SELECT count(*) FROM alias WHERE alias_key=''"), [(0,)])
        with open(self.page, encoding="utf-8") as fh:
            self.assertIn("Tracked programs", fh.read())

    def test_links_and_changes_over_three_weeks(self):
        w1 = [trial("NCT01", "Pexa-Vec", title="Pexa-Vec in liver cancer"),
              trial("NCT02", "Sotorasib", title="AMG 510 study"),
              trial("NCT03", "Placebo", title="MRTX1133 in pancreatic cancer"),
              trial("NCT04", "Radiotherapy", other=("Radiotherapy",))]
        self.take("2026-11-11", w1)
        w2 = [trial("NCT01", "Pexa-Vec", title="Pexa-Vec in liver cancer", status="TERMINATED"),
              trial("NCT02", "Sotorasib", title="AMG 510 study", updated="2026-11-15"),   # bookkeeping only
              trial("NCT03", "Placebo", title="MRTX1133 in pancreatic cancer"),
              trial("NCT04", "Radiotherapy", other=("Radiotherapy",)),
              trial("NCT05", "Adagrasib", title="New KRAS trial", posted="2026-11-13"),
              trial("NCT07", "Sotorasib", title="Old trial newly in scope")]   # posted 2024: no event
        self.take("2026-11-15", w2)
        self.build()
        links = {(n, a): (m, s) for n, a, m, s in rows(self.out, "SELECT nct_id, axp_id, method, status FROM trial_link")}
        pexa = rows(self.out, "SELECT axp_id FROM alias WHERE alias='Pexa-Vec'")[0][0]
        soto = rows(self.out, "SELECT axp_id FROM program WHERE preferred_name='sotorasib'")[0][0]
        mrtx = rows(self.out, "SELECT axp_id FROM program WHERE preferred_name='MRTX1133'")[0][0]
        self.assertEqual(links[("NCT01", pexa)], ("intervention_name", "auto"))
        self.assertEqual(links[("NCT02", soto)], ("intervention_name", "auto"))
        self.assertEqual(links[("NCT03", mrtx)], ("title", "candidate"))
        self.assertFalse(any(n == "NCT04" for n, _ in links))
        ev = {(n, t): (s, ax) for n, t, s, ax in rows(self.out, "SELECT nct_id, type, significance, axp_ids FROM change_event")}
        self.assertEqual(set(ev), {("NCT01", "trial.status_changed"), ("NCT05", "trial.new")})
        self.assertEqual(ev[("NCT01", "trial.status_changed")], ("major", json.dumps([pexa])))
        meta = dict(rows(self.out, "SELECT key, value FROM meta"))
        self.assertEqual((meta["latest_snapshot"], meta["previous_snapshot"]), ("2026-11-15", "2026-11-11"))
        self.assertTrue(meta["registry_release"].startswith("2026-11-22+"))
        with open(self.page, encoding="utf-8") as fh:
            page = fh.read()
        self.assertIn("1 major and 1 minor", page)
        self.assertIn("pexastimogene devacirepvec", page)
        self.assertIn("NCT01", page)
        with open(os.path.join(self.dir, "registry", "link_review.tsv"), encoding="utf-8") as fh:
            review = fh.read()
        self.assertIn("NCT03", review)
        # A third week: an incomplete snapshot reports no new or dropped trials.
        self.take("2026-11-22", [trial("NCT06", "Divarasib", posted="2026-11-20")], fail=())
        con = sqlite3.connect(self.snapdb)
        con.execute("UPDATE snapshot SET complete = 0 WHERE snapshot_date = '2026-11-22'")
        con.commit()
        con.close()
        self.build()
        types = rows(self.out, "SELECT type FROM change_event WHERE snapshot_date='2026-11-22'")
        self.assertIn(("trial.new",), types)          # previous week was complete
        self.assertNotIn(("trial.dropped",), types)   # this week wasn't
        # Rebuilding gives the same events (stable IDs, no duplicates).
        before = rows(self.out, "SELECT event_id FROM change_event ORDER BY event_id")
        self.build()
        self.assertEqual(rows(self.out, "SELECT event_id FROM change_event ORDER BY event_id"), before)

    def test_bad_registry_builds_nothing(self):
        bad = os.path.join(self.dir, "bad")
        shutil.copytree(REPO_REGISTRY, bad)
        with open(os.path.join(bad, "aliases.tsv"), "a", encoding="utf-8") as fh:
            fh.write("AXP999999\tX\tcode\tcurator\t\tCC0-1.0\t\t\t0\taccepted\thttp://x\t2026-11-11\n")
        with self.assertRaises(SystemExit):
            br.build(bad, self.snapdb, self.out, log=self.logs.append)
        self.assertFalse(os.path.exists(self.out))


if __name__ == "__main__":
    unittest.main()
