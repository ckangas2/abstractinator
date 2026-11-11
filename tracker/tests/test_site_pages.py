"""Tests for tracker/site_pages.py: the registry's static web pages."""

import contextlib
import io
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
import build_registry as br  # noqa: E402
import site_pages as sp  # noqa: E402
import snapshot_trials as snap  # noqa: E402
from test_build_registry import REPO_REGISTRY, rows, trial  # noqa: E402
from test_snapshot import FakeAPI  # noqa: E402

snap.PAUSE_SECONDS = 0


def with_conditions(study, conditions):
    study["protocolSection"]["conditionsModule"]["conditions"] = list(conditions)
    return study


class Site(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        # A copy of the real registry plus a merged and a retired ID.
        cls.registry = os.path.join(cls.dir, "registry")
        shutil.copytree(REPO_REGISTRY, cls.registry)
        programs, _ = br.reg.read_tsv(os.path.join(cls.registry, "programs.tsv"), br.reg.PROGRAM_COLUMNS)
        n = max(int(p["axp_id"][3:]) for p in programs)
        cls.merged, cls.retired = "AXP%06d" % (n + 1), "AXP%06d" % (n + 2)
        with open(os.path.join(cls.registry, "programs.tsv"), "a", encoding="utf-8") as fh:
            fh.write("\t".join([cls.merged, "merged", "AXP000001", "OncoVEX duplicate", "Oncolytic virus"]
                               + [""] * 7 + ["1", "2026-11-11", "2026-11-12", "Same product as AXP000001."]) + "\n")
            fh.write("\t".join([cls.retired, "obsolete", "", "not a program", "Oncolytic virus"]
                               + [""] * 7 + ["1", "2026-11-11", "2026-11-12", "Entered in error."]) + "\n")
        assert not br.reg.validate(cls.registry), br.reg.validate(cls.registry)

        trials = [
            with_conditions(trial("NCT01", "Imlygic", title="T-VEC <script>alert(1)</script> & friends"),
                            ["Pancreatic Cancer", "Metastatic Disease"]),
            trial("NCT02", "Pexa-Vec", title="Pexa-Vec in liver cancer"),      # renal/kidney conditions only
            trial("NCT03", "Sotorasib", title="Sotorasib in PANCREATIC ductal adenocarcinoma"),  # title only
            trial("NCT04", "Placebo", title="JAB-21822 in pancreatic cancer"),  # candidate link only
        ]
        cls.snapdb = os.path.join(cls.dir, "trials.sqlite")
        snap.take_snapshot(cls.snapdb, [("onc", "oncolytic")], today="2026-11-11",
                           get=FakeAPI({"oncolytic": trials}), log=lambda *a: None)
        trials[1] = trial("NCT02", "Pexa-Vec", title="Pexa-Vec in liver cancer", status="TERMINATED")
        snap.take_snapshot(cls.snapdb, [("onc", "oncolytic")], today="2026-11-15",
                           get=FakeAPI({"oncolytic": trials}), log=lambda *a: None)
        cls.db = os.path.join(cls.dir, "registry.sqlite")
        br.build(cls.registry, cls.snapdb, cls.db, today="2026-11-16", log=lambda *a: None)
        cls.ids = {name: rows(cls.db, "SELECT axp_id FROM program WHERE preferred_name=?", name)[0][0]
                   for name in ("talimogene laherparepvec", "pexastimogene devacirepvec", "sotorasib", "glecirasib")}
        # Papers and grants as tracker/evidence.py would leave them.
        tvec = cls.ids["talimogene laherparepvec"]
        con = sqlite3.connect(cls.db)
        con.execute("INSERT INTO paper VALUES ('11111111','T-VEC in melanoma','J Clin Oncol',2015,"
                    "'clinical_trial',NULL,NULL)")
        con.execute("INSERT INTO paper VALUES ('44444444','T-VEC in a mouse model','Mol Ther',2019,"
                    "'other',NULL,NULL)")
        con.executemany("INSERT INTO paper_link VALUES (?,?,?,?,?,?,?)", [
            (tvec, "11111111", "title", "T-VEC", None, 0.85, "auto"),
            (tvec, "22222222", "trial_reference", "NCT01", "NCT01", 0.9, "auto"),   # no paper row yet
            (tvec, "33333333", "abstract", "JS1", None, 0.6, "candidate"),
            (tvec, "44444444", "title", "T-VEC", None, 0.85, "auto")])
        con.execute("INSERT INTO grant_award VALUES ('R01CA000001','Oncolytic HSV biology','Univ','Smith, J',"
                    "2010,2014,'javascript:alert(1)')")
        con.execute("INSERT INTO grant_link VALUES (?,?,?,?,?,?)",
                    (tvec, "R01CA000001", "title", "T-VEC", 0.85, "auto"))
        con.commit()
        con.close()
        cls.out = os.path.join(cls.dir, "www", "registry")
        cls.logs = []
        sp.write_site(cls.db, cls.out, log=cls.logs.append)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir)

    def page(self, *parts):
        with open(os.path.join(self.out, *parts), encoding="utf-8") as fh:
            return fh.read()

    def test_index_lists_every_active_program(self):
        index = self.page("index.html")
        programs, _ = br.reg.read_tsv(os.path.join(self.registry, "programs.tsv"), br.reg.PROGRAM_COLUMNS)
        active = [p for p in programs if p["status"] == "active"]
        for p in active:
            self.assertIn('href="%s.html"' % p["axp_id"], index, p["axp_id"])
        self.assertNotIn('href="%s.html"' % self.merged, index)
        self.assertEqual(len(re.findall(r"<tr data-s=", index)), len(active))
        self.assertIn("<h2>Adenoviridae", re.sub(r'<section[^>]*>', "", index))
        self.assertIn('href="disease/pancreatic-cancer.html"', index)
        self.assertIn('href="../changes.html"', index)
        self.assertIn(sp.GITHUB_REGISTRY, index)
        self.assertIn("Not endorsed by NLM".lower(), index.lower())
        # T-VEC's row: its trial's phase, its approvals and one trial
        row = re.search(r'<tr data-s="[^"]*">(<td><a href="%s.html">.*?)</tr>' % self.ids["talimogene laherparepvec"],
                        index).group(1)
        self.assertIn("Phase 1/2", row)
        self.assertIn("yes (FDA, EMA)", row)
        self.assertIn("<td class=num>1</td>", row)
        self.assertIn("Imlygic", row)                     # a key name

    def test_program_page(self):
        tvec = self.ids["talimogene laherparepvec"]
        page = self.page("%s.html" % tvec)
        self.assertIn("<h1>talimogene laherparepvec</h1>", page)
        self.assertIn("%s.2" % tvec, page)                          # versioned ID
        for name in ("Imlygic", "T-VEC", "OncoVEX GM-CSF"):
            self.assertIn("<td>%s</td>" % name, page)
        self.assertIn("Orthoherpesviridae", page)
        self.assertIn("wwwtax.cgi?id=10298", page)
        self.assertIn("CSF2", page)
        self.assertIn("evsexplore/concept/ncit/C61314", page)
        self.assertIn("precision.fda.gov/uniisearch/srs/unii/07730V90L6", page)
        self.assertIn("<td>FDA</td>", page)
        self.assertIn("2015-10-27", page)
        self.assertIn('href="https://clinicaltrials.gov/study/NCT01"', page)
        self.assertIn("Metastatic Disease; Pancreatic Cancer", page)   # conditions, as the snapshot sorts them
        # papers: with metadata, without a paper row, and an unconfirmed one folded away
        self.assertIn("T-VEC in melanoma", page)
        self.assertIn('href="https://pubmed.ncbi.nlm.nih.gov/22222222/"', page)
        self.assertLess(page.index("<details>"), page.index("33333333"))
        # a preclinical paper goes under "Other papers", after the clinical ones;
        # a results paper with no details yet counts as clinical
        self.assertLess(page.index("<h2>Clinical papers</h2>"), page.index("22222222"))
        self.assertLess(page.index("22222222"), page.index("<h2>Other papers</h2>"))
        self.assertLess(page.index("<h2>Other papers</h2>"), page.index("T-VEC in a mouse model"))
        # a grant whose url isn't http(s) links to RePORTER instead
        self.assertIn('href="https://reporter.nih.gov/project-details/R01CA000001"', page)
        self.assertNotIn("javascript:", page)
        self.assertIn("issues/new?title=Registry%20correction%3A%20" + tvec, page)
        self.assertIn("How to cite", page)
        self.assertIn('<a href="index.html">Registry</a>', page)

    def test_candidates_and_changes(self):
        glec = self.page("%s.html" % self.ids["glecirasib"])
        self.assertIn("Unconfirmed matches (1)", glec)
        self.assertLess(glec.index("<details>"), glec.index("NCT04"))
        pexa = self.page("%s.html" % self.ids["pexastimogene devacirepvec"])
        self.assertIn("RECRUITING → TERMINATED", pexa)
        self.assertIn("2026-11-15", pexa)

    def test_merged_and_retired_ids_keep_a_page(self):
        merged = self.page("%s.html" % self.merged)
        self.assertIn("merged into", merged)
        self.assertIn('href="AXP000001.html"', merged)
        retired = self.page("%s.html" % self.retired)
        self.assertIn("retired", retired)
        self.assertIn("Entered in error.", retired)

    def test_pancreatic_view(self):
        page = self.page("disease", "pancreatic-cancer.html")
        self.assertIn('href="../%s.html"' % self.ids["talimogene laherparepvec"], page)   # by condition
        self.assertIn('href="../%s.html"' % self.ids["sotorasib"], page)                  # by title
        self.assertNotIn(self.ids["pexastimogene devacirepvec"], page)                    # no PDAC trial
        self.assertNotIn(self.ids["glecirasib"], page)                                    # candidate link only
        self.assertIn("2 programs, 2 trials", page)
        self.assertIn('<a href="../index.html">Registry</a>', page)
        self.assertIn('href="../../changes.html"', page)

    def test_everything_is_escaped(self):
        for f in ("index.html", "%s.html" % self.ids["talimogene laherparepvec"],
                  os.path.join("disease", "pancreatic-cancer.html")):
            page = self.page(f)
            self.assertNotIn("<script>alert", page, f)
            self.assertNotIn("& friends", page, f)
        self.assertIn("T-VEC &lt;script&gt;alert(1)&lt;/script&gt; &amp; friends",
                      self.page("%s.html" % self.ids["talimogene laherparepvec"]))

    def test_swap_replaces_the_site(self):
        out = os.path.join(self.dir, "swap", "registry")
        os.makedirs(out)
        with open(os.path.join(out, "stale.html"), "w") as fh:
            fh.write("old")
        os.makedirs(out + ".tmp")                     # left over from a crashed run
        sp.write_site(self.db, out, log=lambda *a: None)
        self.assertFalse(os.path.exists(os.path.join(out, "stale.html")))
        self.assertTrue(os.path.isfile(os.path.join(out, "index.html")))
        self.assertEqual(sorted(os.listdir(os.path.dirname(out))), ["registry"])
        # A failure while writing leaves the old site untouched and no temp dir.
        orig = sp.disease_page
        sp.disease_page = lambda *a: 1 / 0
        try:
            with self.assertRaises(ZeroDivisionError):
                sp.write_site(self.db, out, log=lambda *a: None)
        finally:
            sp.disease_page = orig
        self.assertTrue(os.path.isfile(os.path.join(out, "disease", "pancreatic-cancer.html")))
        self.assertEqual(sorted(os.listdir(os.path.dirname(out))), ["registry"])

    def test_build_main_writes_the_site(self):
        out = os.path.join(self.dir, "main")
        args = ["--registry", self.registry, "--snapshots", self.snapdb, "--out", os.path.join(out, "r.sqlite"),
                "--evidence", ""]
        with contextlib.redirect_stdout(io.StringIO()):
            br.main(args + ["--page", os.path.join(out, "changes.html"), "--site", os.path.join(out, "registry")])
        self.assertTrue(os.path.isfile(os.path.join(out, "registry", "AXP000001.html")))
        # The atlas: written with the rest, its embedded data parses, and the
        # index links to it.
        with open(os.path.join(out, "registry", "atlas.html"), encoding="utf-8") as fh:
            atlas = fh.read()
        import json, re
        data = json.loads(re.search(r'id="atlas-data">(.*?)</script>', atlas, re.S).group(1))
        kinds = {n["kind"] for n in data["nodes"]}
        self.assertIn("virus", kinds)
        self.assertIn("family", kinds)
        ids = {n["id"] for n in data["nodes"]}
        self.assertTrue(all(a in ids and b in ids for a, b in data["links"]))
        self.assertNotIn("<script src", atlas)                    # loads nothing from elsewhere
        with open(os.path.join(out, "registry", "index.html"), encoding="utf-8") as fh:
            index = fh.read()
        self.assertIn('href="atlas.html"', index)
        self.assertIn('href="atlas-phage.html"', index)
        # Each atlas page carries the tab bar, marking itself as current.
        with open(os.path.join(out, "registry", "atlas-phage.html"), encoding="utf-8") as fh:
            phage = fh.read()
        self.assertIn('<a href="atlas-phage.html" aria-current="page">Phage therapy</a>', phage)
        self.assertIn('<a href="atlas.html" aria-current="page">Oncolytic viruses</a>', atlas)
        json.loads(re.search(r'id="atlas-data">(.*?)</script>', phage, re.S).group(1))
        with open(os.path.join(out, "changes.html"), encoding="utf-8") as fh:
            self.assertIn('href="registry/index.html"', fh.read())
        shutil.rmtree(out)
        with contextlib.redirect_stdout(io.StringIO()):
            br.main(args + ["--page", "", "--site", ""])
        self.assertEqual(os.listdir(out), ["r.sqlite"])

    def test_helpers(self):
        self.assertEqual(sp.phase_label("PHASE1/PHASE2"), "Phase 1/2")
        self.assertEqual(sp.phase_label("EARLY_PHASE1"), "Early phase 1")
        self.assertEqual(sp.phase_label("NA"), "")
        self.assertGreater(sp.phase_rank("PHASE2"), sp.phase_rank("PHASE1/PHASE2"))
        self.assertGreater(sp.phase_rank("PHASE1/PHASE2"), sp.phase_rank("PHASE1"))
        self.assertEqual(sp.safe_url("javascript:alert(1)"), "")
        self.assertEqual(sp.human("ACTIVE_NOT_RECRUITING"), "Active not recruiting")
        self.assertTrue(sp.matches_disease({"conditions": '["PDAC", "Pancreatic Neoplasms"]', "brief_title": ""},
                                           ["pancrea"]))
        self.assertFalse(sp.matches_disease({"conditions": None, "brief_title": "Liver"}, ["pancrea"]))



