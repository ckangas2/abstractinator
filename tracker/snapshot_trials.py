#!/usr/bin/env python3
"""Weekly snapshot of ClinicalTrials.gov records for the tracked topics.

History is the point: a trial's record is overwritten in place when its status,
phase or enrolment changes, so the only way to know what changed (and when we
first saw it) is to keep copies. Each run fetches every trial matching the
queries in tracker/snapshot_scope.tsv, reduces each to a fixed set of fields
that matter for "what changed" (status, phase, dates, interventions, sponsor,
results...), and records it in one SQLite database:

    snapshot       one row per run: date, timings, complete or not, per-query counts
    trial_version  each distinct version of a trial, stored once: the tracked
                   fields (record, JSON) and the fetched API record (raw,
                   zlib-compressed JSON, contact details removed)
    observation    one row per trial per run: which version was seen that week

Comparing two weeks is a join on observation (see CHANGES_SQL below). A run is
written in a single transaction, so a snapshot is either all there or absent,
and a snapshot date is written once: rows are only ever added.

Standard library only (Python 3.8+), so cron can run it with the system python.

Usage:
    python3 tracker/snapshot_trials.py                 # take today's snapshot
    python3 tracker/snapshot_trials.py --dry-run       # one small page per query, write nothing
    python3 tracker/snapshot_trials.py --status        # age of the newest snapshot; exit 1 if stale
    python3 tracker/snapshot_trials.py --import-legacy DIR
                    # load snapshots taken with the first, file-per-trial layout
Options:
    --db FILE      the database (default: <repo>/data/trial_snapshots/trials.sqlite)
    --scope FILE   query list (default: tracker/snapshot_scope.tsv)
"""

import argparse
import csv
import datetime as dt
import gzip
import hashlib
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

SCRIPT_VERSION = "2"
SCHEMA_VERSION = "1"
API = "https://clinicaltrials.gov/api/v2/studies"
USER_AGENT = "AbstractinatorTrialSnapshots/1 (+https://abstractinator.me)"
PAGE_SIZE = 500
PAUSE_SECONDS = 1.0          # between requests: about one per second
STALE_DAYS = 8               # --status fails when the newest snapshot is older

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_DB = os.path.join(REPO, "data", "trial_snapshots", "trials.sqlite")
DEFAULT_SCOPE = os.path.join(HERE, "snapshot_scope.tsv")

# Only the parts of a record the canonical fields come from. If the API ever
# rejects this list, the run falls back to whole records (and says so).
FIELDS = "|".join([
    "IdentificationModule", "StatusModule", "SponsorCollaboratorsModule",
    "DesignModule", "ArmsInterventionsModule", "ConditionsModule",
    "OutcomesModule", "ContactsLocationsModule", "ReferencesModule", "HasResults",
])

