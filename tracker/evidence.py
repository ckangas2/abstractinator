#!/usr/bin/env python3
"""Find the clinical papers and NIH grants that name each registered program.

The registry links a program to its trials by name (build_registry.py); this
does the same for two other kinds of evidence:

  * clinical papers, from PubMed (NCBI E-utilities: esearch, then efetch in
    batches of 200), or from the Europe PMC REST API with --papers-from
    europepmc: MEDLINE records of clinical trials, case reports and other
    clinical studies whose title or abstract contains one of the program's
    names;
  * NIH grants, from the NIH RePORTER API v2: projects whose title, abstract
    or project terms contain one of the program's names.

Names are every active program's preferred name and accepted aliases in
registry/*.tsv, except those whose alias key is shorter than 4 characters (too
likely to match something else). They are searched in batches of quoted
phrases, and every record that comes back is checked here, with the same
word-window matching build_registry.py uses for trial titles: the search
engines' own matching (stemming, synonyms, tokenising) is never trusted. A
record names a program when one of its names' alias keys is among the
record's window keys; where it was found (title, abstract or project terms)
is recorded, with the title winning when it is in both.

This stores search hits, not judgements: build_registry.py decides which hits
count (auto) and which need review (candidate). Ambiguous names are kept, for
every program that holds them. Abstracts are read to find names but never
stored; only titles, identifiers and bibliographic details are (see
tracker/README.md for sources and terms).

Output: data/evidence/evidence.sqlite, tables as in tracker/REGISTRY_DB.md
("evidence.sqlite"). It is rebuilt from scratch on every run under a
temporary name and renamed into place, so readers never see a half-written
file. If any request fails (after retries), nothing is written and the
previous file stays as it was: the run exits 1. If everything was fetched but
a search had more records than the API lets us page through, the file is
written with meta complete=0 and the run exits 3 (and --status reports it).

Standard library only (Python 3.8+), so cron can run it with the system python.

Usage:
    python3 tracker/evidence.py               # fetch everything, write the database
    python3 tracker/evidence.py --dry-run     # first batch of each source; write nothing
    python3 tracker/evidence.py --status      # age and counts; exit 1 if stale or incomplete
Options:
    --out FILE        the database (default: <repo>/data/evidence/evidence.sqlite)
    --registry DIR    registry TSVs (default: <repo>/registry)
"""

import argparse
import unicodedata
import xml.etree.ElementTree as ET
import datetime as dt
import html
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import registry as reg  # noqa: E402
import build_registry as br  # noqa: E402  (window_keys, AliasIndex, evidence_status)

SCHEMA_VERSION = "1"
USER_AGENT = "AbstractinatorEvidence/1 (+https://abstractinator.me)"
DEFAULT_OUT = reg.data_dir("evidence", "evidence.sqlite")
DEFAULT_REGISTRY = os.path.join(REPO, "registry")

EPMC_API = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
ESEARCH_API = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
EFETCH_API = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
PUBMED_MAX = 9999            # esearch returns at most this many ids for one search
EFETCH_BATCH = 200           # records per efetch
REQUEST_DEADLINE = 90        # seconds a single request may take in total (a slow trickle fails)
TIME_BUDGET = 45 * 60        # seconds the whole fetch may take; past it, nothing is written
REPORTER_API = "https://api.reporter.nih.gov/v2/projects/search"

PAUSE_SECONDS = 1.0          # at least this long between any two requests (NIH asks for <= 1/s)
STALE_DAYS = 8               # --status fails when the newest fetch is older
MIN_KEY = 4                  # names with shorter alias keys are not searched

EPMC_PAGE_SIZE = 1000        # Europe PMC's maximum
EPMC_BATCH = 20              # names per Europe PMC query...
EPMC_MAX_QUERY = 3000        # ...and at most this many characters of URL-encoded query
REPORTER_LIMIT = 500         # RePORTER's maximum page size
REPORTER_MAX_OFFSET = 14999  # RePORTER's maximum offset for project search
REPORTER_BATCH = 25          # names per RePORTER search (halved when a search has too many hits)

# Publication types that make a MEDLINE record clinical evidence (PubMed's
# publication-type vocabulary, which Europe PMC searches as PUB_TYPE).
CLINICAL_PUB_TYPES = [
    "Clinical Trial", "Clinical Trial, Phase I", "Clinical Trial, Phase II",
    "Clinical Trial, Phase III", "Clinical Trial, Phase IV", "Controlled Clinical Trial",
    "Randomized Controlled Trial", "Case Reports", "Clinical Study", "Observational Study",
]

