"""Tests for tracker/registry.py. Run from the repo root:
    python3 -m unittest discover -s tracker/tests -t .
"""

import csv
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import registry as reg  # noqa: E402

MODALITIES = {"Oncolytic virus", "Targeted small molecule", "CAR-T cell therapy"}


def program(axp_id, name="Name", status="active", replaced_by="", modality="Oncolytic virus", **kw):
    row = dict.fromkeys(reg.PROGRAM_COLUMNS, "")
    row.update(axp_id=axp_id, status=status, replaced_by=replaced_by, preferred_name=name,
               modality=modality, entry_version="1", created="2026-11-11", updated="2026-11-11")
    row.update(kw)
    return row


def alias(axp_id, name, ambiguous="0", status="accepted", **kw):
    row = dict.fromkeys(reg.ALIAS_COLUMNS, "")
    row.update(axp_id=axp_id, alias=name, alias_type="code", source="curator",
               source_record="NCT00000000", licence="CC0-1.0", ambiguous=ambiguous,
               status=status, added="2026-11-11")
    row.update(kw)
    return row


class RegistryCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write(self, programs, aliases):
        for name, cols, rows in (("programs.tsv", reg.PROGRAM_COLUMNS, programs),
                                 ("aliases.tsv", reg.ALIAS_COLUMNS, aliases)):
            with open(os.path.join(self.dir, name), "w", encoding="utf-8") as fh:
                fh.write("\t".join(cols) + "\n")
                for r in rows:
                    fh.write("\t".join(r[c] for c in cols) + "\n")

    def problems(self, programs, aliases):
        self.write(programs, aliases)
        return reg.validate(self.dir, modalities=MODALITIES)

    def assertProblem(self, problems, fragment):
        self.assertTrue(any(fragment in p for p in problems),
                        "expected a problem mentioning %r, got %r" % (fragment, problems))


class AliasKey(unittest.TestCase):
    def test_shared_cases(self):
        # The same file will check the R implementation, so both agree.
        with open(os.path.join(HERE, "alias_keys.tsv"), encoding="utf-8", newline="") as fh:
            cases = list(csv.DictReader(fh, delimiter="\t"))
        self.assertGreater(len(cases), 5)
        for c in cases:
            self.assertEqual(reg.alias_key(c["name"]), c["key"], c["note"])

    def test_empty(self):
        self.assertEqual(reg.alias_key(None), "")
        self.assertEqual(reg.alias_key(" - "), "")


class Validate(RegistryCase):
    def test_repo_registry_is_valid(self):
        self.assertEqual(reg.validate(), [])

    def test_good_registry(self):
        p = [program("AXP000001", "MRTX1133", modality="Targeted small molecule"),
             program("AXP000002", "talimogene laherparepvec")]
        a = [alias("AXP000001", "MRTX-1133"), alias("AXP000002", "T-VEC"),
             alias("AXP000002", "Imlygic", alias_type="brand")]
        self.assertEqual(self.problems(p, a), [])

    def test_bad_id_and_gap(self):
        probs = self.problems([program("AXP1"), program("AXP000003")], [])
        self.assertProblem(probs, "6 digits")
        self.assertProblem(probs, "missing AXP000001")

    def test_duplicate_id(self):
        self.assertProblem(self.problems([program("AXP000001"), program("AXP000001", "Other")], []),
                           "duplicate ID")

    def test_unknown_modality(self):
        self.assertProblem(self.problems([program("AXP000001", modality="Magic")], []), "modality")

    def test_merge_rules(self):
        p = [program("AXP000001", "A"), program("AXP000002", "B", status="merged")]
        self.assertProblem(self.problems(p, []), "need replaced_by")
        p = [program("AXP000001", "A", status="merged", replaced_by="AXP000002"),
             program("AXP000002", "B", status="merged", replaced_by="AXP000001")]
        self.assertProblem(self.problems(p, []), "not active")
        p = [program("AXP000001", "A"), program("AXP000002", "B", status="merged", replaced_by="AXP000001")]
        self.assertEqual(self.problems(p, []), [])
        self.assertProblem(self.problems(p, [alias("AXP000002", "B-1")]), "move its aliases")

    def test_collision_between_programs(self):
        p = [program("AXP000001", "Alpha"), program("AXP000002", "Beta")]
        probs = self.problems(p, [alias("AXP000002", "ALPHA ")])
        self.assertProblem(probs, "leading or trailing")
        probs = self.problems(p, [alias("AXP000002", "al-pha")])
        self.assertProblem(probs, "belongs to AXP000001, AXP000002")
        # An alias marked ambiguous may share another program's name.
        self.assertEqual(self.problems(p, [alias("AXP000002", "al-pha", ambiguous="1")]), [])
        # Proposed and rejected aliases don't count.
        self.assertEqual(self.problems(p, [alias("AXP000002", "al-pha", status="proposed")]), [])

    def test_same_key_twice_for_one_program(self):
        p = [program("AXP000001", "Alpha")]
        probs = self.problems(p, [alias("AXP000001", "XY-1"), alias("AXP000001", "XY 1")])
        self.assertProblem(probs, "listed more than once")
        # Listing the preferred name as an alias is fine.
        self.assertEqual(self.problems(p, [alias("AXP000001", "Alpha", alias_type="inn")]), [])

    def test_alias_fields(self):
        p = [program("AXP000001")]
        probs = self.problems(p, [alias("AXP000001", "X1", licence="CC-BY-SA-3.0", alias_type="nick",
                                        ambiguous="yes", valid_from="May 2020",
                                        source_record="")])
        for frag in ("licence", "alias_type", "ambiguous", "valid_from", "evidence_url"):
            self.assertProblem(probs, frag)
        self.assertProblem(self.problems(p, [alias("AXP000009", "X1")]), "no such program")

    def test_structure(self):
        with open(os.path.join(self.dir, "programs.tsv"), "w") as fh:
            fh.write("axp_id\tname\n")
        with open(os.path.join(self.dir, "aliases.tsv"), "w") as fh:
            fh.write("\t".join(reg.ALIAS_COLUMNS) + "\nAXP000001\tonly two\n")
        probs = reg.validate(self.dir, modalities=MODALITIES)
        self.assertProblem(probs, "header should be")
        self.assertProblem(probs, "cells, expected")

    def test_next_id(self):
        self.write([program("AXP000001"), program("AXP000002", "B")], [])
        self.assertEqual(reg.next_id(self.dir), "AXP000003")


