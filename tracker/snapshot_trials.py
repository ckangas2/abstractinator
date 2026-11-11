#!/usr/bin/env python3
"""Weekly snapshot of ClinicalTrials.gov records for the tracked topics.

History is the point: a trial's record is overwritten in place when its status,
phase or enrolment changes, so the only way to know what changed (and when we
first saw it) is to keep copies. Each run fetches every trial matching the
queries in tracker/snapshot_scope.tsv, reduces each to a fixed set of fields
that matter for "what changed" (status, phase, dates, interventions, sponsor,
results...), and writes:

    <out>/<YYYY-MM-DD>/trials.jsonl.gz   one canonical record per trial, sorted
    <out>/<YYYY-MM-DD>/manifest.json     counts per query, completeness, timings
    <out>/raw/<NCT id>/<hash>.json.gz    the fetched record, only when its
                                         canonical content is new

A snapshot directory appears only once complete (it is built under a temporary
name and renamed). An existing snapshot is never overwritten or deleted: with
--force the old one is kept beside it under a ".replaced-..." name.

Standard library only (Python 3.8+), so cron can run it with the system python.

Usage:
    python3 tracker/snapshot_trials.py                 # take today's snapshot
    python3 tracker/snapshot_trials.py --dry-run       # one small page per query, write nothing
    python3 tracker/snapshot_trials.py --status        # age of the newest snapshot; exit 1 if stale
Options:
    --out DIR      where snapshots live (default: <repo>/data/trial_snapshots)
    --scope FILE   query list (default: tracker/snapshot_scope.tsv)
    --force        take a snapshot even if today's exists (the old one is kept)
"""

import argparse
import csv
import datetime as dt
import gzip
import hashlib
import io
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SCRIPT_VERSION = "1"
API = "https://clinicaltrials.gov/api/v2/studies"
USER_AGENT = "AbstractinatorTrialSnapshots/1 (+https://abstractinator.me)"
PAGE_SIZE = 500
PAUSE_SECONDS = 1.0          # between requests: about one per second
STALE_DAYS = 8               # --status fails when the newest snapshot is older

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_OUT = os.path.join(REPO, "data", "trial_snapshots")
DEFAULT_SCOPE = os.path.join(HERE, "snapshot_scope.tsv")

# Only the parts of a record the canonical fields come from. If the API ever
# rejects this list, the run falls back to whole records (and says so).
FIELDS = "|".join([
    "IdentificationModule", "StatusModule", "SponsorCollaboratorsModule",
    "DesignModule", "ArmsInterventionsModule", "ConditionsModule",
    "OutcomesModule", "ContactsLocationsModule", "ReferencesModule", "HasResults",
])

# Fields that change without the trial changing: excluded from content_hash.
UNHASHED = ("last_update_post_date", "status_verified_date")


# --- canonical record ---------------------------------------------------------

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

def gz_bytes(text):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:   # mtime=0: same content, same bytes
        gz.write(text.encode("utf-8"))
    return buf.getvalue()


def write_new(path, data):
    """Write a file that must not exist yet (raw archive entries are immutable)."""
    if os.path.exists(path):
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.rename(tmp, path)
    return True


def take_snapshot(out_dir, scope, today=None, force=False, get=http_get_json, log=print):
    today = today or dt.date.today().isoformat()
    final = os.path.join(out_dir, today)
    if os.path.exists(final) and not force:
        log("snapshot %s already exists; nothing to do (use --force to take another)" % today)
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

    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.join(out_dir, ".%s.tmp" % today)
    if os.path.exists(tmp):
        shutil.rmtree(tmp)      # our own leftover from an interrupted run
    os.makedirs(tmp)
    lines = []
    for nct in sorted(records):
        rec = records[nct]
        rec["matched_queries"] = sorted(set(rec["matched_queries"]))
        lines.append(json.dumps(rec, sort_keys=True, ensure_ascii=False))
    with open(os.path.join(tmp, "trials.jsonl.gz"), "wb") as fh:
        fh.write(gz_bytes("\n".join(lines) + "\n"))

    new_raw = 0
    for nct, study in raw.items():
        path = os.path.join(out_dir, "raw", nct, records[nct]["content_hash"][:16] + ".json.gz")
        if write_new(path, gz_bytes(json.dumps(strip_contacts(study), sort_keys=True, ensure_ascii=False))):
            new_raw += 1

    manifest = {
        "snapshot_date": today,
        "started_at": started,
        "finished_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "script_version": SCRIPT_VERSION,
        "api": API,
        "used_field_list": use_fields,
        "queries": per_query,
        "complete": all(q["complete"] and not q["error"] for q in per_query),
        "n_trials": len(records),
        "n_new_raw_versions": new_raw,
    }
    with open(os.path.join(tmp, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")

    if os.path.exists(final):
        kept = "%s.replaced-%s" % (final, dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.rename(final, kept)
        log("kept the earlier snapshot as %s" % os.path.basename(kept))
    os.rename(tmp, final)
    log("snapshot %s: %d trials, %d new record versions archived, complete=%s"
        % (today, len(records), new_raw, manifest["complete"]))
    return 0 if manifest["complete"] else 3


def latest_snapshot(out_dir):
    if not os.path.isdir(out_dir):
        return None
    days = sorted(d for d in os.listdir(out_dir)
                  if len(d) == 10 and d[4] == "-" and os.path.isfile(os.path.join(out_dir, d, "manifest.json")))
    return days[-1] if days else None


def status(out_dir, today=None, log=print):
    day = latest_snapshot(out_dir)
    if not day:
        log("no snapshots in %s" % out_dir)
        return 1
    with open(os.path.join(out_dir, day, "manifest.json"), encoding="utf-8") as fh:
        m = json.load(fh)
    today = dt.date.fromisoformat(today) if today else dt.date.today()
    age = (today - dt.date.fromisoformat(day)).days
    ok = age <= STALE_DAYS and m.get("complete")
    log("latest snapshot %s (%d days old): %d trials, complete=%s%s"
        % (day, age, m.get("n_trials", 0), m.get("complete"), "" if ok else "  <- needs attention"))
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
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--scope", default=DEFAULT_SCOPE)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args(argv)
    if args.status:
        return status(args.out)
    scope = read_scope(args.scope)
    if args.dry_run:
        return dry_run(scope)
    return take_snapshot(args.out, scope, force=args.force)


if __name__ == "__main__":
    sys.exit(main())
