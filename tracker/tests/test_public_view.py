"""The public MCP view (agent/public_view.py): strong matches only, plain names, no empties."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "agent"))
import public_view as pv  # noqa: E402


def raw_program(**over):
    raw = {
        "registry_release": "2026-11-11+abc",
        "query": "CAN-2409",
        "program": {"axp_id": "AXP000144", "preferred_name": "aglatimagene besadenovec", "status": "active",
                    "modality": "Viral vector gene therapy", "platform": "Ad5", "targets": [],
                    "originator": "Advantagene", "sponsor": "Candel Therapeutics", "ncit": "C73996",
                    "wikidata": "", "unii": "5Z72SSS34W", "entry_version": 1, "notes": "A note."},
        "virus": {"role": "in_vivo_gene_transfer", "virus_family": "Adenoviridae", "virus": "human adenovirus 5",
                  "ncbi_taxon": "28285", "strain": "Ad5", "replication": "non_replicating", "modifications": "E1-deleted",
                  "transgenes": ["HSV-TK"], "route": ["intratumoral"], "carrier": "", "evidence_url": "https://ev"},
        "approvals": [],
        "aliases": [
            {"alias": "aglatimagene besadenovec", "alias_type": "preferred", "ambiguous": False, "source": "curator",
             "evidence_url": ""},
            {"alias": "aglatimagene besadenovec", "alias_type": "inn", "ambiguous": False, "source": "ncit",
             "evidence_url": "https://ncit"},
            {"alias": "CAN-2409", "alias_type": "code", "ambiguous": False, "source": "ncit",
             "evidence_url": "https://ncit"},
            {"alias": "ProstAtak", "alias_type": "brand", "ambiguous": False, "source": "ncit",
             "evidence_url": "https://ncit"},
        ],
        "trials": [
            {"nct_id": "NCT01436968", "brief_title": "ProstAtak phase 3", "overall_status": "ACTIVE_NOT_RECRUITING",
             "phases": "PHASE3", "start_date": "2011-09-20", "link_method": "intervention_name",
             "link_confidence": 0.95, "link_status": "auto", "has_results": False},
            {"nct_id": "NCT00000002", "brief_title": "title-only match", "phases": "PHASE1",
             "link_method": "title", "link_confidence": 0.6, "link_status": "auto"},
            {"nct_id": "NCT00000003", "brief_title": "ambiguous", "phases": "PHASE2",
             "link_method": "intervention_name", "link_confidence": 0.95, "link_status": "candidate"},
        ],
        "papers": [
            {"pmid": "1", "title": "abstract only", "year": 2025, "kind": "clinical_trial",
             "link_method": "abstract", "link_confidence": 0.6, "link_status": "auto"},
            {"pmid": "2", "title": "Phase 3 of CAN-2409", "year": 2026, "kind": "clinical_trial",
             "link_method": "title", "link_confidence": 0.85, "link_status": "auto"},
            {"pmid": "3", "title": "results", "year": 2019, "kind": "clinical_trial", "nct_id": "NCT01436968",
             "link_method": "trial_reference", "link_confidence": 0.9, "link_status": "auto"},
            {"pmid": "4", "title": "AdV-tk paper", "year": 2023, "kind": "other",
             "link_method": "title", "link_confidence": 0.85, "link_status": "candidate"},
        ],
        "grants": [
            {"core_project_num": "R44CA124032", "title": "ProstAtak", "org": "ADVANTAGENE", "pi": "X",
             "first_fy": 2007, "last_fy": 2013, "url": "https://reporter", "link_method": "title",
             "link_confidence": 0.85, "link_status": "auto"},
            {"core_project_num": "P01", "title": "GMCI", "link_method": "abstract", "link_status": "auto"},
        ],
        "recent_changes": [],
        "merged_from": None,
    }
    raw.update(over)
    return raw


class PublicProgramTest(unittest.TestCase):
    def setUp(self):
        self.out = pv.public_program(raw_program())

    def test_only_strong_trials(self):
        self.assertEqual([t["nct_id"] for t in self.out["trials"]], ["NCT01436968"])
        t = self.out["trials"][0]
        self.assertEqual(t["matched_by"], "named as an intervention")
        self.assertEqual(t["phase"], ["Phase 3"])
        self.assertEqual(t["status"], "active not recruiting")

    def test_only_strong_papers_results_first(self):
        self.assertEqual([p["pmid"] for p in self.out["key_papers"]], ["3", "2"])
        self.assertIn("NCT01436968", self.out["key_papers"][0]["matched_by"])
        self.assertEqual(self.out["key_papers"][1]["matched_by"], "named in the title")

    def test_only_title_grants(self):
        self.assertEqual([g["project"] for g in self.out["grants"]], ["R44CA124032"])
        self.assertEqual(self.out["grants"][0]["years"], "2007-2013")

    def test_no_scores_statuses_or_empties(self):
        text = repr(self.out)
        for word in ("link_status", "link_confidence", "link_method", "candidate", "'auto'", "''", "wikidata",
                     "carrier"):
            self.assertNotIn(word, text)

    def test_plain_identity(self):
        o = self.out
        self.assertEqual(o["id"], "AXP000144")
        self.assertEqual(o["page"], "https://abstractinator.me/registry/AXP000144.html")
        self.assertEqual(o["also_known_as"], ["ProstAtak", "CAN-2409"])     # brand first; no repeat of the name
        self.assertEqual(o["developer"], "Candel Therapeutics (originally Advantagene)")
        self.assertEqual(o["virus"]["replication"], "non-replicating")
        self.assertEqual(o["virus"]["role"], "in vivo gene delivery")
        self.assertEqual(o["approvals"], [])                                 # kept: "none" is an answer
        self.assertEqual(o["identifiers"], {"ncit": "C73996", "unii": "5Z72SSS34W"})
        self.assertNotIn("status", o)                                        # active is the default
        self.assertIn("about", o)

    def test_ambiguous_and_errors_pass_through(self):
        amb = pv.public_program({"registry_release": "r", "query": "ADV-tk", "program": None,
                                 "candidates": [{"axp_id": "AXP1", "preferred_name": "a"}]})
        self.assertEqual(amb["matches"], [{"id": "AXP1", "name": "a"}])
        self.assertEqual(pv.public_program({"error": "x"}), {"error": "x"})

    def test_merged_redirect(self):
        o = pv.public_program(raw_program(merged_from="AXP000999"))
        self.assertEqual(o["redirected_from"], "AXP000999")


class PublicSearchTest(unittest.TestCase):
    def test_record(self):
        r = {"title": "T", "abstract": "A", "source": "EPMC", "primary_cell": "Non-descript",
             "primary_virus": "Herpes Simplex Virus", "primary_bacteria": "Non-descript",
             "primary_modality": "Oncolytic virus", "is_bioinformatics": False, "pmid": "1", "pmcid": None,
             "is_open_access": "N", "is_retracted": False, "trial_status": None, "phase": None,
             "merged_from": "OpenAlex: 10.1/x"}
        out = pv.public_search({"results": [r], "returned": 1})
        rec = out["results"][0]
        self.assertEqual(rec["tags"], {"virus": "Herpes Simplex Virus", "therapy": "Oncolytic virus"})
        for k in ("merged_from", "trial_status", "pmcid", "primary_cell", "is_retracted", "open_access"):
            self.assertNotIn(k, rec)
        self.assertEqual(out["returned"], 1)

    def test_flags_kept_when_true(self):
        rec = pv.public_record({"title": "T", "is_retracted": True, "is_open_access": "Y",
                                "is_bioinformatics": True})
        self.assertTrue(rec["retracted"])
        self.assertTrue(rec["open_access"])
        self.assertTrue(rec["tags"]["computational"])

    def test_errors_pass_through(self):
        self.assertEqual(pv.public_search({"error": "x"}), {"error": "x"})


if __name__ == "__main__":
    unittest.main()
