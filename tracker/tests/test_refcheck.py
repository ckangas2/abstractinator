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


class FetchManners(unittest.TestCase):
    """How fetch() treats throttling, repeats and server errors. Found on
    2026-11-11: nine EMA pages in a row answered 429 and the run reported them
    as dead links."""

    def setUp(self):
        refcheck._seen.clear()
        refcheck._last.clear()
        self.slept = []
        self.opened = []
        self._sleep = refcheck.time.sleep
        refcheck.time.sleep = self.slept.append
        self.addCleanup(setattr, refcheck.time, "sleep", self._sleep)
        self._urlopen = refcheck.urllib.request.urlopen
        self.addCleanup(setattr, refcheck.urllib.request, "urlopen", self._urlopen)
        self.addCleanup(refcheck._seen.clear)
        self.addCleanup(refcheck._last.clear)

    def serve(self, codes):
        """Answer each call with the next code; 200 means a good reply."""
        codes = list(codes)

        class Resp:
            status = 200

            def read(self, *a):
                return b"body"

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def fake(req, timeout=None):
            self.opened.append(req.full_url)
            code = codes.pop(0) if codes else 200
            if code == 200:
                return Resp()
            raise refcheck.urllib.error.HTTPError(req.full_url, code, "no", None, None)

        refcheck.urllib.request.urlopen = fake

    def test_429_is_retried_patiently_then_succeeds(self):
        self.serve([429, 429, 200])
        ok, detail, _ = refcheck.fetch("https://www.ema.europa.eu/en/medicines/human/EPAR/x")
        self.assertTrue(ok, detail)
        self.assertEqual(len(self.opened), 3)
        self.assertGreaterEqual(max(self.slept), refcheck.THROTTLE_BACKOFF)

    def test_a_url_is_fetched_once_per_run(self):
        self.serve([200])
        url = "https://example.org/shared"
        first = refcheck.fetch(url)
        second = refcheck.fetch(url)
        self.assertTrue(first[0] and second[0])
        self.assertEqual(len(self.opened), 1)
        self.assertIn("already checked", second[1])

    def test_404_is_not_retried(self):
        self.serve([404])
        ok, detail, _ = refcheck.fetch("https://example.org/gone")
        self.assertFalse(ok)
        self.assertEqual(detail, "HTTP 404")
        self.assertEqual(len(self.opened), 1)

    def test_throttling_host_gets_its_own_interval(self):
        self.assertGreater(refcheck.HOST_PAUSE["www.ema.europa.eu"], refcheck.PAUSE_SECONDS)

    def test_no_single_wait_is_longer_than_the_cap(self):
        # 2026-11-11: uncapped doubling slept 160 s in silence and looked hung.
        # Two kinds of sleep happen here: the retry backoff, capped by
        # THROTTLE_MAX_WAIT, and this host's own pacing interval. Both are
        # bounded, so a throttled-out URL costs a known, small amount of time.
        host_gap = refcheck.HOST_PAUSE["www.ema.europa.eu"]
        self.serve([429, 429, 429, 429, 429])
        ok, _, _ = refcheck.fetch("https://www.ema.europa.eu/en/medicines/human/EPAR/y")
        self.assertFalse(ok)
        self.assertLessEqual(max(self.slept), max(refcheck.THROTTLE_MAX_WAIT, host_gap))
        budget = (refcheck.THROTTLE_MAX_WAIT + host_gap) * (refcheck.THROTTLE_RETRIES + 1)
        self.assertLessEqual(sum(self.slept), budget)
        self.assertLess(budget, 300, "a single URL must not be able to eat five minutes")

    def test_an_ema_link_is_confirmed_from_the_published_lists(self):
        # 2026-11-11: EMA's medicine pages answer 429 to any robot, so they are
        # checked against the lists EMA publishes instead of being fetched.
        refcheck._ema_index[0] = None
        self.addCleanup(lambda: refcheck._ema_index.__setitem__(0, None))
        meds = {"data": [{"medicine_url": "https://www.ema.europa.eu/en/medicines/human/EPAR/glybera"}]}
        docs = {"data": [{"document_url": "https://www.ema.europa.eu/en/documents/x_en.pdf",
                          "translations": {"fr": "https://www.ema.europa.eu/fr/documents/x_fr.pdf"}}]}
        reads = [meds, docs]
        refcheck._read_json = lambda url: reads.pop(0) if reads else None
        self.addCleanup(setattr, refcheck, "_read_json", refcheck._read_json)
        self.serve([])  # any live fetch here would answer 200, so a pass must
                        # come from the lists, which the call count proves
        ok, detail = refcheck.check_url("https://www.ema.europa.eu/en/medicines/human/EPAR/glybera")
        self.assertTrue(ok)
        self.assertIn("published data", detail)
        self.assertEqual(self.opened, [], "a listed EMA link is not fetched")
        ok, detail = refcheck.check_url("https://www.ema.europa.eu/fr/documents/x_fr.pdf")
        self.assertTrue(ok, "translations count too")
        self.assertEqual(self.opened, [])
        # something EMA does not list still gets asked for directly
        ok, _ = refcheck.check_url("https://www.ema.europa.eu/en/documents/older_en.pdf")
        self.assertTrue(ok)
        self.assertEqual(len(self.opened), 1)

    def test_a_throttled_out_url_says_it_is_not_known_to_be_dead(self):
        self.serve([429, 429, 429, 429, 429])
        ok, detail, _ = refcheck.fetch("https://www.ema.europa.eu/en/medicines/human/EPAR/z")
        self.assertFalse(ok)
        self.assertIn("429", detail)
        self.assertIn("not shown to be dead", detail)


