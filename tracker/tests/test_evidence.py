"""Tests for tracker/evidence.py, with fake PubMed, Europe PMC and RePORTER APIs (no network)."""

import copy
import io
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
import urllib.error
from xml.sax.saxutils import escape
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import build_registry as br  # noqa: E402
import evidence as ev  # noqa: E402

ev.PAUSE_SECONDS = 0
REPO_REGISTRY = os.path.join(os.path.dirname(os.path.dirname(HERE)), "registry")
PEXA, TVEC = "AXP000011", "AXP000001"   # pexastimogene devacirepvec / JX-594 / Pexa-Vec; talimogene / T-VEC


def paper(pmid, title, abstract="", types=("Journal Article", "Clinical Trial, Phase II"), year="2011"):
    """A Europe PMC resultType=core record."""
    return {"id": pmid, "source": "MED", "pmid": pmid, "pmcid": "PMC" + pmid, "doi": "10.1/" + pmid,
            "title": title, "abstractText": abstract, "pubYear": year,
            "journalInfo": {"journal": {"title": "Lancet Oncol", "medlineAbbreviation": "LO"}},
            "pubTypeList": {"pubType": list(types)}}


def project(appl, core, fy, title, abstract="", terms="", org="Univ A", pi="SMITH, JANE"):
    """A RePORTER v2 project record (one fiscal year)."""
    return {"appl_id": appl, "core_project_num": core, "fiscal_year": fy, "project_title": title,
            "abstract_text": abstract, "terms": terms, "pref_terms": "",
            "organization": {"org_name": org}, "contact_pi_name": pi,
            "principal_investigators": [{"full_name": "Jane Smith", "is_contact_pi": True}]}


def pubmed_xml(records):
    """The same records as PubMed efetch XML. Titles may hold markup (<i>), as in PubMed."""
    out = ['<?xml version="1.0" ?>\n<PubmedArticleSet>']
    for r in records:
        types = "".join("<PublicationType>%s</PublicationType>" % escape(t) for t in r["pubTypeList"]["pubType"])
        out.append(
            '<PubmedArticle><MedlineCitation><PMID Version="1">%s</PMID><Article>'
            '<Journal><JournalIssue><PubDate><Year>%s</Year></PubDate></JournalIssue><Title>%s</Title></Journal>'
            '<ArticleTitle>%s</ArticleTitle><Abstract><AbstractText>%s</AbstractText></Abstract>'
            '<PublicationTypeList>%s</PublicationTypeList></Article></MedlineCitation>'
            '<PubmedData><ArticleIdList><ArticleId IdType="pubmed">%s</ArticleId>'
            '<ArticleId IdType="doi">%s</ArticleId><ArticleId IdType="pmc">%s</ArticleId>'
            '</ArticleIdList></PubmedData></PubmedArticle>'
            % (r["pmid"], r["pubYear"], escape(r["journalInfo"]["journal"]["title"]), r["title"],
               escape(r["abstractText"]), types, r["pmid"], r["doi"], r["pmcid"]))
    out.append("</PubmedArticleSet>")
    return "".join(out)


