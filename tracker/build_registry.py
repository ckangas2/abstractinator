#!/usr/bin/env python3
"""Build data/registry/registry.sqlite: programs, names, trial links and changes.

Reads the curated registry (registry/*.tsv) and the weekly trial snapshots
(data/trial_snapshots/trials.sqlite), and writes a fresh database that the API
serves read-only. The layout is documented in tracker/REGISTRY_DB.md.

What it works out:
  * which trials are about which programs (trial_link), by matching the
    registry's names against each trial's interventions and title;
  * what changed between consecutive snapshots (change_event): new trials,
    status and phase changes, results posted, enrolment and timeline changes;
  * a weekly digest page (www/changes.html), and the registry's web pages
    (www/registry/, by site_pages.py).

Uncertain ("candidate") trial links are exported on demand, by whoever wants
to review them, into their own reports folder (--export-review), rather than
written next to the database.

Everything is recomputed from its sources on each run; nothing in the output
is edited by hand. The new database is built under a temporary name and
renamed into place, so the API never reads a half-built file.

Standard library only (Python 3.8+).

Usage:
    python3 tracker/build_registry.py
Options:
    --registry DIR    registry TSVs (default: <repo>/registry)
    --snapshots FILE  snapshot database (default: <repo>/data/trial_snapshots/trials.sqlite)
    --out FILE        output database (default: <repo>/data/registry/registry.sqlite)
    --page FILE       digest page (default: <repo>/www/changes.html; "" to skip)
    --site DIR        registry web pages (default: <repo>/www/registry; "" to skip),
                      written by tracker/site_pages.py
    --export-review FILE
                      don't build: write the existing database's candidate
                      links to FILE for review, e.g.
                      ~/abstractinator-reports/link_review-$(date +%F).tsv
"""

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import sqlite3
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import registry as reg  # noqa: E402

DEFAULT_REGISTRY = os.path.join(REPO, "registry")
DEFAULT_SNAPSHOTS = reg.data_dir("trial_snapshots", "trials.sqlite")
DEFAULT_OUT = reg.data_dir("registry", "registry.sqlite")
DEFAULT_PAGE = os.path.join(REPO, "www", "changes.html")
DEFAULT_SITE = os.path.join(REPO, "www", "registry")
DEFAULT_EVIDENCE = reg.data_dir("evidence", "evidence.sqlite")

SCHEMA_VERSION = "3"   # 2: virus and approval tables; 3: trial conditions, papers and grants

CONFIDENCE = {"intervention_name": 0.95, "intervention_text": 0.8, "title": 0.6}
MIN_AUTO_TEXT_KEY = 5        # shorter names found inside text are only candidates
MIN_AUTO_CODE_KEY = 6        # a code this long in an abstract counts on its own
# Found inside a longer intervention name, a development code is only a
# candidate: "AUTO1/22" contains AUTO1 but is a different product. Names
# (INNs, brands) inside text are safe enough to link automatically.
AUTO_TEXT_TYPES = {"preferred", "inn", "usan", "brand"}
MIN_TEXT_KEY = 4             # shorter names are never searched for inside text
MAX_WINDOW = 8               # a name may span up to this many words