class AtlasFieldTest(unittest.TestCase):
    """The phage atlas uses the same code with its own programs, hubs and groups."""

    def test_phage_field(self):
        import atlas_page as ap
        prog = lambda i, name: {"axp_id": i, "preferred_name": name, "status": "active", "sponsor": "Acme"}
        d = {"programs": {"A1": prog("A1", "OV-1"), "P1": prog("P1", "Phage-1"), "P2": prog("P2", "Phage-2")},
             "virus": {"A1": {"role": "oncolytic", "virus_family": "Adenoviridae", "transgenes": "GM-CSF"},
                       "P1": {"role": "phage", "virus_family": "Caudoviricetes", "transgenes": "X",
                              "route": "topical"},
                       "P2": {"role": "phage", "virus_family": "Caudoviricetes"}},
             "trials": {"P1": [{"link_status": "auto", "conditions": '["Urinary Tract Infections"]',
                                "brief_title": "", "phase": "PHASE2"}]},
             "approvals": {}, "aliases": {}}
        data = ap.atlas_data(d, "phage")
        viruses = [n["id"] for n in data["nodes"] if n["kind"] == "virus"]
        self.assertEqual(viruses, ["P1", "P2"])                       # oncolytic left out
        kinds = {n["kind"] for n in data["nodes"]}
        self.assertNotIn("transgene", kinds)                          # no payload hubs for phage
        self.assertIn("sponsor", kinds)                               # Acme has 2 phage products
        p1 = next(n for n in data["nodes"] if n["id"] == "P1")
        self.assertEqual(p1["cancers"], ["Urinary tract"])
        self.assertEqual([n["id"] for n in ap.atlas_data(d)["nodes"] if n["kind"] == "virus"], ["A1"])

if __name__ == "__main__":
    unittest.main()