class FakeAPIs:
    """All three APIs. Paper records (Europe PMC's shape; served to PubMed as
    efetch XML) and RePORTER projects are served for a search that contains
    (quoted) one of the names they are filed under, with paging by cursorMark
    and by offset/limit. fail=True makes RePORTER fail. pubmed_count, if set,
    is the hit count esearch reports."""

    def __init__(self, papers=None, projects=None, epmc_page=2, fail=False, reject_fields=False, pubmed_count=None):
        self.papers, self.projects = papers or {}, projects or {}
        self.epmc_page, self.fail, self.reject_fields = epmc_page, fail, reject_fields
        self.pubmed_count = pubmed_count
        self.calls = []

    def _select(self, table, text):
        out, seen = [], set()
        for name, recs in table.items():
            if '"%s"' % name in text:
                for r in recs:
                    k = r.get("pmid") or r.get("appl_id")
                    if k not in seen:
                        seen.add(k)
                        out.append(r)
        return out

    def __call__(self, url, params=None, body=None, form=None, raw=False):
        self.calls.append((url, copy.deepcopy(params), copy.deepcopy(body or form)))
        if url == ev.ESEARCH_API:
            items = self._select(self.papers, form["term"])
            ids = [r["pmid"] for r in items][:int(form["retmax"])]
            count = self.pubmed_count if self.pubmed_count is not None else len(items)
            return {"esearchresult": {"count": str(count), "idlist": ids}}
        if url == ev.EFETCH_API:
            assert raw
            want = form["id"].split(",")
            recs = {r["pmid"]: r for recs in self.papers.values() for r in recs}
            return pubmed_xml([recs[i] for i in want])
        if url == ev.EPMC_API:
            items = self._select(self.papers, params["query"])
            start = 0 if params["cursorMark"] == "*" else int(params["cursorMark"])
            size = min(int(params["pageSize"]), self.epmc_page)
            page = items[start:start + size]
            nxt = str(start + size) if start + size < len(items) else params["cursorMark"]
            return {"hitCount": len(items), "nextCursorMark": nxt,
                    "resultList": {"result": copy.deepcopy(page)}}
        if url == ev.REPORTER_API:
            if self.fail:
                raise ev.FetchError("HTTP 503 from api.reporter.nih.gov")
            if self.reject_fields and "include_fields" in body:
                raise ev.BadRequest("HTTP 400: bad include_fields")
            items = self._select(self.projects, body["criteria"]["advanced_text_search"]["search_text"])
            off, lim = body["offset"], body["limit"]
            return {"meta": {"total": len(items), "offset": off, "limit": lim},
                    "results": copy.deepcopy(items[off:off + lim])}
        raise AssertionError("unexpected URL " + url)


def standard_apis(**kw):
    papers = {
        "JX-594": [
            paper("1001", "Phase II trial of JX-594 in liver cancer", "Patients got JX-594."),
            paper("1002", "Oncolytic vaccinia in HCC", "We gave pexastimogene devacirepvec (Pexa-Vec) to 30."),
            paper("1003", "A <i>JX 594</i> case", "x", types=("Case Reports",)),
            # The search engine's fuzzy match: no program's name is in it.
            paper("1004", "JX-59 something else", "unrelated"),
            paper("1005", "Meta-analysis of vaccinia", "JX594 was used", types=("Meta-Analysis", "Review")),
        ],
        "talimogene laherparepvec": [
            paper("2001", "T-VEC and JX-594 compared", "", types=("Randomized Controlled Trial",), year="2020"),
        ],
    }
    projects = {
        "JX-594": [
            project(11, "R01CA000001", 2012, "Old title", "about JX-594"),
            project(13, "R01CA000001", 2014, "Pexa-Vec biology", "about JX-594", org="Univ B", pi="DOE, J"),
            project(12, "R01CA000001", 2013, "Middle title", "about JX-594"),
            project(21, "R21CA000002", 2020, "Vaccinia platform", "", terms="<Oncolytic><JX-594><Liver>"),
            project(31, "R01CA000003", 2019, "Nothing named here", "nothing"),
        ],
    }
    return FakeAPIs(papers, projects, **kw)