MAJOR_STATUSES = {"TERMINATED", "WITHDRAWN", "SUSPENDED", "COMPLETED", "ACTIVE_NOT_RECRUITING"}
SLIP_DAYS = 90
# A trial seen for the first time is "new" only if it was registered recently;
# an older trial that just came into scope (a name was added to the registry)
# isn't news.
NEW_TRIAL_DAYS = 30
ENROLLMENT_CHANGE = 0.20

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE program (
  axp_id TEXT PRIMARY KEY, status TEXT, replaced_by TEXT, preferred_name TEXT, modality TEXT,
  platform TEXT, targets TEXT, originator TEXT, sponsor TEXT, ncit TEXT, wikidata TEXT, unii TEXT,
  entry_version INTEGER, created TEXT, updated TEXT, notes TEXT
);
CREATE TABLE alias (
  axp_id TEXT NOT NULL, alias TEXT NOT NULL, alias_key TEXT NOT NULL, alias_type TEXT,
  source TEXT, source_record TEXT, licence TEXT, evidence_url TEXT, ambiguous INTEGER NOT NULL
);
CREATE INDEX alias_by_key ON alias(alias_key);
CREATE TABLE virus (
  axp_id TEXT PRIMARY KEY, role TEXT, virus_family TEXT, virus TEXT, ncbi_taxon TEXT, strain TEXT,
  replication TEXT, modifications TEXT, transgenes TEXT, route TEXT, carrier TEXT, evidence_url TEXT
);
CREATE TABLE approval (
  axp_id TEXT NOT NULL, agency TEXT, region TEXT, date TEXT, status TEXT, brand TEXT,
  indication TEXT, evidence_url TEXT
);
CREATE INDEX approval_by_program ON approval(axp_id);
CREATE TABLE trial (
  nct_id TEXT PRIMARY KEY, snapshot_date TEXT, brief_title TEXT, overall_status TEXT,
  why_stopped TEXT, study_type TEXT, lead_sponsor TEXT, phases TEXT, start_date TEXT,
  primary_completion_date TEXT, completion_date TEXT, enrollment_count INTEGER,
  has_results INTEGER, last_update_post_date TEXT, first_seen TEXT,
  conditions TEXT          -- JSON list
);
CREATE TABLE paper (
  pmid TEXT PRIMARY KEY, title TEXT, journal TEXT, year INTEGER, kind TEXT, doi TEXT, pmcid TEXT
);
CREATE TABLE paper_link (
  axp_id TEXT NOT NULL, pmid TEXT NOT NULL, method TEXT NOT NULL, matched TEXT, nct_id TEXT,
  confidence REAL NOT NULL, status TEXT NOT NULL, PRIMARY KEY (axp_id, pmid)
);
CREATE INDEX paper_link_by_pmid ON paper_link(pmid);
CREATE TABLE grant_award (
  core_project_num TEXT PRIMARY KEY, title TEXT, org TEXT, pi TEXT, first_fy INTEGER, last_fy INTEGER,
  url TEXT
);
CREATE TABLE grant_link (
  axp_id TEXT NOT NULL, core_project_num TEXT NOT NULL, method TEXT NOT NULL, matched TEXT,
  confidence REAL NOT NULL, status TEXT NOT NULL, PRIMARY KEY (axp_id, core_project_num)
);
CREATE TABLE trial_link (
  nct_id TEXT NOT NULL, axp_id TEXT NOT NULL, method TEXT NOT NULL, matched TEXT NOT NULL,
  confidence REAL NOT NULL, status TEXT NOT NULL, PRIMARY KEY (nct_id, axp_id)
);
CREATE INDEX trial_link_by_program ON trial_link(axp_id);
CREATE TABLE change_event (
  event_id TEXT PRIMARY KEY, snapshot_date TEXT NOT NULL, previous_date TEXT NOT NULL,
  nct_id TEXT NOT NULL, type TEXT NOT NULL, significance TEXT NOT NULL,
  field TEXT, before TEXT, after TEXT, axp_ids TEXT NOT NULL
);
CREATE INDEX change_by_date ON change_event(snapshot_date);
CREATE INDEX change_by_trial ON change_event(nct_id);
"""


# --- matching names in text ---------------------------------------------------

def text_tokens(text):
    """Words of a text, normalised the same way as alias_key (so windows of
    consecutive words can be compared with alias keys)."""
    if not text:
        return []
    s = str(text)
    for mark, repl in reg._MARKS.items():
        s = s.replace(mark, repl)
    s = unicodedata.normalize("NFKC", s).upper()
    return re.findall(r"[^\W_]+", s)


def window_keys(text):
    """Every run of 1..MAX_WINDOW consecutive words, joined: the keys a name
    written in this text could have ("MRTX 1133" gives MRTX, 1133, MRTX1133)."""
    toks = text_tokens(text)
    out = set()
    for i in range(len(toks)):
        key = ""
        for j in range(i, min(i + MAX_WINDOW, len(toks))):
            key += toks[j]
            out.add(key)
    return out


# Words that say what kind of organisation it is, not which one.
ORG_SUFFIXES = {"INC", "INCORPORATED", "LTD", "LIMITED", "LLC", "LLP", "CO", "CORP", "CORPORATION", "COMPANY",
                "GMBH", "AG", "SA", "SAS", "SPA", "BV", "NV", "PLC", "AB", "AS", "KK", "PTY", "THE"}
MIN_ORG_KEY = 5


def org_keys(text):
    """Comparable keys for the organisations named in a sponsor field:
    "Spark Therapeutics (Roche)" -> {"SPARKTHERAPEUTICS", "ROCHE"}."""
    out = set()
    for part in re.split(r"[;/(),]|\band\b|&", text or "", flags=re.I):
        toks = [t for t in re.findall(r"[A-Za-z0-9]+", part.upper()) if t not in ORG_SUFFIXES]
        key = "".join(toks)
        if len(key) >= MIN_ORG_KEY:
            out.add(key)
    return out


class AliasIndex:
    def __init__(self, alias_rows, programs=()):
        self.by_key = {}
        for a in alias_rows:
            self.by_key.setdefault(a["alias_key"], []).append(a)
        # Each program's sponsor and originator, the second signal that lets an
        # ambiguous name count (registry plan: "needs a second signal (sponsor
        # or target) before any auto-link").
        self.orgs = {p["axp_id"]: org_keys(p.get("sponsor")) | org_keys(p.get("originator")) for p in programs}

    def sponsor_agrees(self, axp_id, rec):
        """Does the trial's lead sponsor or a collaborator name the program's sponsor or originator?"""
        mine = self.orgs.get(axp_id)
        if not mine:
            return False
        theirs = set()
        for o in [rec.get("lead_sponsor")] + list(rec.get("collaborators") or []):
            theirs |= org_keys(o)
        return any(m == t or (m in t) or (t in m and len(t) >= MIN_ORG_KEY + 3) for m in mine for t in theirs)

    def exact(self, name):
        return self.by_key.get(reg.alias_key(name), [])

    def inside(self, text):
        hits = []
        for k in window_keys(text):
            if len(k) >= MIN_TEXT_KEY and k in self.by_key:
                hits.extend(self.by_key[k])
        return hits


def link_trial(rec, index):
    """Links for one trial (a canonical snapshot record): {axp_id: link dict}.

    auto (counted) when:
      - an intervention's name or other name is one of the program's names;
      - an INN or brand name appears inside an intervention name;
      - a code appears inside an intervention name AND the title names it too,
        or the trial's sponsor is the program's (two separate signals agree;
        "AUTO1/22" alone doesn't make AUTO1);
      - an INN or brand name appears in the title (confidence 0.6).
    Short names and codes seen only in a title stay candidates for review.
    An ambiguous name (one another product also uses) stays a candidate unless
    the trial is sponsored by the program's own sponsor or originator, and is
    named among the interventions: "AdV-tk" from Candel counts for
    aglatimagene besadenovec, "ADV-TK" from a hospital in Wuhan does not.
    """
    best = {}
    title_keys = window_keys(rec.get("brief_title") or "")

    def offer(alias, method):
        key = alias["alias_key"]
        named = alias.get("alias_type") in AUTO_TEXT_TYPES and len(key) >= MIN_AUTO_TEXT_KEY
        if method == "intervention_name":
            status = "auto"
        elif method == "intervention_text":
            status = "auto" if named or key in title_keys or index.sponsor_agrees(alias["axp_id"], rec) \
                else "candidate"
        else:
            status = "auto" if named else "candidate"
        matched = alias["alias"]
        if alias["ambiguous"]:
            if method != "title" and index.sponsor_agrees(alias["axp_id"], rec):
                matched += " (ambiguous name; trial sponsor is the program's)"
            else:
                status = "candidate"
        cand = {"axp_id": alias["axp_id"], "method": method, "matched": matched,
                "confidence": CONFIDENCE[method], "status": status}
        cur = best.get(alias["axp_id"])
        rank = lambda l: (l["status"] == "auto", l["confidence"])
        if cur is None or rank(cand) > rank(cur):
            best[alias["axp_id"]] = cand

    names = []
    for iv in rec.get("interventions") or []:
        names.append(iv.get("name") or "")
        names.extend(iv.get("other_names") or [])
    for n in names:
        for a in index.exact(n):
            offer(a, "intervention_name")
    for n in names:
        for a in index.inside(n):
            offer(a, "intervention_text")
    for a in index.inside(rec.get("brief_title") or ""):
        offer(a, "title")
    return best


# --- changes between snapshots -----------------------------------------------

def _month_or_day(d):
    """'2026-05' or '2026-05-14' -> date (a bare month counts as its 15th)."""
    if not d:
        return None
    try:
        if len(d) == 7:
            return dt.date(int(d[:4]), int(d[5:7]), 15)
        return dt.date.fromisoformat(d[:10])
    except ValueError:
        return None


def _j(v):
    return v if isinstance(v, str) or v is None else json.dumps(v, ensure_ascii=False)


def diff_records(a, b):
    """Events (type, significance, field, before, after) between two versions of a trial."""
    ev = []
    if a.get("overall_status") != b.get("overall_status"):
        sig = "major" if b.get("overall_status") in MAJOR_STATUSES else "minor"
        after = b.get("overall_status")
        if b.get("why_stopped") and after in ("TERMINATED", "WITHDRAWN", "SUSPENDED"):
            after = "%s (%s)" % (after, b["why_stopped"])
        ev.append(("trial.status_changed", sig, "overall_status", a.get("overall_status"), after))
    if (a.get("phases") or []) != (b.get("phases") or []):
        ev.append(("trial.phase_changed", "major", "phases", _j(a.get("phases") or []), _j(b.get("phases") or [])))
    if not a.get("has_results") and b.get("has_results"):
        ev.append(("trial.results_posted", "major", "has_results", "false", "true"))
    ca, cb = a.get("enrollment_count"), b.get("enrollment_count")
    type_turned_actual = a.get("enrollment_type") == "ESTIMATED" and b.get("enrollment_type") == "ACTUAL"
    big = ca and cb is not None and abs(cb - ca) / float(ca) >= ENROLLMENT_CHANGE
    if big or (type_turned_actual and ca != cb):
        ev.append(("trial.enrollment_changed", "minor", "enrollment",
                   "%s (%s)" % (ca, a.get("enrollment_type")), "%s (%s)" % (cb, b.get("enrollment_type"))))
    pa, pb = _month_or_day(a.get("primary_completion_date")), _month_or_day(b.get("primary_completion_date"))
    if pa and pb and (pb - pa).days > SLIP_DAYS:
        ev.append(("trial.completion_slipped", "minor", "primary_completion_date",
                   a.get("primary_completion_date"), b.get("primary_completion_date")))
    if a.get("lead_sponsor") and b.get("lead_sponsor") and a["lead_sponsor"] != b["lead_sponsor"]:
        ev.append(("trial.sponsor_changed", "minor", "lead_sponsor", a["lead_sponsor"], b["lead_sponsor"]))
    names_a = {i.get("name") for i in a.get("interventions") or []}
    added = sorted(n for n in {i.get("name") for i in b.get("interventions") or []} - names_a if n)
    if added:
        ev.append(("trial.intervention_added", "minor", "interventions", None, _j(added)))
    return ev


def snapshot_pairs(snap):
    days = [r[0] for r in snap.execute("SELECT snapshot_date FROM snapshot ORDER BY snapshot_date")]
    return list(zip(days, days[1:]))


def records_for(snap, day):
    rows = snap.execute(
        "SELECT o.nct_id, o.content_hash, v.record FROM observation o JOIN trial_version v "
        "ON v.nct_id = o.nct_id AND v.content_hash = o.content_hash WHERE o.snapshot_date = ?", (day,))
    return {n: (h, rec) for n, h, rec in rows}


def changes_between(snap, a_day, b_day):
    complete = dict(snap.execute("SELECT snapshot_date, complete FROM snapshot"))
    a, b = records_for(snap, a_day), records_for(snap, b_day)
    out = []
    for nct, (hb, rb) in b.items():
        if nct not in a:
            posted = _month_or_day(json.loads(rb).get("first_post_date"))
            since = dt.date.fromisoformat(a_day) - dt.timedelta(days=NEW_TRIAL_DAYS)
            if complete.get(a_day) and posted and posted >= since:
                out.append((nct, "trial.new", "minor", None, None, None))
            continue
        ha, ra = a[nct]
        if ha != hb:
            for e in diff_records(json.loads(ra), json.loads(rb)):
                out.append((nct,) + e)
    if complete.get(a_day) and complete.get(b_day):
        for nct in a:
            if nct not in b:
                out.append((nct, "trial.dropped", "info", None, None, None))
    return out


# --- build ---------------------------------------------------------------------

# --- papers and grants ------------------------------------------------------------

# ClinicalTrials.gov reference types that report the trial itself.
TRIAL_RESULT_REF_TYPES = ("RESULT", "DERIVED")
EVIDENCE_CONFIDENCE = {"trial_reference": 0.9, "title": 0.85, "abstract": 0.6, "terms": 0.6}


def evidence_status(alias, field):
    """auto, candidate or None (don't record the link at all), by where the
    name was found.

    In the title, a name counts unless it is ambiguous or very short. In an
    abstract or project terms it counts if it is an INN or brand, or a
    development code long enough to be distinctive on its own
    (MIN_AUTO_CODE_KEY); such codes are matched as written, so "ON-01" does
    not match "on 01 January". An ambiguous name outside a title is dropped:
    it is noise, not evidence ("TK cells" matches every paper about
    thymidine-kinase-transduced cells, whichever product they used)."""
    if alias is None:
        return "candidate"
    key = alias["alias_key"]
    if alias["ambiguous"]:
        return "candidate" if field == "title" else None
    named = alias.get("alias_type") in AUTO_TEXT_TYPES and len(key) >= MIN_AUTO_TEXT_KEY
    if field == "title":
        return "auto" if named or len(key) >= MIN_TEXT_KEY else "candidate"
    return "auto" if named or len(key) >= MIN_AUTO_CODE_KEY else "candidate"


def add_evidence(db, evidence_path, alias_rows, links_by_trial, nct_refs):
    """Fill paper, paper_link, grant_award and grant_link. Returns (papers, grants) links.

    Papers come from two places: results papers that a linked trial's
    registration cites (no fetching needed), and the hits that
    tracker/evidence.py found by searching each program's names
    (data/evidence/evidence.sqlite, optional). Grants come from the latter."""
    by_alias = {}
    for a in alias_rows:
        by_alias.setdefault((a["axp_id"], a["alias_key"]), a)
    best = {}

    def offer(table, axp, ident, method, matched, status, conf, nct=None):
        if status is None:
            return                  # evidence_status says this hit is noise
        k = (table, axp, ident)
        cand = (status == "auto", conf, method, matched, nct, status)
        if k not in best or cand[:2] > best[k][:2]:
            best[k] = cand

    for nct, axps in links_by_trial.items():
        for ref in nct_refs.get(nct, []):
            if ref.get("pmid"):
                for axp in axps:
                    offer("paper", axp, ref["pmid"], "trial_reference", nct, "auto",
                          EVIDENCE_CONFIDENCE["trial_reference"], nct)

    have_evidence = bool(evidence_path) and os.path.isfile(evidence_path)
    with db:
        if have_evidence:
            ev = sqlite3.connect("file:%s?mode=ro" % evidence_path, uri=True)
            try:
                for pmid, title, journal, year, kind, doi, pmcid in ev.execute(
                        "SELECT pmid, title, journal, year, kind, doi, pmcid FROM paper"):
                    db.execute("INSERT OR REPLACE INTO paper VALUES (?,?,?,?,?,?,?)",
                               (pmid, title, journal, year, kind, doi, pmcid))
                for row in ev.execute("SELECT core_project_num, title, org, pi, first_fy, last_fy, url FROM grant_award"):
                    db.execute("INSERT OR REPLACE INTO grant_award VALUES (?,?,?,?,?,?,?)", row)
                for pmid, axp, matched, field in ev.execute("SELECT pmid, axp_id, matched, field FROM paper_hit"):
                    alias = by_alias.get((axp, reg.alias_key(matched)))
                    offer("paper", axp, pmid, field, matched, evidence_status(alias, field),
                          EVIDENCE_CONFIDENCE.get(field, 0.6))
                for core, axp, matched, field in ev.execute(
                        "SELECT core_project_num, axp_id, matched, field FROM grant_hit"):
                    alias = by_alias.get((axp, reg.alias_key(matched)))
                    offer("grant", axp, core, field, matched, evidence_status(alias, field),
                          EVIDENCE_CONFIDENCE.get(field, 0.6))
            finally:
                ev.close()
        n_p = n_g = 0
        for (table, axp, ident), (_, conf, method, matched, nct, status) in sorted(best.items()):
            if table == "paper":
                db.execute("INSERT INTO paper_link VALUES (?,?,?,?,?,?,?)",
                           (axp, ident, method, matched, nct, conf, status))
                n_p += 1
            else:
                db.execute("INSERT INTO grant_link VALUES (?,?,?,?,?,?)",
                           (axp, ident, method, matched, conf, status))
                n_g += 1
    return n_p, n_g


def registry_release(registry_dir, today):
    h = hashlib.sha256()
    for name in ("programs.tsv", "aliases.tsv"):
        with open(os.path.join(registry_dir, name), "rb") as fh:
            h.update(fh.read())
    return "%s+%s" % (today, h.hexdigest()[:12])


def build(registry_dir, snapshots, out, today=None, log=print, evidence=None):
    today = today or dt.date.today().isoformat()
    problems = reg.validate(registry_dir)
    if problems:
        for p in problems:
            log("ERROR " + p)
        raise SystemExit("registry has problems; nothing built")
    programs, _ = reg.read_tsv(os.path.join(registry_dir, "programs.tsv"), reg.PROGRAM_COLUMNS)
    aliases, _ = reg.read_tsv(os.path.join(registry_dir, "aliases.tsv"), reg.ALIAS_COLUMNS)

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = out + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.executescript(SCHEMA)

    with db:
        for p in programs:
            db.execute("INSERT INTO program VALUES (%s)" % ",".join("?" * len(reg.PROGRAM_COLUMNS)),
                       [int(p[c]) if c == "entry_version" else p[c] for c in reg.PROGRAM_COLUMNS])
        alias_rows = []
        for p in programs:
            if p["status"] == "active":
                alias_rows.append({"axp_id": p["axp_id"], "alias": p["preferred_name"],
                                   "alias_key": reg.alias_key(p["preferred_name"]), "alias_type": "preferred",
                                   "source": "curator", "source_record": "", "licence": "CC-BY-4.0",
                                   "evidence_url": "", "ambiguous": 0})
        for a in aliases:
            if a["status"] == "accepted":
                alias_rows.append({"axp_id": a["axp_id"], "alias": a["alias"], "alias_key": reg.alias_key(a["alias"]),
                                   "alias_type": a["alias_type"], "source": a["source"],
                                   "source_record": a["source_record"], "licence": a["licence"],
                                   "evidence_url": a["evidence_url"], "ambiguous": int(a["ambiguous"])})
        db.executemany("INSERT INTO alias VALUES (:axp_id, :alias, :alias_key, :alias_type, :source, "
                       ":source_record, :licence, :evidence_url, :ambiguous)", alias_rows)
        (viruses, _), (approvals, _) = reg.read_optional(registry_dir)
        db.executemany("INSERT INTO virus VALUES (%s)" % ",".join("?" * len(reg.VIRUS_COLUMNS)),
                       [[v[c] for c in reg.VIRUS_COLUMNS] for v in viruses])
        db.executemany("INSERT INTO approval VALUES (%s)" % ",".join("?" * len(reg.APPROVAL_COLUMNS)),
                       [[a[c] for c in reg.APPROVAL_COLUMNS] for a in approvals])

    latest = previous = ""
    n_links = n_events = 0
    links_by_trial, nct_refs = {}, {}
    review = []
    if os.path.isfile(snapshots):
        snap = sqlite3.connect("file:%s?mode=ro" % snapshots, uri=True)
        try:
            days = [r[0] for r in snap.execute("SELECT snapshot_date FROM snapshot ORDER BY snapshot_date")]
            if days:
                latest = days[-1]
                previous = days[-2] if len(days) > 1 else ""
                first_seen = dict(snap.execute("SELECT nct_id, min(snapshot_date) FROM observation GROUP BY nct_id"))
                index = AliasIndex(alias_rows, programs)
                names = {p["axp_id"]: p["preferred_name"] for p in programs}
                links_by_trial = {}
                nct_refs = {}
                with db:
                    for nct, (h, rec_json) in sorted(records_for(snap, latest).items()):
                        rec = json.loads(rec_json)
                        obs = snap.execute("SELECT last_update_post_date FROM observation "
                                           "WHERE snapshot_date = ? AND nct_id = ?", (latest, nct)).fetchone()
                        db.execute("INSERT INTO trial VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                            nct, latest, rec.get("brief_title"), rec.get("overall_status"), rec.get("why_stopped"),
                            rec.get("study_type"), rec.get("lead_sponsor"), "/".join(rec.get("phases") or []),
                            rec.get("start_date"), rec.get("primary_completion_date"), rec.get("completion_date"),
                            rec.get("enrollment_count"), int(bool(rec.get("has_results"))),
                            obs[0] if obs else None, first_seen.get(nct),
                            json.dumps(rec.get("conditions") or [], ensure_ascii=False)))
                        if nct_refs is not None:
                            nct_refs[nct] = [r for r in rec.get("references") or []
                                             if (r.get("type") or "") in TRIAL_RESULT_REF_TYPES]
                        for axp, l in sorted(link_trial(rec, index).items()):
                            db.execute("INSERT INTO trial_link VALUES (?,?,?,?,?,?)",
                                       (nct, axp, l["method"], l["matched"], l["confidence"], l["status"]))
                            n_links += 1
                            if l["status"] == "auto":
                                links_by_trial.setdefault(nct, []).append(axp)
                            else:
                                review.append((axp, names.get(axp, ""), nct, l["method"], l["matched"],
                                               rec.get("brief_title") or ""))
                    for a_day, b_day in snapshot_pairs(snap):
                        for nct, typ, sig, field, before, after in changes_between(snap, a_day, b_day):
                            db.execute("INSERT OR REPLACE INTO change_event VALUES (?,?,?,?,?,?,?,?,?,?)", (
                                "AXE-%s-%s-%s" % (b_day, nct, typ.split(".", 1)[1]), b_day, a_day, nct, typ, sig,
                                field, before, after, json.dumps(sorted(links_by_trial.get(nct, [])))))
                    n_events = db.execute("SELECT count(*) FROM change_event").fetchone()[0]
        finally:
            snap.close()
    else:
        log("no snapshot database at %s; programs and names only" % snapshots)

    n_papers, n_grants = add_evidence(db, evidence, alias_rows, links_by_trial, nct_refs)

    with db:
        for k, v in (("schema_version", SCHEMA_VERSION),
                     ("built_at", dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")),
                     ("registry_release", registry_release(registry_dir, today)),
                     ("latest_snapshot", latest), ("previous_snapshot", previous)):
            db.execute("INSERT INTO meta VALUES (?, ?)", (k, v))
    db.execute("PRAGMA optimize")
    db.close()
    os.replace(tmp, out)

    log("built %s: %d programs, %d names, %d trial links (%d to review), %d change events, "
        "%d paper links, %d grant links; latest snapshot %s"
        % (os.path.basename(out), len(programs), len(alias_rows), n_links, len(review), n_events,
           n_papers, n_grants, latest or "none"))
    return out


# --- digest page -----------------------------------------------------------------

PAGE_CSS = """
:root{--bg:#fbfbf9;--fg:#1d1d1b;--muted:#6b6b66;--line:#e2e1dc;--accent:#8a3b12;--chip:#f1efe8}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ecebe6;--muted:#a3a29b;--line:#2e2d2a;--accent:#e08a5a;--chip:#22211f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:860px;margin:0 auto;padding:32px 16px 64px}h1{font-size:1.6rem;margin:0 0 4px}h2{font-size:1.15rem;margin:32px 0 8px}
h3{font-size:1rem;margin:20px 0 6px}.muted{color:var(--muted)}a{color:var(--accent)}
ul{padding-left:20px;margin:6px 0}li{margin:3px 0}.chip{display:inline-block;background:var(--chip);border-radius:4px;padding:0 6px;font-size:.85em}
table{border-collapse:collapse;width:100%;font-size:.92rem}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
td.num{text-align:right;font-variant-numeric:tabular-nums}footer{margin-top:40px;font-size:.85rem;color:var(--muted)}
"""

TYPE_LABEL = {
    "trial.status_changed": "status", "trial.phase_changed": "phase", "trial.results_posted": "results posted",
    "trial.enrollment_changed": "enrolment", "trial.completion_slipped": "completion slipped",
    "trial.sponsor_changed": "sponsor", "trial.intervention_added": "intervention added",
    "trial.new": "new trial", "trial.dropped": "no longer matched",
}


def write_page(db_path, page_path, log=print):
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        meta = dict(con.execute("SELECT key, value FROM meta"))
        latest, previous = meta.get("latest_snapshot", ""), meta.get("previous_snapshot", "")
        programs = con.execute(
            "SELECT p.axp_id, p.preferred_name, p.modality, "
            "(SELECT count(*) FROM trial_link l WHERE l.axp_id = p.axp_id AND l.status = 'auto') "
            "FROM program p WHERE p.status = 'active' ORDER BY p.modality, p.preferred_name").fetchall()
        events = con.execute(
            "SELECT e.nct_id, t.brief_title, e.type, e.significance, e.before, e.after, e.axp_ids "
            "FROM change_event e LEFT JOIN trial t ON t.nct_id = e.nct_id "
            "WHERE e.snapshot_date = ? ORDER BY e.significance, e.nct_id, e.type", (latest,)).fetchall()
    finally:
        con.close()
    names = {p[0]: p[1] for p in programs}
    esc = html.escape
    nct = lambda n: '<a href="https://clinicaltrials.gov/study/%s">%s</a>' % (esc(n), esc(n))
    body = []
    body.append("<h1>What changed</h1>")
    if not previous:
        body.append('<p class="muted">Weekly ClinicalTrials.gov snapshots started on %s. Changes appear here '
                    "once there are two snapshots to compare.</p>" % esc(latest or "(no snapshot yet)"))
    else:
        major = [e for e in events if e[3] == "major"]
        minor = [e for e in events if e[3] == "minor"]
        body.append('<p class="muted">ClinicalTrials.gov, snapshot of %s compared with %s: '
                    "%d major and %d minor changes in the tracked trials.</p>"
                    % (esc(latest), esc(previous), len(major), len(minor)))
        body.append("<h2>Major changes</h2>")
        if not major:
            body.append('<p class="muted">None this week.</p>')
        groups = {}
        for e in major:
            progs = json.loads(e[6]) or [""]
            for p in progs:
                groups.setdefault(p, []).append(e)
        for p in sorted(groups, key=lambda x: (x == "", names.get(x, x).lower())):
            body.append("<h3>%s</h3><ul>" % (esc(names.get(p, p)) if p else "Not linked to a program"))
            for e in groups[p]:
                change = "%s → %s" % (esc(e[4] or "–"), esc(e[5] or "–")) if e[2] != "trial.results_posted" else ""
                body.append('<li>%s %s <span class="chip">%s</span> %s</li>'
                            % (nct(e[0]), esc(e[1] or ""), esc(TYPE_LABEL.get(e[2], e[2])), change))
            body.append("</ul>")
        if minor:
            counts = {}
            for e in minor:
                counts[TYPE_LABEL.get(e[2], e[2])] = counts.get(TYPE_LABEL.get(e[2], e[2]), 0) + 1
            body.append("<h2>Minor changes</h2><p>%s. Full list: the <code>changes</code> API and MCP tool.</p>"
                        % esc(", ".join("%d %s" % (n, t) for t, n in sorted(counts.items(), key=lambda x: -x[1]))))
    body.append("<h2>Tracked programs</h2><table><tr><th>Program</th><th>Kind</th><th class=num>Trials</th></tr>")
    for axp, name, modality, n in programs:
        body.append("<tr><td>%s <span class=muted>%s</span></td><td>%s</td><td class=num>%d</td></tr>"
                    % (esc(name), esc(axp), esc(modality), n))
    body.append("</table>")
    body.append("<footer>Registry release %s. Trials link to programs by the names in the open "
                '<a href="https://github.com/ckangas2/abstractinator/tree/main/registry">program registry</a> '
                "(CC BY 4.0); every program has its own page in the "
                '<a href="registry/index.html">registry pages</a>. Source: ClinicalTrials.gov; not endorsed by NLM. '
                '<a href="/">The Abstractinator</a></footer>' % esc(meta.get("registry_release", "")))
    page = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>What changed · The Abstractinator</title><style>%s</style></head><body><main>%s</main></body></html>\n"
            % (PAGE_CSS, "\n".join(body)))
    os.makedirs(os.path.dirname(os.path.abspath(page_path)), exist_ok=True)
    with open(page_path + ".tmp", "w", encoding="utf-8") as fh:
        fh.write(page)
    os.replace(page_path + ".tmp", page_path)
    log("wrote %s" % page_path)


REVIEW_SQL = """
SELECT 'trial' AS kind, l.axp_id, p.preferred_name, l.nct_id AS ref, l.method, l.matched,
       t.brief_title AS title, '' AS extra
FROM trial_link l JOIN program p ON p.axp_id = l.axp_id LEFT JOIN trial t ON t.nct_id = l.nct_id
WHERE l.status = 'candidate'
"""

REVIEW_PAPER_SQL = """
SELECT 'paper' AS kind, l.axp_id, p.preferred_name, l.pmid AS ref, l.method, l.matched,
       a.title, COALESCE(a.kind, '') AS extra
FROM paper_link l JOIN program p ON p.axp_id = l.axp_id LEFT JOIN paper a ON a.pmid = l.pmid
WHERE l.status = 'candidate'
"""

REVIEW_GRANT_SQL = """
SELECT 'grant' AS kind, l.axp_id, p.preferred_name, l.core_project_num AS ref, l.method, l.matched,
       g.title, COALESCE(g.org, '') AS extra
FROM grant_link l JOIN program p ON p.axp_id = l.axp_id
LEFT JOIN grant_award g ON g.core_project_num = l.core_project_num
WHERE l.status = 'candidate'
"""

REVIEW_HEADERS = ["kind", "axp_id", "program", "reference", "method", "matched", "title", "extra"]


def export_review(db_path, dest, log=print):
    """Write the candidate links in an existing registry database to dest (TSV):
    trials, and papers and grants when those tables exist. Reads the database
    read-only; refuses to overwrite an existing file."""
    if os.path.exists(dest):
        raise SystemExit("%s already exists; not overwriting" % dest)
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        rows = []
        for table, sql in (("trial_link", REVIEW_SQL), ("paper_link", REVIEW_PAPER_SQL),
                           ("grant_link", REVIEW_GRANT_SQL)):
            if table in tables:
                rows += con.execute(sql).fetchall()
    finally:
        con.close()
    rows.sort(key=lambda r: (r[0], str(r[2]), str(r[3])))
    os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write("\t".join(REVIEW_HEADERS) + "\n")
        for row in rows:
            fh.write("\t".join(" ".join(str(x or "").split()) for x in row) + "\n")
    counts = {}
    for row in rows:
        counts[row[0]] = counts.get(row[0], 0) + 1
    log("%d candidate links (%s) -> %s"
        % (len(rows), ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items())) or "none", dest))
    return len(rows)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--registry", default=DEFAULT_REGISTRY)
    ap.add_argument("--snapshots", default=DEFAULT_SNAPSHOTS)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--page", default=DEFAULT_PAGE)
    ap.add_argument("--site", default=DEFAULT_SITE, help='registry web pages ("" to skip)')
    ap.add_argument("--evidence", default=DEFAULT_EVIDENCE,
                    help="papers and grants found by tracker/evidence.py (optional)")
    ap.add_argument("--export-review", metavar="FILE",
                    help="don't build; write the candidate links of the existing database to FILE")
    args = ap.parse_args(argv)
    if args.export_review:
        export_review(args.out, os.path.expanduser(args.export_review))
        return 0
    out = build(args.registry, args.snapshots, args.out, evidence=args.evidence)
    if args.page:
        write_page(out, args.page)
    if args.site:
        import site_pages  # here, not at the top: site_pages imports this module
        site_pages.write_site(out, args.site)
    return 0


if __name__ == "__main__":
    sys.exit(main())