if __name__ == "__main__":
    unittest.main()


class NctReplies(unittest.TestCase):
    """What check_nct() makes of odd replies from the ClinicalTrials.gov API.
    Both cases are real, from the AAV batch of 2026-11-11: AXP000289's lookup
    answered with something that was not JSON, and AXP000298's answered with a
    different NCT id, and the run called both of them bad citations when the
    study pages were live in the same pass."""

    def setUp(self):
        refcheck._seen.clear()
        self.asked = []
        self.slept = []
        self._sleep = refcheck.time.sleep
        refcheck.time.sleep = self.slept.append
        self.addCleanup(setattr, refcheck.time, "sleep", self._sleep)
        self._fetch = refcheck.fetch
        self.addCleanup(setattr, refcheck, "fetch", self._fetch)
        self.addCleanup(refcheck._seen.clear)

    def serve(self, bodies):
        bodies = list(bodies)

        def fake(url, accept="*/*"):
            self.asked.append(url)
            body = bodies.pop(0) if bodies else bodies_last[0]
            bodies_last[0] = body
            return True, "HTTP 200", body

        bodies_last = [b""]
        refcheck.fetch = fake

    @staticmethod
    def study(nct):
        return ('{"protocolSection": {"identificationModule": {"nctId": "%s"}}}'
                % nct).encode()

    def test_a_reply_that_is_not_json_is_retried_before_judging_it(self):
        self.serve([b"<html>sorry</html>", self.study("NCT04693598")])
        ok, detail = refcheck.check_nct("NCT04693598")
        self.assertTrue(ok, detail)
        self.assertEqual(detail, "found")
        self.assertEqual(len(self.asked), 2)

    def test_a_reply_that_is_never_json_fails_and_says_how_many_tries(self):
        self.serve([b"<html>sorry</html>"] * (refcheck.THROTTLE_RETRIES + 1))
        ok, detail = refcheck.check_nct("NCT04693598")
        self.assertFalse(ok)
        self.assertIn("not JSON", detail)
        self.assertIn("tries", detail)

    def test_a_superseded_id_is_reached_not_dead(self):
        self.serve([self.study("NCT05739643")])
        ok, detail = refcheck.check_nct("NCT04693598")
        self.assertTrue(ok, detail)
        self.assertIn("NCT05739643", detail)

    def test_a_reply_with_no_id_at_all_is_a_failure(self):
        self.serve([b'{"protocolSection": {}}'])
        ok, detail = refcheck.check_nct("NCT04693598")
        self.assertFalse(ok)
        self.assertIn("no NCT id", detail)

    def test_no_single_wait_is_longer_than_the_cap(self):
        self.serve([b"x"] * (refcheck.THROTTLE_RETRIES + 1))
        refcheck.check_nct("NCT04693598")
        self.assertTrue(self.slept)
        self.assertLessEqual(max(self.slept), refcheck.THROTTLE_MAX_WAIT)