class Pieces(unittest.TestCase):
    def test_kind(self):
        self.assertEqual(ev.paper_kind(["Journal Article", "Clinical Trial, Phase III"]), "clinical_trial")
        self.assertEqual(ev.paper_kind(["Randomized Controlled Trial"]), "clinical_trial")
        self.assertEqual(ev.paper_kind(["Case Reports", "Journal Article"]), "case_report")
        self.assertEqual(ev.paper_kind(["Review", "Clinical Study"]), "review")
        self.assertEqual(ev.paper_kind(["Observational Study"]), "clinical_other")
        self.assertEqual(ev.paper_kind(["Clinical Trial Protocol"]), "clinical_other")
        self.assertEqual(ev.paper_kind(["Journal Article"]), "other")
        self.assertEqual(ev.paper_kind([]), "other")

    def test_names_skip_short_keys_and_keep_spellings(self):
        names = ev.load_names(REPO_REGISTRY)
        self.assertTrue(all(len(n["alias_key"]) >= 4 for n in names))
        terms = ev.search_terms(names)
        self.assertIn("JX-594", terms)
        self.assertIn("pexastimogene devacirepvec", terms)
        self.assertEqual(len(terms), len({t.lower() for t in terms}))
        self.assertFalse(any('"' in t for t in terms))

    def test_query_shape_and_batches(self):
        q = ev.epmc_query(["JX-594", "T-VEC"])
        self.assertTrue(q.startswith('(TITLE:"JX-594" OR ABSTRACT:"JX-594" OR TITLE:"T-VEC" OR ABSTRACT:"T-VEC") '
                                     'AND SRC:MED AND (PUB_TYPE:"Clinical Trial" OR '))
        self.assertIn('PUB_TYPE:"Case Reports"', q)
        batches = ev.epmc_batches(ev.search_terms(ev.load_names(REPO_REGISTRY)))
        self.assertTrue(all(len(b) <= ev.EPMC_BATCH for b in batches))
        self.assertTrue(all(len(ev.urllib.parse.quote(ev.epmc_query(b))) <= ev.EPMC_MAX_QUERY
                            for b in batches if len(b) > 1))
        small = ev.epmc_batches(["a" * 50] * 10, batch=20, max_chars=600)
        self.assertGreater(len(small), 1)
        body = ev.reporter_body(["JX-594", "T-VEC"])
        self.assertEqual(body["criteria"]["advanced_text_search"],
                         {"operator": "or", "search_field": "projecttitle,terms,abstracttext",
                          "search_text": '"JX-594" "T-VEC"'})
        self.assertEqual(body["limit"], 500)

    def test_grouping_fiscal_years(self):
        rows = ev.grant_rows([
            project(11, "R01CA1", 2012, "Old", org="Univ A"),
            project(13, "R01CA1", 2014, "New", org="Univ B", pi="DOE, J"),
            project(12, "R01CA1", 2013, "Mid"),
            project(13, "R01CA1", 2014, "New", org="Univ B", pi="DOE, J"),   # same record twice
            project(99, None, 2014, "No core number"),
        ])
        self.assertEqual(rows, {"R01CA1": ("R01CA1", "New", "Univ B", "DOE, J", 2012, 2014,
                                           "https://reporter.nih.gov/project-details/13")})

    def test_retries_on_503_then_succeeds(self):
        calls = []

        def urlopen(req, timeout=None):
            calls.append(req)
            if len(calls) < 3:
                raise urllib.error.HTTPError(req.full_url, 503, "busy", {}, io.BytesIO(b""))
            return io.BytesIO(b'{"ok": 1}')

        sleeps = []
        with mock.patch.object(ev.urllib.request, "urlopen", urlopen):
            self.assertEqual(ev.http_json(ev.REPORTER_API, body={"x": 1}, sleep=sleeps.append), {"ok": 1})
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [5.0, 10.0])
        self.assertEqual(calls[0].get_method(), "POST")
        self.assertEqual(calls[0].get_header("User-agent"), ev.USER_AGENT)

    def test_slow_trickle_is_cut_off(self):
        class Slow:
            def __init__(self):
                self.n = 0
            def read(self, size):
                self.n += 1
                return b"x"
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
        clock = iter(range(0, 10 ** 6, 10))
        with mock.patch.object(ev.time, "monotonic", lambda: next(clock)):
            with self.assertRaises(TimeoutError):
                ev._read_all(Slow(), 60)
        # In http_json a cut-off read is retried like any network error, then fails.
        with mock.patch.object(ev.urllib.request, "urlopen", lambda req, timeout=None: Slow()), \
                mock.patch.object(ev, "REQUEST_DEADLINE", -1):
            with self.assertRaises(ev.FetchError):
                ev.http_json(ev.ESEARCH_API, form={"term": "x"}, sleep=lambda s: None)

    def test_form_post_and_raw(self):
        seen = []
        def urlopen(req, timeout=None):
            seen.append(req)
            return io.BytesIO(b"<x/>")
        with mock.patch.object(ev.urllib.request, "urlopen", urlopen):
            self.assertEqual(ev.http_json(ev.EFETCH_API, form={"id": "1,2"}, raw=True), "<x/>")
        self.assertEqual(seen[0].get_method(), "POST")
        self.assertEqual(seen[0].data, b"id=1%2C2")
        self.assertEqual(seen[0].get_header("Content-type"), "application/x-www-form-urlencoded")

    def test_pubmed_parsing(self):
        rec = ev.parse_pubmed_xml(pubmed_xml([paper("7", "A <i>JX 594</i> case", "Abs & more",
                                                    types=("Case Reports",))]))[0]
        self.assertEqual(rec, {"pmid": "7", "title": "A JX 594 case", "abstract": "Abs & more",
                               "journal": "Lancet Oncol", "year": 2011, "pub_types": ["Case Reports"],
                               "doi": "10.1/7", "pmcid": "PMC7"})
        self.assertEqual(ev.pubmed_query(["JX-594", "T-VEC"]), '("JX-594"[tiab] OR "T-VEC"[tiab])')
        q = ev.pubmed_query(["JX-594", "T-VEC"], clinical_only=True)
        self.assertTrue(q.startswith('("JX-594"[tiab] OR "T-VEC"[tiab]) AND ("Clinical Trial"[pt] OR '))

    def test_short_names_must_be_written_as_themselves(self):
        a = {"alias": "ON-01", "alias_key": "ON01"}
        for text in ("ON-01 in glioma", "a trial of ON 01.", "(ON01)", "ON\u201101", "On-01", "on01"):
            self.assertTrue(ev._as_written(a, text), text)
        for text in ("based on 01 January", "On 01 March", "MON-01", "ON-012"):
            self.assertFalse(ev._as_written(a, text), text)
        self.assertTrue(ev._as_written({"alias": "T-VEC", "alias_key": "TVEC"}, "T-Vec was given"))
        self.assertTrue(ev._as_written({"alias": "ADV-tk", "alias_key": "ADVTK"}, "ADV-TK therapy"))
        self.assertTrue(ev._as_written({"alias": "G47\u2206", "alias_key": "G47\u0394"}, "G47\u0394 in glioma"))

    def test_guards_in_matching(self):
        rows = [
            {"axp_id": "AXP1", "alias": "ON-01", "alias_key": "ON01", "alias_type": "preferred", "ambiguous": 0},
            {"axp_id": "AXP2", "alias": "Egypt 101 virus", "alias_key": "EGYPT101VIRUS", "alias_type": "synonym",
             "ambiguous": 1},
        ]
        index = br.AliasIndex(rows)
        self.assertEqual(ev.best_hits(index, [("abstract", "Enrolled based on 01 March data.")]), {})
        self.assertEqual(set(ev.best_hits(index, [("abstract", "Patients got ON-01.")])), {"AXP1"})
        # A thesaurus tag doesn't count for an ambiguous name; the same name in an abstract does.
        self.assertEqual(ev.best_hits(index, [("terms", ["West Nile virus", "Egypt 101 virus"])]), {})
        self.assertEqual(set(ev.best_hits(index, [("abstract", "the Egypt 101 virus strain")])), {"AXP2"})

    def test_400_is_not_retried(self):
        def urlopen(req, timeout=None):
            raise urllib.error.HTTPError(req.full_url, 400, "bad", {}, io.BytesIO(b"nope"))
        with mock.patch.object(ev.urllib.request, "urlopen", urlopen):
            with self.assertRaises(ev.BadRequest):
                ev.http_json(ev.EPMC_API, params={"query": "x"}, sleep=lambda s: None)