class VirusAndApprovals(RegistryCase):
    def write_extra(self, viruses=(), approvals=()):
        for name, cols, rows in (("virus.tsv", reg.VIRUS_COLUMNS, viruses),
                                 ("approvals.tsv", reg.APPROVAL_COLUMNS, approvals)):
            with open(os.path.join(self.dir, name), "w", encoding="utf-8") as fh:
                fh.write("\t".join(cols) + "\n")
                for r in rows:
                    fh.write("\t".join(r.get(c, "") for c in cols) + "\n")

    def virus(self, **kw):
        row = dict(axp_id="AXP000001", role="oncolytic", virus_family="Herpesviridae",
                   virus="herpes simplex virus 1", ncbi_taxon="10298", strain="JS1",
                   replication="conditionally_replicating", modifications="ICP34.5 and ICP47 deleted",
                   transgenes="CSF2", route="intratumoral", evidence_url="https://example.org/tvec")
        row.update(kw)
        return row

    def approval(self, **kw):
        row = dict(axp_id="AXP000001", agency="FDA", region="US", date="2015-10-27", status="approved",
                   brand="Imlygic", indication="melanoma", evidence_url="https://example.org/label")
        row.update(kw)
        return row

    def check(self, viruses=(), approvals=()):
        self.write([program("AXP000001", "talimogene laherparepvec"), program("AXP000002", "B", status="merged",
                                                                             replaced_by="AXP000001")], [])
        self.write_extra(viruses, approvals)
        return reg.validate(self.dir, modalities=MODALITIES)

    def test_good(self):
        self.assertEqual(self.check([self.virus(route="intratumoral; intravenous")], [self.approval()]), [])

    def test_missing_files_are_empty(self):
        self.write([program("AXP000001")], [])
        self.assertEqual(reg.validate(self.dir, modalities=MODALITIES), [])

    def test_virus_rules(self):
        probs = self.check([self.virus(role="cure", virus_family="herpes", ncbi_taxon="HSV",
                                       replication="sometimes", route="intratumoral; by post",
                                       evidence_url="")])
        for frag in ("role", "virus_family", "ncbi_taxon", "replication", "by post", "evidence_url"):
            self.assertProblem(probs, frag)
        self.assertProblem(self.check([self.virus(), self.virus()]), "second row")
        self.assertProblem(self.check([self.virus(axp_id="AXP000002")]), "use the active entry")
        self.assertEqual(self.check([self.virus(virus_family="Caudoviricetes", role="phage")]), [])

    def test_approval_rules(self):
        probs = self.check(approvals=[self.approval(agency="FDA2", region="USA", date="Oct 2015",
                                                    status="maybe", indication="")])
        for frag in ("agency", "region", "date", "status", "indication"):
            self.assertProblem(probs, frag)


class Modalities(unittest.TestCase):
    def test_reads_the_app_list(self):
        names = reg.modality_names()
        self.assertIn("Oncolytic virus", names)
        self.assertIn("CAR-T cell therapy", names)
        self.assertIn("Microbiome therapy", names)
        self.assertEqual(len(names), len(set(names)))
        self.assertGreaterEqual(len(names), 20)


if __name__ == "__main__":
    unittest.main()