# Fields asked of RePORTER. If it ever rejects this list, the run falls back to
# whole records (and says so).
REPORTER_FIELDS = [
    "ApplId", "CoreProjectNum", "FiscalYear", "ProjectTitle", "Organization",
    "ContactPiName", "PrincipalInvestigators", "AbstractText", "Terms", "PrefTerms",
]

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE paper (
  pmid TEXT PRIMARY KEY, title TEXT, journal TEXT, year INTEGER, kind TEXT, doi TEXT, pmcid TEXT
);
CREATE TABLE paper_hit (
  pmid TEXT NOT NULL, axp_id TEXT NOT NULL, matched TEXT NOT NULL, field TEXT NOT NULL,
  PRIMARY KEY (pmid, axp_id)
);
CREATE TABLE grant_award (
  core_project_num TEXT PRIMARY KEY, title TEXT, org TEXT, pi TEXT, first_fy INTEGER, last_fy INTEGER,
  url TEXT
);
CREATE TABLE grant_hit (
  core_project_num TEXT NOT NULL, axp_id TEXT NOT NULL, matched TEXT NOT NULL, field TEXT NOT NULL,
  PRIMARY KEY (core_project_num, axp_id)
);
"""

# Where a name was found, best first.
FIELD_ORDER = {"title": 0, "abstract": 1, "terms": 2}


# --- names ----------------------------------------------------------------------

def load_names(registry_dir=DEFAULT_REGISTRY):
    """Every searchable name: the alias rows build_registry.py makes (each
    active program's preferred name and its accepted aliases), minus names
    whose alias key is shorter than MIN_KEY. A name held by several programs
    (ambiguous) appears once per program."""
    programs, e1 = reg.read_tsv(os.path.join(registry_dir, "programs.tsv"), reg.PROGRAM_COLUMNS)
    aliases, e2 = reg.read_tsv(os.path.join(registry_dir, "aliases.tsv"), reg.ALIAS_COLUMNS)
    if e1 or e2:
        raise SystemExit("registry can't be read: " + "; ".join(e1 + e2))
    active = {p["axp_id"] for p in programs if p["status"] == "active"}
    rows = []
    for p in programs:
        if p["status"] == "active" and p["preferred_name"]:
            rows.append({"axp_id": p["axp_id"], "alias": p["preferred_name"], "alias_type": "preferred",
                         "ambiguous": 0})
    for a in aliases:
        if a["status"] == "accepted" and a["axp_id"] in active:
            rows.append({"axp_id": a["axp_id"], "alias": a["alias"], "alias_type": a["alias_type"],
                         "ambiguous": int(a["ambiguous"] == "1")})
    out = []
    for r in rows:
        r["alias_key"] = reg.alias_key(r["alias"])
        if len(r["alias_key"]) >= MIN_KEY:
            out.append(r)
    return out


def search_terms(names):
    """The distinct spellings to search for (quotes removed, spaces collapsed;
    case doesn't matter to either API), sorted. "JX-594" and "JX594" share a
    key but are both searched, since a search engine may tokenise them apart."""
    seen = {}
    for n in names:
        t = " ".join(n["alias"].replace('"', " ").split())
        if t and t.lower() not in seen:
            seen[t.lower()] = t
    return sorted(seen.values(), key=lambda s: (s.lower(), s))


def _clean(text):
    """Text with markup removed: Europe PMC titles and abstracts carry HTML tags."""
    if not text:
        return ""
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", str(text))).split())


SHORT_KEY = 5     # names with a key this short must be written as themselves (see _as_written)

_JOIN = r"[\-\u2010-\u2015_./]*"      # hyphens and the like: any letter case
_SPACED = r"[\s\-\u2010-\u2015_./]*"  # also spaces: same letter case only


def _as_written(alias, text):
    """Is a short name written in the text as itself? Joined or hyphenated in
    any letter case ("ON-01", "ON01", "T-Vec" for T-VEC), or split by spaces
    in the same case ("ON 01"). Not "on 01 January" or "On 01 March", which
    squash to the same key."""
    def norm(t):
        return unicodedata.normalize("NFKC", t.replace("\u2206", "\u0394"))   # increment sign as Greek delta
    chars = [re.escape(c) for c in norm(alias["alias"]) if c.isalnum()]
    text = norm(text)

    def found(sep, flags):
        return re.search(r"(?<![^\W_])" + sep.join(chars) + r"(?![^\W_])", text, flags) is not None
    return found(_JOIN, re.IGNORECASE) or found(_SPACED, 0)


def best_hits(index, fields):
    """Which programs a record names, and where: {axp_id: (field, alias row)}.

    fields is [(field, text or list of texts)] (a list is matched item by
    item, so project terms don't run into each other). Per program, the best
    evidence wins: title over abstract over terms, then a name that would be
    linked automatically over one left for review, then the longer name.

    Two guards against names that match by accident: a name with a key of
    SHORT_KEY characters or fewer must be written as itself (words like
    "on 01" squash to the key of "ON-01"; see _as_written); and an ambiguous name
    never counts in project terms, which are thesaurus tags with synonyms
    (NIH tags every West Nile virus grant "Egypt 101 virus")."""
    best = {}
    for field, texts in fields:
        if isinstance(texts, str) or texts is None:
            texts = [texts]
        for text in texts:
            text = _clean(text)
            for alias in index.inside(text):
                if field == "terms" and alias["ambiguous"]:
                    continue
                if len(alias["alias_key"]) <= SHORT_KEY and not _as_written(alias, text):
                    continue
                rank = (-FIELD_ORDER[field], br.evidence_status(alias, field) == "auto",
                        not alias["ambiguous"], len(alias["alias_key"]), alias["alias"])
                cur = best.get(alias["axp_id"])
                if cur is None or rank > cur[0]:
                    best[alias["axp_id"]] = (rank, field, alias)
    return {axp: (field, alias) for axp, (_, field, alias) in best.items()}


# --- HTTP -------------------------------------------------------------------------

class BadRequest(Exception):
    pass


class FetchError(Exception):
    pass


_last_request = [0.0]


_deadline = [None]           # monotonic time after which no new request starts (TIME_BUDGET)


def say(msg):
    """Print a progress line now, not when the buffer fills: cron sends it to a log."""
    print(msg, flush=True)


def _read_all(resp, limit):
    """The whole body, failing if it takes longer than `limit` seconds in total.
    (urlopen's timeout only covers silence; a slow trickle could run for hours.)"""
    start, chunks = time.monotonic(), []
    while True:
        chunk = resp.read(65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        if time.monotonic() - start > limit:
            raise TimeoutError("response took longer than %d s" % limit)


def http_json(url, params=None, body=None, retries=4, timeout=60, sleep=time.sleep, form=None, raw=False):
    """GET url?params, or POST body as JSON (or form as form data); the decoded
    JSON reply (the text, if raw).

    Requests are spaced at least PAUSE_SECONDS apart and each must finish
    within REQUEST_DEADLINE seconds. 429 and 5xx replies and network errors
    are retried with backoff (5, 10, 20, 40 s, or the server's Retry-After);
    a 400 raises BadRequest; anything else raises FetchError. Past the run's
    time budget, FetchError."""
    if _deadline[0] is not None and time.monotonic() > _deadline[0]:
        raise FetchError("time budget of %d minutes used up" % (TIME_BUDGET // 60))
    if params:
        url = url + "?" + urllib.parse.urlencode(params)
    headers = {"User-Agent": USER_AGENT, "Accept": "*/*" if raw else "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    host = urllib.parse.urlsplit(url).netloc
    delay = 5.0
    for attempt in range(retries + 1):
        wait = _last_request[0] + PAUSE_SECONDS - time.monotonic()
        if wait > 0:
            sleep(wait)
        _last_request[0] = time.monotonic()
        req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                text = _read_all(resp, REQUEST_DEADLINE).decode("utf-8")
                return text if raw else json.loads(text)
        except urllib.error.HTTPError as e:
            if e.code == 400:
                raise BadRequest("HTTP 400 from %s: %s" % (host, e.read()[:300].decode("utf-8", "replace")))
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                after = e.headers.get("Retry-After") if e.headers else None
                sleep(float(after) if after and after.isdigit() else delay)
                delay *= 2
                continue
            raise FetchError("HTTP %d from %s" % (e.code, host))
        except (urllib.error.URLError, TimeoutError, ConnectionError, ValueError) as e:
            if attempt < retries:
                sleep(delay)
                delay *= 2
                continue
            raise FetchError("network error from %s: %s" % (host, e))


# --- PubMed (NCBI E-utilities) --------------------------------------------------------

def pubmed_query(terms, clinical_only=False):
    """("a"[tiab] OR "b"[tiab] ...), papers of every type; with clinical_only,
    AND ("Clinical Trial"[pt] OR ...), the clinical publication types."""
    names = " OR ".join('"%s"[tiab]' % t for t in terms)
    if not clinical_only:
        return "(%s)" % names
    types = " OR ".join('"%s"[pt]' % t for t in CLINICAL_PUB_TYPES)
    return "(%s) AND (%s)" % (names, types)


def _text(el):
    return " ".join("".join(el.itertext()).split()) if el is not None else ""


def parse_pubmed_xml(text):
    """[{pmid, title, abstract, journal, year, pub_types, doi, pmcid}] from efetch XML."""
    out = []
    root = ET.fromstring(text)
    for art in root.iter("PubmedArticle"):
        cit = art.find("MedlineCitation")
        if cit is None:
            continue
        a = cit.find("Article")
        pmid = _text(cit.find("PMID"))
        if not pmid or a is None:
            continue
        year = _text(a.find("Journal/JournalIssue/PubDate/Year")) or \
            _text(a.find("Journal/JournalIssue/PubDate/MedlineDate"))[:4]
        ids = {i.get("IdType"): _text(i) for i in art.findall("PubmedData/ArticleIdList/ArticleId")}
        out.append({
            "pmid": pmid,
            "title": _text(a.find("ArticleTitle")),
            "abstract": " ".join(_text(x) for x in a.findall("Abstract/AbstractText")),
            "journal": _text(a.find("Journal/Title")) or _text(a.find("Journal/ISOAbbreviation")) or None,
            "year": _int(year),
            "pub_types": [_text(t) for t in a.findall("PublicationTypeList/PublicationType")],
            "doi": ids.get("doi") or None,
            "pmcid": ids.get("pmc") or None,
        })
    return out


def fetch_pubmed(query, http=http_json, max_ids=None, batch=None, max_fetch=None):
    """Records for one search: esearch for the ids (at most PUBMED_MAX), efetch
    them in batches of EFETCH_BATCH. Returns (records, hit_count, requests)."""
    max_ids = max_ids or PUBMED_MAX
    batch = batch or EFETCH_BATCH
    data = http(ESEARCH_API, form={"db": "pubmed", "term": query, "retmode": "json", "retmax": max_ids})
    res = data.get("esearchresult") or {}
    if res.get("ERROR"):
        raise BadRequest("PubMed rejected the query: %s" % res.get("ERROR"))
    ids = res.get("idlist") or []
    total = int(res.get("count") or 0)
    if max_fetch is not None:
        ids = ids[:max_fetch]
    records, requests = [], 1
    for i in range(0, len(ids), batch):
        text = http(EFETCH_API, form={"db": "pubmed", "id": ",".join(ids[i:i + batch]), "retmode": "xml"}, raw=True)
        records.extend(parse_pubmed_xml(text))
        requests += 1
    return records, total, requests


def collect_papers_pubmed(names, http=http_json, log=say, max_batches=None, max_fetch=None,
                          clinical_only=False):
    """As collect_papers, from PubMed. Returns (papers, hits, complete).
    A search with more hits than esearch returns (PUBMED_MAX) is split in
    half until it fits; a single name that still doesn't fit is fetched in
    part and the run marked incomplete."""
    index = br.AliasIndex(names)
    papers, hits, complete = {}, {}, True
    queue = epmc_batches(search_terms(names))[:max_batches]
    i = 0
    while queue:
        terms = queue.pop(0)
        i += 1
        records, total, _ = fetch_pubmed(pubmed_query(terms, clinical_only), http=http, max_fetch=max_fetch)
        if total > PUBMED_MAX and len(terms) > 1:
            half = len(terms) // 2
            queue[:0] = [terms[:half], terms[half:]]
            log("pubmed: %d names give %d papers, more than one search returns; splitting" % (len(terms), total))
            continue
        if total > PUBMED_MAX:
            complete = False
            log("pubmed: %r gives %d papers; only %d fetched" % (terms[0], total, len(records)))
        kept = 0
        for rec in records:
            found = best_hits(index, [("title", rec["title"]), ("abstract", rec["abstract"])])
            if not found:
                continue      # PubMed's match (it expands terms), not ours
            kept += 1
            row = (rec["pmid"], _clean(rec["title"]) or None, rec["journal"], rec["year"],
                   paper_kind(rec["pub_types"]), rec["doi"], rec["pmcid"])
            papers[row[0]] = row
            for axp, (field, alias) in found.items():
                _offer(hits, (row[0], axp), field, alias)
        log("pubmed    %3d (%d to go): %4d names, %5s hits, %5d fetched, %5d name a program"
            % (i, len(queue), len(terms), total, len(records), kept))
    return papers, hits, complete


def trial_cited_pmids(names, snapshots=None, log=say):
    """PMIDs of the results papers (RESULT/DERIVED references) that trials
    linked to a program cite, in the newest snapshot. build_registry links
    these papers to the program straight from the registration; fetching them
    here gives them a title, journal and year even when the paper never names
    the program in its title or abstract. Empty if there are no snapshots."""
    path = snapshots or br.DEFAULT_SNAPSHOTS
    if not os.path.isfile(path):
        return set()
    index = br.AliasIndex(names)
    out = set()
    snap = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        days = [r[0] for r in snap.execute("SELECT snapshot_date FROM snapshot ORDER BY snapshot_date")]
        if not days:
            return set()
        for _nct, (_h, rec_json) in br.records_for(snap, days[-1]).items():
            rec = json.loads(rec_json)
            refs = [r.get("pmid") for r in rec.get("references") or []
                    if (r.get("type") or "") in br.TRIAL_RESULT_REF_TYPES and r.get("pmid")]
            if refs and any(l["status"] == "auto" for l in br.link_trial(rec, index).values()):
                out.update(str(p) for p in refs)
    finally:
        snap.close()
    return out


def fetch_pmids(pmids, http=http_json, batch=None):
    """Paper rows for these PMIDs from PubMed efetch (no search, no hits)."""
    batch = batch or EFETCH_BATCH
    ids, rows = sorted(pmids), {}
    for i in range(0, len(ids), batch):
        text = http(EFETCH_API, form={"db": "pubmed", "id": ",".join(ids[i:i + batch]), "retmode": "xml"}, raw=True)
        for rec in parse_pubmed_xml(text):
            rows[rec["pmid"]] = (rec["pmid"], _clean(rec["title"]) or None, rec["journal"], rec["year"],
                                 paper_kind(rec["pub_types"]), rec["doi"], rec["pmcid"])
    return rows


# --- Europe PMC ---------------------------------------------------------------------

def epmc_query(terms, clinical_only=True):
    """(TITLE:"a" OR ABSTRACT:"a" OR TITLE:"b" ...) AND SRC:MED [AND (PUB_TYPE:"..." OR ...)]"""
    names = " OR ".join('TITLE:"%s" OR ABSTRACT:"%s"' % (t, t) for t in terms)
    if not clinical_only:
        return "(%s) AND SRC:MED" % names
    types = " OR ".join('PUB_TYPE:"%s"' % t for t in CLINICAL_PUB_TYPES)
    return "(%s) AND SRC:MED AND (%s)" % (names, types)


def epmc_batches(terms, batch=EPMC_BATCH, max_chars=EPMC_MAX_QUERY):
    """Terms split into queries of at most `batch` names and `max_chars`
    URL-encoded characters (a single over-long name gets a query of its own)."""
    out, cur = [], []
    for t in terms:
        trial = cur + [t]
        if cur and (len(trial) > batch or len(urllib.parse.quote(epmc_query(trial))) > max_chars):
            out.append(cur)
            trial = [t]
        cur = trial
    if cur:
        out.append(cur)
    return out


def paper_kind(pub_types):
    """clinical_trial, case_report, review, clinical_other or other, from a
    record's publication types (first match wins, in that order)."""
    types = {str(t).strip().lower() for t in pub_types or []}
    if any(t.startswith("clinical trial") and "protocol" not in t and "veterinary" not in t for t in types) or \
            types & {"randomized controlled trial", "controlled clinical trial", "pragmatic clinical trial",
                     "equivalence trial", "adaptive clinical trial"}:
        return "clinical_trial"
    if types & {"case reports", "case report"}:
        return "case_report"
    if types & {"review", "systematic review", "meta-analysis", "scoping review"}:
        return "review"
    # Not "Comparative Study", "Evaluation Study" or "Validation Study": PubMed
    # gives those to lab work as often as to studies in people (an assay
    # validation, a cell-line comparison).
    if types & {"clinical study", "observational study", "clinical trial protocol", "multicenter study"}:
        return "clinical_other"
    return "other"


def _pub_types(rec):
    pt = (rec.get("pubTypeList") or {}).get("pubType")
    if isinstance(pt, str):
        return [pt]
    return pt if isinstance(pt, list) else []


def _int(x):
    try:
        return int(str(x)[:4])
    except (TypeError, ValueError):
        return None


def paper_row(rec):
    """(pmid, title, journal, year, kind, doi, pmcid) of a Europe PMC core record."""
    journal = ((rec.get("journalInfo") or {}).get("journal") or {})
    return (str(rec.get("pmid")), _clean(rec.get("title")) or None,
            journal.get("title") or journal.get("medlineAbbreviation") or None,
            _int(rec.get("pubYear")), paper_kind(_pub_types(rec)),
            rec.get("doi") or None, rec.get("pmcid") or None)


def fetch_epmc(query, http=http_json, page_size=EPMC_PAGE_SIZE, max_pages=None):
    """Every record of one search, by cursorMark. Returns (records, hit_count, pages)."""
    cursor, records, pages, total = "*", [], 0, None
    while True:
        data = http(EPMC_API, params={"query": query, "format": "json", "resultType": "core",
                                      "pageSize": page_size, "cursorMark": cursor})
        pages += 1
        if total is None:
            total = data.get("hitCount")
        page = (data.get("resultList") or {}).get("result") or []
        records.extend(r for r in page if isinstance(r, dict))
        nxt = data.get("nextCursorMark")
        if not page or not nxt or nxt == cursor or (total is not None and len(records) >= total) \
                or (max_pages and pages >= max_pages):
            break
        cursor = nxt
    return records, total, pages


def collect_papers(names, http=http_json, log=say, max_batches=None, page_size=EPMC_PAGE_SIZE, clinical_only=False,
                   max_pages=None):
    """Search every name; returns (papers {pmid: row}, hits {(pmid, axp): (field, alias)}, complete)."""
    index = br.AliasIndex(names)
    papers, hits, complete = {}, {}, True
    batches = epmc_batches(search_terms(names))[:max_batches]
    for i, terms in enumerate(batches, 1):
        records, total, pages = fetch_epmc(epmc_query(terms, clinical_only), http=http, page_size=page_size,
                                           max_pages=max_pages)
        if total is not None and len(records) < total and not max_pages:
            complete = False
        kept = 0
        for rec in records:
            if not rec.get("pmid"):
                continue
            found = best_hits(index, [("title", rec.get("title")), ("abstract", rec.get("abstractText"))])
            if not found:
                continue      # the search engine's match, not ours
            kept += 1
            row = paper_row(rec)
            papers[row[0]] = row
            for axp, (field, alias) in found.items():
                _offer(hits, (row[0], axp), field, alias)
        log("europepmc %3d/%d: %4d names, %5s hits, %5d fetched, %5d name a program"
            % (i, len(batches), len(terms), total, len(records), kept))
    return papers, hits, complete


def _offer(hits, key, field, alias):
    rank = lambda f, a: (-FIELD_ORDER[f], br.evidence_status(a, f) == "auto", not a["ambiguous"],
                         len(a["alias_key"]), a["alias"])
    cur = hits.get(key)
    if cur is None or rank(field, alias) > rank(*cur):
        hits[key] = (field, alias)


# --- NIH RePORTER --------------------------------------------------------------------

def reporter_body(terms, offset=0, limit=REPORTER_LIMIT, fields=True):
    body = {"criteria": {"advanced_text_search": {
                "operator": "or", "search_field": "projecttitle,terms,abstracttext",
                "search_text": " ".join('"%s"' % t for t in terms)}},
            "offset": offset, "limit": limit,
            # A fixed order, so pages don't shift between requests (the sort the
            # app's NIHReporter_extraction.R already uses).
            "sort_field": "project_start_date", "sort_order": "desc"}
    if fields:
        body["include_fields"] = list(REPORTER_FIELDS)
    return body


def fetch_reporter(terms, http=http_json, limit=None, max_pages=None, state=None):
    """Every project record of one search. Returns (records, total, truncated).

    state["fields"] says whether include_fields is still in use: if the API
    rejects it, the search is repeated without (whole records)."""
    state = state if state is not None else {"fields": True}
    limit = limit or REPORTER_LIMIT
    records, offset, total, pages = [], 0, None, 0
    while True:
        try:
            data = http(REPORTER_API, body=reporter_body(terms, offset, limit, state["fields"]))
        except BadRequest:
            if not state["fields"] or pages:
                raise
            state["fields"] = False
            continue
        pages += 1
        if total is None:
            total = (data.get("meta") or {}).get("total")
        page = [r for r in data.get("results") or [] if isinstance(r, dict)]
        records.extend(page)
        offset += len(page)
        if not page or (total is not None and offset >= total) or (max_pages and pages >= max_pages):
            break
        if offset > REPORTER_MAX_OFFSET:
            break
    truncated = total is not None and len(records) < total and not max_pages
    return records, total, truncated


def _terms_list(rec):
    out = []
    for key in ("terms", "pref_terms"):
        v = rec.get(key)
        if isinstance(v, list):
            out.extend(str(x) for x in v)
        elif v:
            out.extend(re.split(r"[<>;]", str(v)))
    return [t for t in (" ".join(x.split()) for x in out) if t]


def _pi(rec):
    if rec.get("contact_pi_name"):
        return " ".join(str(rec["contact_pi_name"]).split())
    pis = [p for p in rec.get("principal_investigators") or [] if isinstance(p, dict)]
    pis.sort(key=lambda p: not p.get("is_contact_pi"))
    return (pis[0].get("full_name") or None) if pis else None


def grant_rows(records):
    """Fiscal-year records grouped by core project: {core: row}, where row is
    (core_project_num, title, org, pi, first_fy, last_fy, url). Title, org,
    PI and URL come from the latest fiscal year."""
    groups = {}
    for r in records:
        core = r.get("core_project_num")
        if core:
            groups.setdefault(core, {})[str(r.get("appl_id"))] = r
    out = {}
    for core, recs in groups.items():
        recs = list(recs.values())
        years = [y for y in (_int(r.get("fiscal_year")) for r in recs) if y]
        latest = max(recs, key=lambda r: (_int(r.get("fiscal_year")) or 0, _int(r.get("appl_id")) or 0))
        appl = latest.get("appl_id")
        out[core] = (core, _clean(latest.get("project_title")) or None,
                     (latest.get("organization") or {}).get("org_name") or None, _pi(latest),
                     min(years) if years else None, max(years) if years else None,
                     "https://reporter.nih.gov/project-details/%s" % (appl or core))
    return out


def collect_grants(names, http=http_json, log=say, max_batches=None, limit=None, max_pages=None):
    """Search every name; returns (grants {core: row}, hits {(core, axp): (field, alias)}, complete)."""
    index = br.AliasIndex(names)
    terms = search_terms(names)
    queue = [terms[i:i + REPORTER_BATCH] for i in range(0, len(terms), REPORTER_BATCH)][:max_batches]
    records, hits, complete, state, n = [], {}, True, {"fields": True}, 0
    while queue:
        batch = queue.pop(0)
        got, total, truncated = fetch_reporter(batch, http=http, limit=limit, max_pages=max_pages, state=state)
        n += 1
        if truncated and len(batch) > 1:
            # More records than the API pages through: search each half instead.
            half = len(batch) // 2
            queue[:0] = [batch[:half], batch[half:]]
            log("reporter: %d names give %s projects, more than can be paged; splitting" % (len(batch), total))
            continue
        if truncated:
            complete = False
            log("reporter: %r gives %s projects; only %d fetched" % (batch[0], total, len(got)))
        kept = 0
        for r in got:
            core = r.get("core_project_num")
            if not core:
                continue
            found = best_hits(index, [("title", r.get("project_title")), ("abstract", r.get("abstract_text")),
                                      ("terms", _terms_list(r))])
            if not found:
                continue
            kept += 1
            records.append(r)
            for axp, (field, alias) in found.items():
                _offer(hits, (core, axp), field, alias)
        log("reporter  %3d: %4d names, %5s hits, %5d fetched, %5d name a program"
            % (n, len(batch), total, len(got), kept))
    if not state["fields"]:
        log("reporter: include_fields was rejected; fetched whole records")
    return grant_rows(records), hits, complete


# --- writing ---------------------------------------------------------------------------

def write_db(out, papers, paper_hits, grants, grant_hits, complete, fetched_at):
    """Write a fresh database under a temporary name and rename it into place."""
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = out + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    try:
        db.executescript(SCHEMA)
        with db:
            db.executemany("INSERT INTO meta VALUES (?, ?)", [
                ("schema_version", SCHEMA_VERSION), ("fetched_at", fetched_at), ("complete", "1" if complete else "0")])
            db.executemany("INSERT INTO paper VALUES (?,?,?,?,?,?,?)", sorted(papers.values()))
            db.executemany("INSERT INTO paper_hit VALUES (?,?,?,?)",
                           sorted((p, axp, a["alias"], f) for (p, axp), (f, a) in paper_hits.items()))
            db.executemany("INSERT INTO grant_award VALUES (?,?,?,?,?,?,?)", sorted(grants.values()))
            db.executemany("INSERT INTO grant_hit VALUES (?,?,?,?)",
                           sorted((c, axp, a["alias"], f) for (c, axp), (f, a) in grant_hits.items()))
    except BaseException:
        db.close()
        os.remove(tmp)
        raise
    db.close()
    os.replace(tmp, out)


def fetch_all(out, registry_dir=DEFAULT_REGISTRY, http=http_json, log=say, now=None, papers_from="pubmed",
              clinical_only=False, snapshots=None,
              budget=TIME_BUDGET):
    """Fetch both sources and write the database. Returns the exit code:
    0 written and complete, 3 written but incomplete, 1 nothing written.
    papers_from: "pubmed" (default) or "europepmc". Past `budget` seconds,
    nothing is written and the previous file stays."""
    now = now or dt.datetime.now(dt.timezone.utc)
    _deadline[0] = time.monotonic() + budget if budget else None
    names = load_names(registry_dir)
    log("%d names (%d searched spellings) for %d programs"
        % (len(names), len(search_terms(names)), len({n["axp_id"] for n in names})))
    try:
        if papers_from == "europepmc":
            papers, phits, p_ok = collect_papers(names, http=http, log=log, clinical_only=clinical_only)
        else:
            papers, phits, p_ok = collect_papers_pubmed(names, http=http, log=log, clinical_only=clinical_only)
        if papers_from != "europepmc":
            cited = trial_cited_pmids(names, snapshots, log=log) - set(papers)
            if cited:
                try:
                    found = fetch_pmids(cited, http=http)
                    papers.update(found)
                    log("pubmed    trial-cited papers: %d not found by name, %d fetched" % (len(cited), len(found)))
                except FetchError as e:     # a supplement: the build still links them, just without details
                    log("pubmed    trial-cited papers: %d not fetched (%s)" % (len(cited), e))
        grants, ghits, g_ok = collect_grants(names, http=http, log=log)
    except (FetchError, BadRequest) as e:
        log("ERROR %s; nothing written, %s left as it was" % (e, out))
        return 1
    finally:
        _deadline[0] = None
    if not papers and not grants:
        log("ERROR no papers and no grants found (an API change?); nothing written, %s left as it was" % out)
        return 1
    write_db(out, papers, phits, grants, ghits, p_ok and g_ok, now.isoformat(timespec="seconds"))
    log("wrote %s: %d papers (%d program hits), %d grants (%d program hits), complete=%s"
        % (out, len(papers), len(phits), len(grants), len(ghits), p_ok and g_ok))
    return 0 if p_ok and g_ok else 3


def status(path, today=None, log=say):
    if not os.path.isfile(path):
        log("no evidence database at %s" % path)
        return 1
    con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        meta = dict(con.execute("SELECT key, value FROM meta"))
        counts = con.execute("SELECT (SELECT count(*) FROM paper), (SELECT count(*) FROM paper_hit), "
                             "(SELECT count(*) FROM grant_award), (SELECT count(*) FROM grant_hit)").fetchone()
    finally:
        con.close()
    try:
        fetched = dt.date.fromisoformat(meta.get("fetched_at", "")[:10])
    except ValueError:
        log("%s has no valid fetched_at" % path)
        return 1
    today = dt.date.fromisoformat(today) if today else dt.datetime.now(dt.timezone.utc).date()
    age = (today - fetched).days
    complete = meta.get("complete") == "1"
    ok = age <= STALE_DAYS and complete
    log("evidence fetched %s (%d days old): %d papers (%d program hits), %d grants (%d program hits), "
        "complete=%s%s" % (fetched, age, counts[0], counts[1], counts[2], counts[3], complete,
                           "" if ok else "  <- needs attention"))
    return 0 if ok else 1


def dry_run(registry_dir=DEFAULT_REGISTRY, http=http_json, log=say, papers_from="pubmed", clinical_only=False):
    """The first batch of each source, one small page; prints counts and samples, writes nothing."""
    names = load_names(registry_dir)
    log("%d names (%d searched spellings)" % (len(names), len(search_terms(names))))
    first = epmc_batches(search_terms(names))[0]
    try:
        if papers_from == "europepmc":
            log("europepmc query: %s" % epmc_query(first, clinical_only)[:400])
            papers, phits, _ = collect_papers(names, http=http, log=log, max_batches=1, page_size=25, max_pages=1,
                                              clinical_only=clinical_only)
        else:
            log("pubmed query: %s" % pubmed_query(first, clinical_only)[:400])
            papers, phits, _ = collect_papers_pubmed(names, http=http, log=log, max_batches=1, max_fetch=25,
                                                     clinical_only=clinical_only)
        for (pmid, axp), (field, alias) in sorted(phits.items())[:3]:
            log("  PMID %s -> %s by %r in %s: %s" % (pmid, axp, alias["alias"], field, papers[pmid][1]))
        grants, ghits, _ = collect_grants(names, http=http, log=log, max_batches=1, limit=25, max_pages=1)
        for (core, axp), (field, alias) in sorted(ghits.items())[:3]:
            log("  %s -> %s by %r in %s: %s" % (core, axp, alias["alias"], field, grants[core][1]))
    except (FetchError, BadRequest) as e:
        log("ERROR %s" % e)
        return 1
    log("dry run: nothing written")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--registry", default=DEFAULT_REGISTRY)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--papers-from", choices=["pubmed", "europepmc"], default="pubmed",
                    help="where clinical papers are searched (default pubmed)")
    ap.add_argument("--budget-minutes", type=int, default=TIME_BUDGET // 60,
                    help="stop (writing nothing) after this long")
    ap.add_argument("--clinical-only", action="store_true",
                    help="only clinical publication types (default: every type, labelled by kind)")
    args = ap.parse_args(argv)
    if args.status:
        return status(args.out, log=say)
    if args.dry_run:
        return dry_run(args.registry, papers_from=args.papers_from, clinical_only=args.clinical_only)
    return fetch_all(args.out, args.registry, papers_from=args.papers_from, budget=args.budget_minutes * 60,
                     clinical_only=args.clinical_only)


if __name__ == "__main__":
    sys.exit(main())
