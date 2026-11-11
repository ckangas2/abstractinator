"""Offline tests for tracker/refcheck.py: no network, every fetch stubbed."""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
import refcheck  # noqa: E402
import registry as reg  # noqa: E402

PROGRAM = ["AXP000001", "active", "", "thing one", "Oncolytic virus", "", "", "", "", "", "", "",
           "1", "2026-11-11", "2026-11-11", "tested in NCT00000001; see PMID 12345678"]
PROGRAM2 = ["AXP000002", "active", "", "thing two", "Oncolytic virus", "", "", "", "", "", "", "",
            "1", "2026-11-11", "2026-11-11", ""]


def alias(axp, name, status="proposed", url="https://example.org/one"):
    return [axp, name, "code", "ctgov", "NCT00000001", "public-domain", "", "", "0", status,
            url, "2026-11-11"]


class RefcheckTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="refcheck-test-")
        self.registry = os.path.join(self.dir, "registry")
        os.makedirs(self.registry)
        self.write("programs.tsv", reg.PROGRAM_COLUMNS, [PROGRAM, PROGRAM2])
        self.write("aliases.tsv", reg.ALIAS_COLUMNS,
                   [alias("AXP000001", "one"), alias("AXP000002", "two",
                                                     url="https://example.org/gone")])
        self.calls = []
        self._real_fetch = refcheck.fetch
        refcheck.fetch = self.fake_fetch
        self.addCleanup(setattr, refcheck, "fetch", self._real_fetch)
        self.addCleanup(shutil.rmtree, self.dir, True)

    def write(self, name, columns, rows):
        with open(os.path.join(self.registry, name), "w", encoding="utf-8") as fh:
            fh.write("\t".join(columns) + "\n")
            for r in rows:
                fh.write("\t".join(r) + "\n")

    def fake_fetch(self, *a, **kw):
        raise AssertionError("fetch takes a url")

    def fake(self, url, accept="*/*"):
        self.calls.append(url)
        if "gone" in url:
            return False, "HTTP 404", b""
        if "clinicaltrials.gov/api" in url:
            nct = url.rsplit("/", 1)[-1]
            return True, "HTTP 200", (
                '{"protocolSection": {"identificationModule": {"nctId": "%s"}}}' % nct).encode()
        if "eutils" in url:
            pmid = url.rsplit("=", 1)[-1]
            return True, "HTTP 200", ('{"result": {"%s": {"uid": "%s"}}}' % (pmid, pmid)).encode()
        return True, "HTTP 200", b"<html></html>"

    def run_main(self, *args):
        refcheck.fetch = self.fake
        return refcheck.main(["--registry", self.registry] + list(args))

    def aliases_now(self):
        rows, _ = reg.read_tsv(os.path.join(self.registry, "aliases.tsv"), reg.ALIAS_COLUMNS)
        return {r["alias"]: r["status"] for r in rows}

    def test_ranges_and_lists(self):
        self.assertEqual(refcheck.wanted_ids("AXP000215-AXP000217", []),
                         ["AXP000215", "AXP000216", "AXP000217"])
        self.assertEqual(refcheck.wanted_ids("AXP000001, AXP000009", []),
                         ["AXP000001", "AXP000009"])

    def test_finds_ncts_and_pmids_in_prose(self):
        refs = refcheck.references({"programs": [dict(zip(reg.PROGRAM_COLUMNS, PROGRAM))]},
                                   {"AXP000001"})
        self.assertEqual(refs["AXP000001"]["ncts"], {"NCT00000001"})
        self.assertEqual(refs["AXP000001"]["pmids"], {"12345678"})

    def test_everything_reachable_accepts(self):
        self.assertEqual(self.run_main("--programs", "AXP000001", "--accept",
                                       "--backup-dir", os.path.join(self.dir, "bak")), 0)
        self.assertEqual(self.aliases_now()["one"], "accepted")
        self.assertTrue(any("clinicaltrials.gov/api" in c for c in self.calls))
        self.assertTrue(any("eutils" in c for c in self.calls))
        self.assertTrue(os.listdir(os.path.join(self.dir, "bak")), "a backup is kept")

    def test_a_dead_link_blocks_only_its_own_program(self):
        rc = self.run_main("--programs", "AXP000001,AXP000002", "--accept",
                           "--backup-dir", os.path.join(self.dir, "bak"))
        self.assertEqual(rc, 1)
        now = self.aliases_now()
        self.assertEqual(now["one"], "accepted")
        self.assertEqual(now["two"], "proposed")

    def test_without_accept_nothing_is_written(self):
        self.assertEqual(self.run_main("--programs", "AXP000001"), 0)
        self.assertEqual(self.aliases_now()["one"], "proposed")

    def test_unknown_program_is_an_error(self):
        self.assertEqual(self.run_main("--programs", "AXP999999"), 2)


if __name__ == "__main__":
    unittest.main()