# Fields that change without the trial changing: excluded from content_hash,
# and kept per observation rather than per version.
UNHASHED = ("last_update_post_date", "status_verified_date")

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS snapshot (
  snapshot_date  TEXT PRIMARY KEY,            -- YYYY-MM-DD
  started_at     TEXT NOT NULL,               -- UTC, ISO 8601
  finished_at    TEXT NOT NULL,
  script_version TEXT NOT NULL,
  complete       INTEGER NOT NULL,            -- 1 if every query was fetched in full
  n_trials       INTEGER NOT NULL,
  n_new_versions INTEGER NOT NULL,
  manifest       TEXT NOT NULL                -- JSON: per-query counts and errors
);
CREATE TABLE IF NOT EXISTS trial_version (
  nct_id       TEXT NOT NULL,
  content_hash TEXT NOT NULL,                 -- sha256 of record
  first_seen   TEXT NOT NULL REFERENCES snapshot(snapshot_date),
  record       TEXT NOT NULL,                 -- JSON: the tracked fields
  raw          BLOB,                          -- zlib JSON: the API record, contacts removed
  PRIMARY KEY (nct_id, content_hash)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS observation (
  snapshot_date         TEXT NOT NULL REFERENCES snapshot(snapshot_date),
  nct_id                TEXT NOT NULL,
  content_hash          TEXT NOT NULL,
  last_update_post_date TEXT,
  status_verified_date  TEXT,
  matched_queries       TEXT NOT NULL,        -- JSON list of query ids
  PRIMARY KEY (snapshot_date, nct_id),
  FOREIGN KEY (nct_id, content_hash) REFERENCES trial_version(nct_id, content_hash)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS observation_by_trial ON observation(nct_id, snapshot_date);
"""

# Trials whose tracked fields differ between two snapshots (:a earlier, :b later).
CHANGES_SQL = """
SELECT b.nct_id, a.content_hash AS before_hash, b.content_hash AS after_hash
FROM observation a JOIN observation b ON a.nct_id = b.nct_id
WHERE a.snapshot_date = :a AND b.snapshot_date = :b AND a.content_hash <> b.content_hash
ORDER BY b.nct_id
"""


def _get(obj, *path):
    for key in path:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(key)
    return obj


def _text(x):
    if x is None:
        return None
    x = " ".join(str(x).split())
    return x or None


def _list(x):
    return x if isinstance(x, list) else []


def _int(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


def canonical(study):
    """The fields we track for one study (an API v2 study object), as a flat dict.

    Lists are sorted and de-duplicated so that a reordering in the registry is
    not a change. Missing values are None. Contact details are never kept.
    """
    ps = study.get("protocolSection") or {}
    ident = ps.get("identificationModule") or {}
    status = ps.get("statusModule") or {}
    sponsor = ps.get("sponsorCollaboratorsModule") or {}
    design = ps.get("designModule") or {}
    arms = ps.get("armsInterventionsModule") or {}
    conds = ps.get("conditionsModule") or {}
    outcomes = ps.get("outcomesModule") or {}
    locs = ps.get("contactsLocationsModule") or {}
    refs = ps.get("referencesModule") or {}

    interventions = []
    seen = set()
    for iv in _list(arms.get("interventions")):
        if not isinstance(iv, dict):
            continue
        item = {
            "type": _text(iv.get("type")),
            "name": _text(iv.get("name")),
            "other_names": sorted({t for t in (_text(o) for o in _list(iv.get("otherNames"))) if t}),
        }
        key = json.dumps(item, sort_keys=True)
        if item["name"] and key not in seen:
            seen.add(key)
            interventions.append(item)
    interventions.sort(key=lambda d: ((d["name"] or "").lower(), d["type"] or ""))

    primary = sorted(
        "%s|%s" % (_text(o.get("measure")) or "", _text(o.get("timeFrame")) or "")
        for o in _list(outcomes.get("primaryOutcomes")) if isinstance(o, dict)
    )
    primary_hash = (hashlib.sha256("\n".join(primary).encode("utf-8")).hexdigest()[:16]
                    if primary else None)

    locations = [l for l in _list(locs.get("locations")) if isinstance(l, dict)]
    references = sorted(
        {(_text(r.get("pmid")), _text(r.get("type"))) for r in _list(refs.get("references"))
         if isinstance(r, dict) and _text(r.get("pmid"))},
        key=lambda t: (t[0], t[1] or ""),
    )

    def date(struct):
        return _text(_get(status, struct, "date")), _text(_get(status, struct, "type"))

    start, start_type = date("startDateStruct")
    pcd, pcd_type = date("primaryCompletionDateStruct")
    cd, cd_type = date("completionDateStruct")

    rec = {
        "nct_id": _text(ident.get("nctId")),
        "brief_title": _text(ident.get("briefTitle")),
        "study_type": _text(design.get("studyType")),
        "overall_status": _text(status.get("overallStatus")),
        "why_stopped": _text(status.get("whyStopped")),
        "phases": sorted({p for p in (_text(x) for x in _list(design.get("phases"))) if p}),
        "enrollment_count": _int(_get(design, "enrollmentInfo", "count")),
        "enrollment_type": _text(_get(design, "enrollmentInfo", "type")),
        "start_date": start, "start_date_type": start_type,
        "primary_completion_date": pcd, "primary_completion_date_type": pcd_type,
        "completion_date": cd, "completion_date_type": cd_type,
        "lead_sponsor": _text(_get(sponsor, "leadSponsor", "name")),
        "lead_sponsor_class": _text(_get(sponsor, "leadSponsor", "class")),
        "collaborators": sorted({c for c in (_text(_get(x, "name")) for x in _list(sponsor.get("collaborators"))) if c}),
        "interventions": interventions,
        "conditions": sorted({c for c in (_text(x) for x in _list(conds.get("conditions"))) if c}),
        "primary_outcomes_hash": primary_hash,
        "has_results": bool(study.get("hasResults")),
        "countries": sorted({c for c in (_text(l.get("country")) for l in locations) if c}),
        "n_locations": len(locations),
        "references": [{"pmid": p, "type": t} for p, t in references],
        "first_post_date": _text(_get(status, "studyFirstPostDateStruct", "date")),
        "last_update_post_date": _text(_get(status, "lastUpdatePostDateStruct", "date")),
        "status_verified_date": _text(status.get("statusVerifiedDate")),
    }
    rec["content_hash"] = content_hash(rec)
    return rec


def content_hash(rec):
    body = {k: v for k, v in rec.items() if k not in UNHASHED and k not in ("content_hash", "matched_queries")}
    return hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def strip_contacts(study):
    """A copy of the fetched record without people's contact details, for the raw archive."""
    study = json.loads(json.dumps(study))
    locs = _get(study, "protocolSection", "contactsLocationsModule")
    if isinstance(locs, dict):
        locs.pop("centralContacts", None)
        for l in _list(locs.get("locations")):
            if isinstance(l, dict):
                l.pop("contacts", None)
    return study


# --- fetching -----------------------------------------------------------------

class FieldsRejected(Exception):
    pass


def http_get_json(params, retries=3, timeout=120):
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    delay = 5.0
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 400 and "fields" in params:
                raise FieldsRejected(e.read()[:300].decode("utf-8", "replace"))
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                time.sleep(delay)
                delay *= 2
                continue
            raise RuntimeError("HTTP %d from ClinicalTrials.gov" % e.code)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt < retries:
                time.sleep(delay)
                delay *= 2
                continue
            raise RuntimeError("network error: %s" % e)


def fetch_query(query, use_fields, page_size=PAGE_SIZE, max_pages=None, get=http_get_json):
    """All studies matching one query. Returns (studies, total_count, pages, used_fields)."""
    studies, token, pages, total = [], None, 0, None
    while True:
        params = {"format": "json", "query.term": query, "pageSize": page_size, "countTotal": "true"}
        if use_fields:
            params["fields"] = FIELDS
        if token:
            params["pageToken"] = token
        try:
            data = get(params)
        except FieldsRejected:
            if pages:
                raise RuntimeError("the API rejected the field list part-way through a query")
            use_fields = False
            continue
        pages += 1
        if total is None:
            total = data.get("totalCount")
        studies.extend(s for s in _list(data.get("studies")) if isinstance(s, dict))
        token = data.get("nextPageToken")
        if not token or (max_pages and pages >= max_pages):
            break
        time.sleep(PAUSE_SECONDS)
    return studies, total, pages, use_fields


def read_scope(path):
    with open(path, encoding="utf-8", newline="") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    out = []
    for r in rows:
        qid, q = (r.get("query_id") or "").strip(), (r.get("query") or "").strip()
        if qid and q and not qid.startswith("#"):
            out.append((qid, q))
    if not out:
        raise SystemExit("no queries in %s" % path)
    if len({q for q, _ in out}) != len(out):
        raise SystemExit("duplicate query_id in %s" % path)
    return out


# --- writing ------------------------------------------------------------------
# --- storing ------------------------------------------------------------------

def tracked_fields(rec):
    """The part of a canonical record that content_hash covers."""
    return {k: v for k, v in rec.items() if k not in UNHASHED and k not in ("content_hash", "matched_queries")}


def compress(obj):
    return zlib.compress(json.dumps(obj, sort_keys=True, ensure_ascii=False).encode("utf-8"), 9)


def decompress(blob):
    return json.loads(zlib.decompress(blob).decode("utf-8"))


def connect(db_path):
    d = os.path.dirname(os.path.abspath(db_path))
    os.makedirs(d, exist_ok=True)
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA foreign_keys = ON")
    con.executescript(SCHEMA)
    row = con.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
    if row is None:
        with con:
            con.execute("INSERT INTO meta VALUES ('schema_version', ?)", (SCHEMA_VERSION,))
    elif row[0] != SCHEMA_VERSION:
        raise SystemExit("database schema %s, this script writes %s" % (row[0], SCHEMA_VERSION))
    return con


def store_snapshot(con, day, records, raw, manifest):
    """Write one snapshot in a single transaction. Returns the number of new versions."""
    new_versions = 0
    with con:   # commits on success, rolls back everything on any error
        con.execute(
            "INSERT INTO snapshot VALUES (?, ?, ?, ?, ?, ?, 0, ?)",
            (day, manifest["started_at"], manifest["finished_at"], manifest["script_version"],
             int(manifest["complete"]), len(records), json.dumps(manifest, sort_keys=True)))
        for nct in sorted(records):
            rec = records[nct]
            cur = con.execute(
                "INSERT OR IGNORE INTO trial_version VALUES (?, ?, ?, ?, ?)",
                (nct, rec["content_hash"], day,
                 json.dumps(tracked_fields(rec), sort_keys=True, ensure_ascii=False),
                 compress(strip_contacts(raw[nct])) if raw.get(nct) is not None else None))
            new_versions += cur.rowcount
            con.execute(
                "INSERT INTO observation VALUES (?, ?, ?, ?, ?, ?)",
                (day, nct, rec["content_hash"], rec.get("last_update_post_date"),
                 rec.get("status_verified_date"), json.dumps(sorted(set(rec["matched_queries"])))))
        con.execute("UPDATE snapshot SET n_new_versions = ? WHERE snapshot_date = ?", (new_versions, day))
    return new_versions


def take_snapshot(db_path, scope, today=None, get=http_get_json, log=print):
    today = today or dt.date.today().isoformat()
    con = connect(db_path)
    try:
        if con.execute("SELECT 1 FROM snapshot WHERE snapshot_date = ?", (today,)).fetchone():
            log("snapshot %s already taken; nothing to do" % today)
            return 0
        started = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        records, raw, per_query, use_fields = {}, {}, [], True
        for qid, query in scope:
            entry = {"query_id": qid, "query": query, "total_count": None, "fetched": 0,
                     "pages": 0, "complete": False, "error": None}
            try:
                studies, total, pages, use_fields = fetch_query(query, use_fields, get=get)
                entry.update(total_count=total, fetched=len(studies), pages=pages,
                             complete=(total is None or len(studies) >= total))
            except Exception as e:  # one failed query must not lose the others
                studies = []
                entry["error"] = str(e)
            for s in studies:
                rec = canonical(s)
                nct = rec["nct_id"]
                if not nct:
                    continue
                if nct in records:
                    records[nct]["matched_queries"].append(qid)
                else:
                    rec["matched_queries"] = [qid]
                    records[nct] = rec
                    raw[nct] = s
            per_query.append(entry)
            log("%-12s %5d of %s trials%s" % (qid, entry["fetched"], entry["total_count"],
                                              "" if not entry["error"] else "  ERROR: " + entry["error"]))
            time.sleep(PAUSE_SECONDS)

        if not records:
            log("nothing fetched; no snapshot written")
            return 1
        manifest = {
            "snapshot_date": today, "started_at": started,
            "finished_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "script_version": SCRIPT_VERSION, "api": API, "used_field_list": use_fields,
            "queries": per_query,
            "complete": all(q["complete"] and not q["error"] for q in per_query),
        }
        new = store_snapshot(con, today, records, raw, manifest)
        log("snapshot %s: %d trials, %d new versions stored, complete=%s"
            % (today, len(records), new, manifest["complete"]))
        return 0 if manifest["complete"] else 3
    finally:
        con.close()


def import_legacy(db_path, legacy_dir, log=print):
    """Load snapshots written by script version 1 (<date>/trials.jsonl.gz + raw/<NCT>/<hash16>.json.gz).

    Every record's hash is recomputed and every version must have its raw
    record, or nothing is written. The legacy files are left untouched.
    """
    days = sorted(d for d in os.listdir(legacy_dir)
                  if len(d) == 10 and d[4] == "-" and os.path.isfile(os.path.join(legacy_dir, d, "manifest.json")))
    if not days:
        log("no legacy snapshots in %s" % legacy_dir)
        return 1
    con = connect(db_path)
    try:
        for day in days:
            if con.execute("SELECT 1 FROM snapshot WHERE snapshot_date = ?", (day,)).fetchone():
                log("%s already in the database; skipped" % day)
                continue
            with open(os.path.join(legacy_dir, day, "manifest.json"), encoding="utf-8") as fh:
                manifest = json.load(fh)
            records, raw = {}, {}
            with gzip.open(os.path.join(legacy_dir, day, "trials.jsonl.gz"), "rt", encoding="utf-8") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    rec = json.loads(line)
                    if content_hash(rec) != rec["content_hash"]:
                        raise SystemExit("%s %s: stored hash doesn't match its fields" % (day, rec["nct_id"]))
                    path = os.path.join(legacy_dir, "raw", rec["nct_id"], rec["content_hash"][:16] + ".json.gz")
                    if not os.path.isfile(path):
                        raise SystemExit("%s %s: raw record missing (%s)" % (day, rec["nct_id"], path))
                    with gzip.open(path, "rt", encoding="utf-8") as rf:
                        raw[rec["nct_id"]] = json.load(rf)   # already without contacts
                    records[rec["nct_id"]] = rec
            if len(records) != manifest.get("n_trials"):
                raise SystemExit("%s: %d records but the manifest says %s"
                                 % (day, len(records), manifest.get("n_trials")))
            manifest = dict(manifest, imported_from="script version 1 file layout")
            new = store_snapshot(con, day, records, raw, manifest)
            log("imported %s: %d trials, %d versions" % (day, len(records), new))
        return 0
    finally:
        con.close()


def status(db_path, today=None, log=print):
    if not os.path.isfile(db_path):
        log("no snapshot database at %s" % db_path)
        return 1
    con = connect(db_path)
    try:
        row = con.execute("SELECT snapshot_date, n_trials, complete FROM snapshot "
                          "ORDER BY snapshot_date DESC LIMIT 1").fetchone()
        n_snap, n_ver = con.execute("SELECT (SELECT count(*) FROM snapshot), "
                                    "(SELECT count(*) FROM trial_version)").fetchone()
    finally:
        con.close()
    if not row:
        log("no snapshots yet in %s" % db_path)
        return 1
    day, n, complete = row
    today = dt.date.fromisoformat(today) if today else dt.date.today()
    age = (today - dt.date.fromisoformat(day)).days
    ok = age <= STALE_DAYS and bool(complete)
    log("latest snapshot %s (%d days old): %d trials, complete=%s; %d snapshots, %d trial versions, %.1f MB%s"
        % (day, age, n, bool(complete), n_snap, n_ver, os.path.getsize(db_path) / 1e6,
           "" if ok else "  <- needs attention"))
    return 0 if ok else 1


def dry_run(scope, get=http_get_json, log=print):
    for qid, query in scope:
        studies, total, pages, used = fetch_query(query, True, page_size=5, max_pages=1, get=get)
        log("%-12s %s trials match; field list accepted: %s" % (qid, total, used))
        if studies:
            log(json.dumps(canonical(studies[0]), indent=2, ensure_ascii=False))
        time.sleep(PAUSE_SECONDS)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--scope", default=DEFAULT_SCOPE)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--import-legacy", metavar="DIR")
    args = ap.parse_args(argv)
    if args.status:
        return status(args.db)
    if args.import_legacy:
        return import_legacy(args.db, args.import_legacy)
    scope = read_scope(args.scope)
    if args.dry_run:
        return dry_run(scope)
    return take_snapshot(args.db, scope)


if __name__ == "__main__":
    sys.exit(main())
