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
        l = br.link_trial(rec("Biological: JX-594 low dose", title="JX-594 in liver cancer"), idx)
        self.assertEqual(l["AXP1"]["status"], "auto")               # ...unless the title names it too
        l = br.link_trial(rec("Oncolytic virus H101 injection", title="H101 plus PD-1"), idx)
        self.assertEqual(l["AXP4"]["status"], "auto")
        l = br.link_trial(rec("AUTO1/22"), idx)                     # a different product containing a code
        self.assertEqual(l["AXP5"]["status"], "candidate")
        l = br.link_trial(rec("Imlygic injection"), idx)
        self.assertEqual(l["AXP6"]["status"], "auto")
        l = br.link_trial(rec("Oncolytic virus H101 injection"), idx)  # short key: candidate only
        self.assertEqual(l["AXP4"]["status"], "candidate")
        l = br.link_trial(rec("RP1"), idx)                          # ambiguous name: candidate only
        self.assertEqual(l["AXP2"]["status"], "candidate")
        l = br.link_trial(rec("Placebo", title="MRTX1133 in pancreatic cancer"), idx)   # a name in the title
        self.assertEqual((l["AXP3"]["method"], l["AXP3"]["status"], l["AXP3"]["confidence"]), ("title", "auto", 0.6))
        l = br.link_trial(rec("Placebo", title="JX-594 in liver cancer"), idx)          # a code in the title only
        self.assertEqual((l["AXP1"]["method"], l["AXP1"]["status"]), ("title", "candidate"))
        l = br.link_trial(rec("Placebo", title="RP1 and RP2 expression"), idx)          # too short to search text
        self.assertNotIn("AXP2", l)
        l = br.link_trial(rec("Placebo", other=["MRTX-1133"], title="MRTX1133 study"), idx)
        self.assertEqual(l["AXP3"]["method"], "intervention_name")  # best evidence wins
        self.assertEqual(br.link_trial(rec("Radiotherapy", other=["Radiotherapy"]), idx), {})

    def test_ambiguous_name_with_the_programs_sponsor(self):
        """An ambiguous code counts when the trial's sponsor is the program's own."""
        alias = {"axp_id": "AXP144", "alias": "AdV-tk", "alias_key": br.reg.alias_key("AdV-tk"),
                 "alias_type": "code", "ambiguous": 1}
        progs = [{"axp_id": "AXP144", "sponsor": "Candel Therapeutics", "originator": "Advantagene"}]
        idx = br.AliasIndex([alias], progs)
        rec = lambda sponsor, collab=(), title="A study": {
            "interventions": [{"name": "AdV-tk", "other_names": []}], "brief_title": title,
            "lead_sponsor": sponsor, "collaborators": list(collab)}
        l = br.link_trial(rec("Candel Therapeutics, Inc."), idx)
        self.assertEqual((l["AXP144"]["method"], l["AXP144"]["status"]), ("intervention_name", "auto"))
        self.assertIn("sponsor", l["AXP144"]["matched"])
        self.assertEqual(br.link_trial(rec("Advantagene, Inc."), idx)["AXP144"]["status"], "auto")   # originator
        self.assertEqual(br.link_trial(rec("Some University", ["Candel Therapeutics"]), idx)["AXP144"]["status"],
                         "auto")                                                                     # collaborator
        self.assertEqual(br.link_trial(rec("Huazhong University of Science and Technology"), idx)["AXP144"]["status"],
                         "candidate")                                         # same name, someone else's product
        self.assertEqual(br.link_trial(rec(None), idx)["AXP144"]["status"], "candidate")
        # without program sponsors (the evidence fetcher's index) nothing changes
        self.assertEqual(br.link_trial(rec("Candel Therapeutics, Inc."), br.AliasIndex([alias]))["AXP144"]["status"],
                         "candidate")
        # the title alone is never enough, sponsor or not
        title_only = {"interventions": [{"name": "Placebo", "other_names": []}], "brief_title": "AdV-tk study",
                      "lead_sponsor": "Candel Therapeutics"}
        self.assertNotEqual(br.link_trial(title_only, idx).get("AXP144", {}).get("status"), "auto")

    def test_code_inside_an_intervention_with_the_programs_sponsor(self):
        alias = {"axp_id": "AXP144", "alias": "CAN-2409", "alias_key": br.reg.alias_key("CAN-2409"),
                 "alias_type": "code", "ambiguous": 0}
        idx = br.AliasIndex([alias], [{"axp_id": "AXP144", "sponsor": "Candel Therapeutics", "originator": ""}])
        rec = lambda sponsor: {"interventions": [{"name": "CAN-2409 + valacyclovir", "other_names": []}],
                               "brief_title": "Gene mediated cytotoxic immunotherapy in NSCLC", "lead_sponsor": sponsor}
        self.assertEqual(br.link_trial(rec("Candel Therapeutics, Inc."), idx)["AXP144"]["status"], "auto")
        self.assertEqual(br.link_trial(rec("Another Company"), idx)["AXP144"]["status"], "candidate")

    def test_org_keys(self):
        self.assertEqual(br.org_keys("Spark Therapeutics (Roche)"), {"SPARKTHERAPEUTICS", "ROCHE"})
        self.assertEqual(br.org_keys("Candel Therapeutics, Inc."), {"CANDELTHERAPEUTICS"})
        self.assertEqual(br.org_keys("Inc."), set())
        self.assertEqual(br.org_keys("Johnson & Johnson"), {"JOHNSONJOHNSON"})
        roche = br.AliasIndex([], [{"axp_id": "A", "sponsor": "Roche", "originator": ""}])
        self.assertTrue(roche.sponsor_agrees("A", {"lead_sponsor": "Hoffmann-La Roche"}))
        self.assertFalse(roche.sponsor_agrees("A", {"lead_sponsor": "University of Rochester"}))
        mayo = br.AliasIndex([], [{"axp_id": "M", "sponsor": "Mayo Clinic", "originator": ""}])
        self.assertTrue(mayo.sponsor_agrees("M", {"lead_sponsor": "Mayo Clinic in Florida"}))
        self.assertEqual(br.org_keys("Centers for Disease Control and Prevention"),
                         {"CENTERSFORDISEASECONTROLANDPREVENTION"})


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
              trial("NCT03", "Placebo", title="JAB-21822 in pancreatic cancer"),
              trial("NCT04", "Radiotherapy", other=("Radiotherapy",))]
        self.take("2026-11-11", w1)
        w2 = [trial("NCT01", "Pexa-Vec", title="Pexa-Vec in liver cancer", status="TERMINATED"),
              trial("NCT02", "Sotorasib", title="AMG 510 study", updated="2026-11-15"),   # bookkeeping only
              trial("NCT03", "Placebo", title="JAB-21822 in pancreatic cancer"),
              trial("NCT04", "Radiotherapy", other=("Radiotherapy",)),
              trial("NCT05", "Adagrasib", title="New KRAS trial", posted="2026-11-13"),
              trial("NCT07", "Sotorasib", title="Old trial newly in scope")]   # posted 2024: no event
        self.take("2026-11-15", w2)
        self.build()
        links = {(n, a): (m, s) for n, a, m, s in rows(self.out, "SELECT nct_id, axp_id, method, status FROM trial_link")}
        pexa = rows(self.out, "SELECT axp_id FROM alias WHERE alias='Pexa-Vec'")[0][0]
        soto = rows(self.out, "SELECT axp_id FROM program WHERE preferred_name='sotorasib'")[0][0]
        glec = rows(self.out, "SELECT axp_id FROM program WHERE preferred_name='glecirasib'")[0][0]
        self.assertEqual(links[("NCT01", pexa)], ("intervention_name", "auto"))
        self.assertEqual(links[("NCT02", soto)], ("intervention_name", "auto"))
        self.assertEqual(links[("NCT03", glec)], ("title", "candidate"))   # a code in the title only
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
        self.assertFalse(os.path.exists(os.path.join(self.dir, "registry", "link_review.tsv")))
        dest = os.path.join(self.dir, "reports", "link_review.tsv")
        self.assertEqual(br.export_review(self.out, dest, log=self.logs.append), 1)
        with open(dest, encoding="utf-8") as fh:
            review = fh.read()
        self.assertIn("NCT03", review)
        # An ambiguous name outside a title is dropped rather than queued for review.
        amb = {"ambiguous": 1, "alias_key": "TKCELLS", "alias_type": "synonym"}
        self.assertIsNone(br.evidence_status(amb, "abstract"))
        self.assertIsNone(br.evidence_status(amb, "terms"))
        self.assertEqual(br.evidence_status(amb, "title"), "candidate")
        # A long, unambiguous development code counts in an abstract; a short one waits.
        code = {"ambiguous": 0, "alias_key": "SCH58500", "alias_type": "code"}
        self.assertEqual(br.evidence_status(code, "abstract"), "auto")
        short = {"ambiguous": 0, "alias_key": "G207", "alias_type": "code"}
        self.assertEqual(br.evidence_status(short, "abstract"), "candidate")
        self.assertEqual(br.evidence_status(short, "title"), "auto")     # a title is enough for a short code
        tiny = {"ambiguous": 0, "alias_key": "HF10", "alias_type": "code"}
        self.assertEqual(br.evidence_status(tiny, "abstract"), "candidate")
        self.assertEqual(review.split("\n")[0].split("\t")[0], "kind")
        self.assertTrue(any(l.startswith("trial\t") for l in review.splitlines()[1:]))
        with self.assertRaises(SystemExit):                     # never overwrites
            br.export_review(self.out, dest, log=self.logs.append)
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

    def test_papers_and_grants(self):
        # A linked trial's registration cites a results paper.
        self.take("2026-11-11", [trial("NCT01", "Pexa-Vec", pmids=("11111111",))])
        ev = os.path.join(self.dir, "evidence.sqlite")
        con = sqlite3.connect(ev)
        con.executescript("""
          CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
          CREATE TABLE paper (pmid TEXT PRIMARY KEY, title TEXT, journal TEXT, year INTEGER, kind TEXT,
                              doi TEXT, pmcid TEXT);
          CREATE TABLE paper_hit (pmid TEXT, axp_id TEXT, matched TEXT, field TEXT, PRIMARY KEY (pmid, axp_id));
          CREATE TABLE grant_award (core_project_num TEXT PRIMARY KEY, title TEXT, org TEXT, pi TEXT,
                                    first_fy INTEGER, last_fy INTEGER, url TEXT);
          CREATE TABLE grant_hit (core_project_num TEXT, axp_id TEXT, matched TEXT, field TEXT,
                                  PRIMARY KEY (core_project_num, axp_id));
        """)
        con.commit()
        con.close()
        br.build(REPO_REGISTRY, self.snapdb, self.out, today="2026-11-22", log=self.logs.append, evidence=ev)
        pexa = rows(self.out, "SELECT axp_id FROM alias WHERE alias='Pexa-Vec'")[0][0]
        self.assertEqual(rows(self.out, "SELECT axp_id, pmid, method, nct_id, status FROM paper_link"),
                         [(pexa, "11111111", "trial_reference", "NCT01", "auto")])
        con = sqlite3.connect(ev)
        con.executemany("INSERT INTO paper_hit VALUES (?,?,?,?)", [
            ("22222222", pexa, "JX-594", "title"),       # code in a title: counts
            ("33333333", pexa, "JX-594", "abstract"),    # code only in an abstract: review
            ("44444444", pexa, "pexastimogene devacirepvec", "abstract"),  # INN in an abstract: counts
            ("11111111", pexa, "JX-594", "abstract")])   # weaker evidence for an existing link: ignored
        con.execute("INSERT INTO paper VALUES ('22222222','JX-594 in HCC','J',2010,'clinical_trial',NULL,NULL)")
        con.execute("INSERT INTO grant_award VALUES ('R01CA000001','Pexa-Vec biology','Univ','Smith, J',2010,2014,NULL)")
        con.executemany("INSERT INTO grant_hit VALUES (?,?,?,?)", [
            ("R01CA000001", pexa, "Pexa-Vec", "title"), ("R21CA000002", pexa, "JX-594", "terms")])
        con.commit()
        con.close()
        br.build(REPO_REGISTRY, self.snapdb, self.out, today="2026-11-22", log=self.logs.append, evidence=ev)
        links = {p: (m, st) for p, m, st in rows(self.out, "SELECT pmid, method, status FROM paper_link")}
        self.assertEqual(links["11111111"], ("trial_reference", "auto"))
        self.assertEqual(links["22222222"], ("title", "auto"))
        self.assertEqual(links["33333333"], ("abstract", "candidate"))
        self.assertEqual(links["44444444"], ("abstract", "auto"))
        self.assertEqual(rows(self.out, "SELECT title FROM paper WHERE pmid='22222222'"), [("JX-594 in HCC",)])
        grants = {g: (m, st) for g, m, st in rows(self.out, "SELECT core_project_num, method, status FROM grant_link")}
        self.assertEqual(grants, {"R01CA000001": ("title", "auto"), "R21CA000002": ("terms", "candidate")})
        # Trial conditions are kept for disease views (e.g. pancreatic cancer).
        (conds,), = rows(self.out, "SELECT conditions FROM trial WHERE nct_id='NCT01'")
        self.assertIn("Renal Cell Carcinoma", json.loads(conds))

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
