"""Offline tests for fill_host_taxon.resolve(): exact name, reclassified name, refusals.

Built from the real failure of 2026-11-14: NCBI has reclassified Mycobacterium
abscessus as Mycobacteroides abscessus, so a [Scientific Name] search for the
name the registry holds returns nothing. NCBI is never called here; every
reply is canned.
"""

import io
import json
import os
import sys
import unittest
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import fill_host_taxon                                 # noqa: E402

ABSCESSUS_XML = """<?xml version="1.0"?><TaxaSet><Taxon>
<TaxId>36809</TaxId><ScientificName>Mycobacteroides abscessus</ScientificName>
<Rank>species</Rank>
<OtherNames><Synonym>Mycobacterium abscessus</Synonym>
<Synonym>Mycobacterium chelonae subsp. abscessus</Synonym></OtherNames>
<LineageEx><Taxon><TaxId>1762</TaxId><ScientificName>Mycobacteriales</ScientificName></Taxon></LineageEx>
</Taxon></TaxaSet>"""


def esearch(ids):
    return json.dumps({"esearchresult": {"idlist": ids}})


def esummary(taxid, science, rank):
    return json.dumps({"result": {taxid: {"scientificname": science, "rank": rank}}})


class ResolveTest(unittest.TestCase):

    def setUp(self):
        self.canned = {}
        self._urlopen = urllib.request.urlopen
        self._sleep = fill_host_taxon.time.sleep
        urllib.request.urlopen = self._fake_urlopen
        fill_host_taxon.time.sleep = lambda seconds: None

    def tearDown(self):
        urllib.request.urlopen = self._urlopen
        fill_host_taxon.time.sleep = self._sleep

    def _fake_urlopen(self, url, timeout=0):
        for fragment, body in self.canned.items():
            if fragment in url:
                return io.BytesIO(body.encode("utf-8"))
        raise AssertionError("the resolver asked for something unexpected: " + url)

    def test_current_scientific_name_is_taken_straight(self):
        self.canned = {"Scientific%20Name": esearch(["562"]),
                       "esummary": esummary("562", "Escherichia coli", "species")}
        self.assertEqual(fill_host_taxon.resolve("Escherichia coli"), ("562", "species", ""))

    def test_reclassified_name_matches_as_a_synonym(self):
        self.canned = {"Scientific%20Name": esearch([]),
                       "All%20Names": esearch(["36809"]),
                       "esummary": esummary("36809", "Mycobacteroides abscessus", "species"),
                       "efetch": ABSCESSUS_XML}
        self.assertEqual(fill_host_taxon.resolve("Mycobacterium abscessus"),
                         ("36809", "species", "synonym of Mycobacteroides abscessus"))

    def test_a_taxon_that_does_not_carry_our_name_is_refused(self):
        self.canned = {"Scientific%20Name": esearch([]),
                       "All%20Names": esearch(["36809"]),
                       "esummary": esummary("36809", "Mycobacteroides abscessus", "species"),
                       "efetch": ABSCESSUS_XML.replace(
                           "<Synonym>Mycobacterium abscessus</Synonym>", "")}
        with self.assertRaises(SystemExit) as stopped:
            fill_host_taxon.resolve("Mycobacterium abscessus")
        self.assertIn("does not list", str(stopped.exception))

    def test_two_scientific_name_hits_are_refused(self):
        self.canned = {"Scientific%20Name": esearch(["1", "2"])}
        with self.assertRaises(SystemExit) as stopped:
            fill_host_taxon.resolve("Bacillus whatever")
        self.assertIn("is the scientific name of 2 taxa", str(stopped.exception))

    def test_no_hit_at_all_is_refused(self):
        self.canned = {"Scientific%20Name": esearch([]), "All%20Names": esearch([])}
        with self.assertRaises(SystemExit) as stopped:
            fill_host_taxon.resolve("Not A Bacterium")
        self.assertIn("matched 0 taxonomy ids under any name", str(stopped.exception))

    def test_a_rank_below_species_is_refused(self):
        self.canned = {"Scientific%20Name": esearch(["1280"]),
                       "esummary": esummary("1280", "Staphylococcus aureus", "no rank")}
        with self.assertRaises(SystemExit) as stopped:
            fill_host_taxon.resolve("Staphylococcus aureus")
        self.assertIn("expected genus or species", str(stopped.exception))


if __name__ == "__main__":
    unittest.main()