class Fetching(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.out = os.path.join(self.dir, "evidence", "evidence.sqlite")
        self.logs = []

    def tearDown(self):
        shutil.rmtree(self.dir)

    def rows(self, sql, path=None):
        con = sqlite3.connect(path or self.out)
        try:
            return con.execute(sql).fetchall()
        finally:
            con.close()

    def run_fetch(self, apis, registry=REPO_REGISTRY):
        return ev.fetch_all(self.out, registry, http=apis, log=self.logs.append)

    def test_papers(self):
        apis = standard_apis()
        self.assertEqual(self.run_fetch(apis), 0)
        hits = {(p, a): (m, f) for p, a, m, f in self.rows("SELECT pmid, axp_id, matched, field FROM paper_hit")}
        self.assertEqual(hits[("1001", PEXA)], ("JX-594", "title"))
        # Only in the abstract; the INN wins over the code (it would be linked automatically).
        self.assertEqual(hits[("1002", PEXA)], ("pexastimogene devacirepvec", "abstract"))
        self.assertEqual(hits[("1003", PEXA)], ("JX-594", "title"))       # markup stripped, "JX 594"
        self.assertNotIn(("1004", PEXA), hits)                           # engine's match, not ours
        self.assertEqual(hits[("1005", PEXA)][1], "abstract")
        # One paper, two programs; found by either program's search.
        self.assertEqual(hits[("2001", TVEC)], ("T-VEC", "title"))
        self.assertEqual(hits[("2001", PEXA)], ("JX-594", "title"))
        papers = {r[0]: r for r in self.rows("SELECT * FROM paper")}
        self.assertEqual(set(papers), {"1001", "1002", "1003", "1005", "2001"})
        self.assertEqual(papers["1001"], ("1001", "Phase II trial of JX-594 in liver cancer", "Lancet Oncol",
                                          2011, "clinical_trial", "10.1/1001", "PMC1001"))
        self.assertEqual(papers["1003"][1], "A JX 594 case")
        self.assertEqual(papers["1003"][4], "case_report")
        self.assertEqual(papers["1005"][4], "review")
        # PubMed by default; the query asks for clinical publication types.
        self.assertFalse([c for c in apis.calls if c[0] == ev.EPMC_API])
        terms = [c[2]["term"] for c in apis.calls if c[0] == ev.ESEARCH_API]
        self.assertTrue(any('"JX-594"[tiab]' in t for t in terms))
        self.assertFalse(any("[pt]" in t for t in terms))                  # every paper type
        # Abstracts are never stored.
        with open(self.out, "rb") as fh:
            blob = fh.read()
        self.assertNotIn(b"We gave", blob)
        self.assertNotIn(b"Patients got", blob)
        self.assertEqual(dict(self.rows("SELECT key, value FROM meta"))["complete"], "1")

    def test_europepmc_source_gives_the_same_papers(self):
        apis = standard_apis()
        self.assertEqual(ev.fetch_all(self.out, REPO_REGISTRY, http=apis, log=self.logs.append,
                                      papers_from="europepmc"), 0)
        epmc_rows = self.rows("SELECT * FROM paper ORDER BY pmid")
        epmc_hits = self.rows("SELECT * FROM paper_hit ORDER BY pmid, axp_id")
        epmc = [c for c in apis.calls if c[0] == ev.EPMC_API]
        self.assertTrue(any(c[1]["cursorMark"] != "*" for c in epmc))     # paged
        self.assertTrue(all(c[1]["resultType"] == "core" and c[1]["format"] == "json" for c in epmc))
        self.assertFalse([c for c in apis.calls if c[0] in (ev.ESEARCH_API, ev.EFETCH_API)])
        self.assertEqual(self.run_fetch(standard_apis()), 0)
        self.assertEqual(self.rows("SELECT * FROM paper ORDER BY pmid"), epmc_rows)
        self.assertEqual(self.rows("SELECT * FROM paper_hit ORDER BY pmid, axp_id"), epmc_hits)

    def test_pubmed_batches_ids(self):
        many = [paper(str(5000 + i), "JX-594 report %d" % i) for i in range(5)]
        apis = FakeAPIs({"JX-594": many})
        recs, total, requests = ev.fetch_pubmed('"JX-594"[tiab]', http=apis, batch=2)
        self.assertEqual((len(recs), total, requests), (5, 5, 4))           # 1 esearch + 3 efetch

    def test_pubmed_splits_a_search_that_is_too_big(self):
        many = [paper(str(6000 + i), "JX-594 report %d" % i) for i in range(5)]
        apis = FakeAPIs({"JX-594": many, "T-VEC": [paper("7001", "T-VEC report")]})
        names = [n for n in ev.load_names(REPO_REGISTRY) if n["alias"] in ("JX-594", "T-VEC")]
        with mock.patch.object(ev, "PUBMED_MAX", 4):
            papers, hits, complete = ev.collect_papers_pubmed(names, http=apis, log=self.logs.append)
        self.assertTrue(any("splitting" in l for l in self.logs))
        self.assertIn("7001", papers)                  # the half without JX-594 is complete
        self.assertFalse(complete)                     # JX-594 alone still has 5 > 4
        self.assertTrue(any("only 4 fetched" in l for l in self.logs))

    def test_clinical_only_option(self):
        apis = standard_apis()
        self.assertEqual(ev.fetch_all(self.out, REPO_REGISTRY, http=apis, log=self.logs.append,
                                      clinical_only=True), 0)
        terms = [c[2]["term"] for c in apis.calls if c[0] == ev.ESEARCH_API]
        self.assertTrue(terms and all('"Case Reports"[pt]' in t for t in terms))

    def test_pubmed_over_the_cap_is_incomplete(self):
        apis = FakeAPIs(standard_apis().papers, standard_apis().projects, pubmed_count=ev.PUBMED_MAX + 1)
        self.assertEqual(self.run_fetch(apis), 3)
        self.assertEqual(dict(self.rows("SELECT key, value FROM meta"))["complete"], "0")

    def test_time_budget_writes_nothing(self):
        self.assertEqual(self.run_fetch(standard_apis()), 0)
        with open(self.out, "rb") as fh:
            before = fh.read()
        apis = standard_apis()
        real = ev.http_json
        # The real request function's budget check, in front of the fake.
        def http(url, **kw):
            if ev._deadline[0] is not None and ev.time.monotonic() > ev._deadline[0]:
                raise ev.FetchError("time budget used up")
            return apis(url, **kw)
        self.assertIs(ev.http_json, real)
        clock = iter(range(0, 10 ** 6, 100))
        with mock.patch.object(ev.time, "monotonic", lambda: next(clock)):
            self.assertEqual(ev.fetch_all(self.out, REPO_REGISTRY, http=http, log=self.logs.append, budget=250), 1)
        with open(self.out, "rb") as fh:
            self.assertEqual(fh.read(), before)
        self.assertIsNone(ev._deadline[0])

    def test_grants(self):
        apis = FakeAPIs(standard_apis().papers, standard_apis().projects)
        self.assertEqual(self.run_fetch(apis), 0)
        self.assertEqual(self.rows("SELECT * FROM grant_award ORDER BY core_project_num"), [
            ("R01CA000001", "Pexa-Vec biology", "Univ B", "DOE, J", 2012, 2014,
             "https://reporter.nih.gov/project-details/13"),
            ("R21CA000002", "Vaccinia platform", "Univ A", "SMITH, JANE", 2020, 2020,
             "https://reporter.nih.gov/project-details/21")])
        hits = self.rows("SELECT core_project_num, axp_id, matched, field FROM grant_hit ORDER BY 1")
        # Title of the latest year says Pexa-Vec: title wins over the abstract's JX-594.
        self.assertEqual(hits, [("R01CA000001", PEXA, "Pexa-Vec", "title"),
                                ("R21CA000002", PEXA, "JX-594", "terms")])
        rep = [c for c in apis.calls if c[0] == ev.REPORTER_API]
        self.assertTrue(all("include_fields" in c[2] for c in rep))

    def test_reporter_paging_and_splitting(self):
        many = [project(100 + i, "R01CA%06d" % i, 2020, "JX-594 study %d" % i) for i in range(7)]
        apis = FakeAPIs({}, {"JX-594": many, "T-VEC": [project(500, "R01CA9", 2021, "T-VEC grant")]})
        with mock.patch.object(ev, "REPORTER_MAX_OFFSET", 4):
            grants, hits, complete = ev.collect_grants(ev.load_names(REPO_REGISTRY), http=apis,
                                                       log=self.logs.append, limit=2)
        # JX-594's batch had more than can be paged, so it was split down to
        # one name, which still can't be paged in full: incomplete, said so.
        self.assertFalse(complete)
        self.assertTrue(any("splitting" in l for l in self.logs))
        self.assertIn("R01CA9", grants)
        self.assertEqual(len([g for g in grants if g.startswith("R01CA0")]), 6)   # offsets 0, 2, 4
        offsets = [c[2]["offset"] for c in apis.calls]
        self.assertIn(4, offsets)

    def test_incomplete_is_written_and_flagged(self):
        many = [project(100 + i, "R01CA%06d" % i, 2020, "JX-594 study %d" % i) for i in range(7)]
        apis = FakeAPIs(standard_apis().papers, {"JX-594": many})
        with mock.patch.object(ev, "REPORTER_MAX_OFFSET", 4), mock.patch.object(ev, "REPORTER_LIMIT", 2):
            self.assertEqual(self.run_fetch(apis), 3)
        self.assertEqual(dict(self.rows("SELECT key, value FROM meta"))["complete"], "0")
        self.assertEqual(ev.status(self.out, log=self.logs.append), 1)

    def test_include_fields_rejected_falls_back(self):
        apis = standard_apis(reject_fields=True)
        self.assertEqual(self.run_fetch(apis), 0)
        self.assertEqual(len(self.rows("SELECT * FROM grant_award")), 2)
        self.assertTrue(any("include_fields was rejected" in l for l in self.logs))

    def test_ambiguous_name_maps_to_both_programs(self):
        reg_dir = os.path.join(self.dir, "registry")
        shutil.copytree(REPO_REGISTRY, reg_dir)
        with open(os.path.join(reg_dir, "aliases.tsv"), "a", encoding="utf-8") as fh:
            for axp in (TVEC, PEXA):
                fh.write("%s\tOncoShared-7\tsynonym\tcurator\t\tCC0-1.0\t\t\t1\taccepted\thttps://x.org\t2026-11-11\n"
                         % axp)
        apis = FakeAPIs({"OncoShared-7": [paper("3001", "OncoShared 7 in melanoma")]},
                        {"OncoShared-7": [project(1, "R01X", 2020, "t", "uses OncoShared-7")]})
        self.assertEqual(self.run_fetch(apis, reg_dir), 0)
        self.assertEqual(self.rows("SELECT pmid, axp_id, matched, field FROM paper_hit ORDER BY axp_id"),
                         [("3001", TVEC, "OncoShared-7", "title"), ("3001", PEXA, "OncoShared-7", "title")])
        self.assertEqual(self.rows("SELECT axp_id, field FROM grant_hit ORDER BY axp_id"),
                         [(TVEC, "abstract"), (PEXA, "abstract")])
        # build_registry turns them into candidates, for both programs.
        reg_db = os.path.join(self.dir, "registry.sqlite")
        br.build(reg_dir, os.path.join(self.dir, "none.sqlite"), reg_db, log=self.logs.append, evidence=self.out)
        self.assertEqual(self.rows("SELECT axp_id, status FROM paper_link WHERE pmid='3001' ORDER BY axp_id", reg_db),
                         [(TVEC, "candidate"), (PEXA, "candidate")])

    def test_contract_tables(self):
        self.assertEqual(self.run_fetch(standard_apis()), 0)
        expected = {
            "meta": [("key", "TEXT", 1), ("value", "TEXT", 0)],
            "paper": [("pmid", "TEXT", 1), ("title", "TEXT", 0), ("journal", "TEXT", 0), ("year", "INTEGER", 0),
                      ("kind", "TEXT", 0), ("doi", "TEXT", 0), ("pmcid", "TEXT", 0)],
            "paper_hit": [("pmid", "TEXT", 1), ("axp_id", "TEXT", 2), ("matched", "TEXT", 0), ("field", "TEXT", 0)],
            "grant_award": [("core_project_num", "TEXT", 1), ("title", "TEXT", 0), ("org", "TEXT", 0),
                            ("pi", "TEXT", 0), ("first_fy", "INTEGER", 0), ("last_fy", "INTEGER", 0),
                            ("url", "TEXT", 0)],
            "grant_hit": [("core_project_num", "TEXT", 1), ("axp_id", "TEXT", 2), ("matched", "TEXT", 0),
                          ("field", "TEXT", 0)],
        }
        tables = {r[0] for r in self.rows("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertEqual(tables, set(expected))
        for t, cols in expected.items():
            self.assertEqual([(c[1], c[2], c[5]) for c in self.rows("PRAGMA table_info(%s)" % t)], cols, t)
        meta = dict(self.rows("SELECT key, value FROM meta"))
        self.assertEqual(set(meta), {"schema_version", "fetched_at", "complete"})
        self.assertEqual(meta["schema_version"], "1")
        self.assertEqual({f for f, in self.rows("SELECT DISTINCT field FROM paper_hit")}, {"title", "abstract"})
        self.assertTrue({f for f, in self.rows("SELECT DISTINCT field FROM grant_hit")} <= {"title", "abstract", "terms"})
        self.assertEqual({k for k, in self.rows("SELECT DISTINCT kind FROM paper")} -
                         {"clinical_trial", "case_report", "clinical_other", "review", "other"}, set())

    def test_failure_keeps_previous_file(self):
        self.assertEqual(self.run_fetch(standard_apis()), 0)
        with open(self.out, "rb") as fh:
            before = fh.read()
        self.assertEqual(self.run_fetch(standard_apis(fail=True)), 1)
        with open(self.out, "rb") as fh:
            self.assertEqual(fh.read(), before)
        self.assertFalse(os.path.exists(self.out + ".tmp"))
        self.assertTrue(any("nothing written" in l for l in self.logs))

    def test_nothing_found_writes_nothing(self):
        self.assertEqual(self.run_fetch(FakeAPIs()), 1)
        self.assertFalse(os.path.exists(self.out))

    def test_write_error_leaves_old_file(self):
        self.assertEqual(self.run_fetch(standard_apis()), 0)
        with open(self.out, "rb") as fh:
            before = fh.read()
        bad = {"x": ("x",)}   # a malformed row: the insert fails part-way
        with self.assertRaises(sqlite3.Error):
            ev.write_db(self.out, bad, {}, {}, {}, True, "2026-11-11T00:00:00+00:00")
        with open(self.out, "rb") as fh:
            self.assertEqual(fh.read(), before)
        self.assertFalse(os.path.exists(self.out + ".tmp"))

    def test_status(self):
        self.assertEqual(ev.status(self.out, log=self.logs.append), 1)          # missing
        self.assertEqual(self.run_fetch(standard_apis()), 0)
        today = dt_today()
        self.assertEqual(ev.status(self.out, today=today, log=self.logs.append), 0)
        later = (ev.dt.date.fromisoformat(today) + ev.dt.timedelta(days=9)).isoformat()
        self.assertEqual(ev.status(self.out, today=later, log=self.logs.append), 1)
        self.assertIn("needs attention", self.logs[-1])

    def test_dry_run_writes_nothing(self):
        apis = standard_apis()
        self.assertEqual(ev.dry_run(REPO_REGISTRY, http=apis, log=self.logs.append), 0)
        self.assertFalse(os.path.exists(self.out))
        self.assertEqual(len([c for c in apis.calls if c[0] == ev.ESEARCH_API]), 1)
        self.assertLessEqual(len([c for c in apis.calls if c[0] == ev.EFETCH_API]), 1)
        self.assertEqual(len([c for c in apis.calls if c[0] == ev.REPORTER_API]), 1)
        self.assertEqual([c for c in apis.calls if c[0] == ev.EPMC_API], [])
        self.assertTrue(any("nothing written" in l for l in self.logs))

    def test_build_registry_consumes_it(self):
        # End to end with the real registry: evidence.py's output feeds build_registry.
        self.assertEqual(self.run_fetch(standard_apis()), 0)
        reg_db = os.path.join(self.dir, "registry.sqlite")
        br.build(REPO_REGISTRY, os.path.join(self.dir, "no-snapshots.sqlite"), reg_db,
                 log=self.logs.append, evidence=self.out)
        links = {(a, p): (m, s) for a, p, m, s in self.rows(
            "SELECT axp_id, pmid, method, status FROM paper_link", reg_db)}
        self.assertEqual(links[(PEXA, "1001")], ("title", "auto"))
        self.assertEqual(links[(PEXA, "1002")], ("abstract", "auto"))     # the INN
        self.assertEqual(links[(PEXA, "1005")], ("abstract", "candidate"))  # a code only in the abstract
        self.assertEqual(links[(TVEC, "2001")], ("title", "auto"))
        self.assertEqual(self.rows("SELECT title, year, kind FROM paper WHERE pmid='2001'", reg_db),
                         [("T-VEC and JX-594 compared", 2020, "clinical_trial")])
        grants = {(a, c): (m, s) for a, c, m, s in self.rows(
            "SELECT axp_id, core_project_num, method, status FROM grant_link", reg_db)}
        self.assertEqual(grants, {(PEXA, "R01CA000001"): ("title", "auto"),
                                  (PEXA, "R21CA000002"): ("terms", "candidate")})
        self.assertEqual(self.rows("SELECT first_fy, last_fy FROM grant_award WHERE core_project_num='R01CA000001'",
                                   reg_db), [(2012, 2014)])


def dt_today():
    return ev.dt.datetime.now(ev.dt.timezone.utc).date().isoformat()


if __name__ == "__main__":
    unittest.main()
