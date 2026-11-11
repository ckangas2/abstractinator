#!/usr/bin/env python3
"""Check that everything a registry entry cites can still be reached.

A curated row is only as good as its evidence, so before a proposed alias is
accepted, every link it rests on is visited:

  * `evidence_url` on each alias, virus and approval row of the programs
    checked (an HTTP GET; a 2xx or 3xx counts, anything else does not).
    Links to EMA are confirmed against the two lists EMA publishes of its
    medicine pages and EPAR documents, because its site refuses robots;
  * every NCT number named in those programs' rows, against the
    ClinicalTrials.gov API (the study must exist);
  * every PMID named in them, against the NCBI E-utilities summary endpoint
    (the record must exist and not be an error).

NCT numbers and PMIDs are found in `notes`, `source_record` and the evidence
links themselves, so a citation written in prose is checked too.

    python3 tracker/refcheck.py --programs AXP000215-AXP000247
    python3 tracker/refcheck.py --programs AXP000215-AXP000247 --accept

Without --accept nothing is written: the run prints one line per reference
and a summary, and exits 1 if anything is unreachable. With --accept, and
only if every reference of a program resolved, that program's `proposed`
aliases become `accepted` (aliases.tsv is rewritten in place after a
timestamped backup in ~/abstractinator-backups/). A program with a bad
reference is left alone and named in the summary.

Standard library only, same HTTP manners as tracker/evidence.py: one request
at a time, spaced per host (further apart for hosts that throttle, see
HOST_PAUSE), each URL fetched once per run, 429 obeyed patiently and 5xx
retried.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registry as reg  # noqa: E402

USER_AGENT = "AbstractinatorRefcheck/1 (+https://abstractinator.me)"
PAUSE_SECONDS = 1.0
TIMEOUT = 45
RETRIES = 3

# Some hosts rate-limit a run of requests even at one a second. EMA answered
# 429 to nine EPAR pages in a row on 2026-11-11, so its requests are spaced
# further apart; anything not listed keeps the one-second default.
HOST_PAUSE = {"www.ema.europa.eu": 4.0, "ema.europa.eu": 4.0}

# EMA's medicine pages sit behind a filter that answers 429 however slowly we
# knock (bigtop, 2026-11-11: the PDF under /en/documents/ came back 200 while
# /en/medicines/human/EPAR/... was refused four times at 15 s apart). Rather
# than knock harder, read the lists EMA publishes for exactly this purpose:
# two JSON files, refreshed twice a day, naming every centrally authorised
# medicine's page and every EPAR document. A link that appears there is live,
# which is a better check than a 200 anyway, and it costs two requests for the
# whole run instead of one per citation. Nothing from these files is kept:
# they are read to confirm links and then dropped.
EMA_MEDICINES_JSON = ("https://www.ema.europa.eu/en/documents/report/"
                      "medicines-output-medicines_json-report_en.json")
EMA_EPAR_DOCUMENTS_JSON = ("https://www.ema.europa.eu/en/documents/report/"
                           "documents-output-epar_documents_json-report_en.json")
EMA_HOSTS = {"www.ema.europa.eu", "ema.europa.eu"}
# A 429 is the host asking us to wait, not a dead link, so it is retried more
# patiently than a server error, and Retry-After is obeyed when given. The
# waits are capped and announced: a silent five-minute sleep looks exactly
# like a hang, which is how the first version of this read on 2026-11-11.
THROTTLE_RETRIES = 4
THROTTLE_BACKOFF = 8.0
THROTTLE_MAX_WAIT = 30.0

NCT_RE = re.compile(r"\bNCT[0-9]{8}\b")
PMID_RE = re.compile(r"\bPMID[: ]*([0-9]{5,9})\b|pubmed\.ncbi\.nlm\.nih\.gov/([0-9]{5,9})")
ID_RANGE_RE = re.compile(r"^AXP([0-9]{6})-AXP([0-9]{6})$")

_last = {}        # host -> when it was last asked
_ema_index = [None]   # the URLs EMA publishes, read at most once per run
_seen = {}        # url -> (ok, detail, body), so a link shared by several
                  # programs is fetched once


def say(msg):
    print(msg, flush=True)


def _pause(host):
    """Keep this host's requests at least its own interval apart."""
    gap = HOST_PAUSE.get(host, PAUSE_SECONDS)
    wait = _last.get(host, 0.0) + gap - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _last[host] = time.monotonic()


def _read_json(url):
    """The whole of a published JSON file (fetch() caps its reads, so this does
    its own request). None if it cannot be read.

    These files are the fallback for a host that refuses robots, so a 429 here
    is worth waiting out: the whole run depends on them, where a single
    citation does not."""
    host = urllib.parse.urlsplit(url).netloc
    name = url.rsplit("/", 1)[-1]
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                               "Accept": "application/json"})
    wait = THROTTLE_BACKOFF
    for attempt in range(THROTTLE_RETRIES + 1):
        _pause(host)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT * 4) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if attempt >= THROTTLE_RETRIES:
                say("     could not read %s (HTTP %d)" % (name, e.code))
                return None
            after = e.headers.get("Retry-After") if e.headers else None
            pause = min(float(after) if after and str(after).isdigit() else wait,
                        THROTTLE_MAX_WAIT)
            say("     HTTP %d reading %s, waiting %ds (try %d of %d)"
                % (e.code, name, round(pause), attempt + 1, THROTTLE_RETRIES))
            time.sleep(pause)
            wait = min(wait * 2, THROTTLE_MAX_WAIT)
        except Exception as e:
            if attempt >= THROTTLE_RETRIES:
                say("     could not read %s (%s)" % (name, type(e).__name__))
                return None
            time.sleep(min(wait, THROTTLE_MAX_WAIT))
            wait = min(wait * 2, THROTTLE_MAX_WAIT)


def ema_index():
    """Every medicine page and EPAR document URL EMA publishes, lower-cased
    and without trailing slashes. An empty set means the lists could not be
    read, and callers fall back to fetching the page itself."""
    if _ema_index[0] is not None:
        return _ema_index[0]
    urls = set()
    say("     reading EMA's published medicine and document lists (two files)")
    for source, field in ((EMA_MEDICINES_JSON, "medicine_url"),
                          (EMA_EPAR_DOCUMENTS_JSON, "document_url")):
        data = _read_json(source)
        for row in (data or {}).get("data", []):
            value = row.get(field)
            if value:
                urls.add(value.rstrip("/").lower())
            for t in (row.get("translations") or {}).values():
                if isinstance(t, str) and t.startswith("http"):
                    urls.add(t.rstrip("/").lower())
    if urls:
        say("     EMA lists %d medicine and document links" % len(urls))
    _ema_index[0] = urls
    return urls


def fetch(url, accept="*/*"):
    """(ok, detail, body) for one GET. 2xx and 3xx are ok; everything else is
    not. The same URL is fetched once per run, however many programs cite it."""
    if url in _seen:
        ok, detail, body = _seen[url]
        return ok, detail + " (already checked)", body
    host = urllib.parse.urlsplit(url).netloc
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    delay = 4.0
    throttle_delay = THROTTLE_BACKOFF
    attempt = 0
    throttled = 0
    while True:
        _pause(host)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                out = (True, "HTTP %d" % resp.status, resp.read(200000))
                _seen[url] = out
                return out
        except urllib.error.HTTPError as e:
            if e.code == 429 and throttled < THROTTLE_RETRIES:
                after = e.headers.get("Retry-After") if e.headers else None
                wait = min(float(after) if after and str(after).isdigit() else throttle_delay,
                           THROTTLE_MAX_WAIT)
                say("     429 from %s, waiting %ds (try %d of %d)"
                    % (host, round(wait), throttled + 1, THROTTLE_RETRIES))
                time.sleep(wait)
                throttle_delay = min(throttle_delay * 2, THROTTLE_MAX_WAIT)
                throttled += 1
                continue
            if e.code in (500, 502, 503, 504) and attempt < RETRIES:
                time.sleep(delay)
                delay *= 2
                attempt += 1
                continue
            detail = "HTTP %d" % e.code
            if e.code == 429:
                detail = ("HTTP 429 (still throttled after %d tries; not shown to be dead)"
                          % THROTTLE_RETRIES)
            out = (False, detail, b"")
            _seen[url] = out
            return out
        except Exception as e:  # network error, TLS, timeout
            if attempt < RETRIES:
                time.sleep(delay)
                delay *= 2
                attempt += 1
                continue
            out = (False, type(e).__name__ + ": " + str(e)[:120], b"")
            _seen[url] = out
            return out


def check_url(url):
    if urllib.parse.urlsplit(url).netloc in EMA_HOSTS:
        listed = ema_index()
        if listed and url.rstrip("/").lower() in listed:
            return True, "listed in EMA's published data"
        # Not listed, or the lists could not be read: ask the site itself,
        # which still works for documents and older pages.
    ok, detail, _ = fetch(url)
    return ok, detail


def check_nct(nct):
    ok, detail, body = fetch("https://clinicaltrials.gov/api/v2/studies/" + nct,
                             accept="application/json")
    if not ok:
        return False, detail
    try:
        data = json.loads(body.decode("utf-8"))
    except ValueError:
        return False, "reply was not JSON"
    got = (data.get("protocolSection", {}).get("identificationModule", {}).get("nctId"))
    return (got == nct), ("found" if got == nct else "registry returned %r" % got)


def check_pmid(pmid):
    url = ("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&retmode=json&id="
           + pmid)
    ok, detail, body = fetch(url, accept="application/json")
    if not ok:
        return False, detail
    try:
        data = json.loads(body.decode("utf-8"))
    except ValueError:
        return False, "reply was not JSON"
    rec = data.get("result", {}).get(pmid)
    if not rec or "error" in rec:
        return False, "no such PMID"
    return True, "found"


def wanted_ids(spec, programs):
    """The AXP ids named by --programs: a range, a comma list, or 'all'."""
    if spec in (None, "", "all"):
        return [p["axp_id"] for p in programs if p["status"] == "active"]
    m = ID_RANGE_RE.match(spec)
    if m:
        lo, hi = int(m.group(1)), int(m.group(2))
        return ["AXP%06d" % n for n in range(lo, hi + 1)]
    return [s.strip() for s in spec.split(",") if s.strip()]


def references(rows, ids):
    """{axp_id: {"urls": set, "ncts": set, "pmids": set}} for the rows given."""
    out = {}
    for kind, rs in rows.items():
        for row in rs:
            axp = row.get("axp_id")
            if axp not in ids:
                continue
            ref = out.setdefault(axp, {"urls": set(), "ncts": set(), "pmids": set()})
            url = row.get("evidence_url", "")
            if url.startswith(("http://", "https://")):
                ref["urls"].add(url)
            text = " ".join(str(row.get(c, "")) for c in
                            ("notes", "source_record", "evidence_url", "indication"))
            ref["ncts"].update(NCT_RE.findall(text))
            for a, b in PMID_RE.findall(text):
                ref["pmids"].add(a or b)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry", default=reg.DEFAULT_DIR, help="registry directory")
    ap.add_argument("--programs", default="all",
                    help="AXP000215-AXP000247, a comma-separated list, or all (default)")
    ap.add_argument("--accept", action="store_true",
                    help="flip these programs' proposed aliases to accepted if every "
                         "reference resolved")
    ap.add_argument("--backup-dir", default=os.path.expanduser("~/abstractinator-backups"))
    args = ap.parse_args(argv)

    programs, _ = reg.read_tsv(os.path.join(args.registry, "programs.tsv"), reg.PROGRAM_COLUMNS)
    aliases, _ = reg.read_tsv(os.path.join(args.registry, "aliases.tsv"), reg.ALIAS_COLUMNS)
    extra = reg.read_optional(args.registry)
    viruses, approvals = extra[0][0], extra[1][0]  # read_optional gives (rows, errors) each

    ids = set(wanted_ids(args.programs, programs))
    known = {p["axp_id"] for p in programs}
    missing_ids = sorted(i for i in ids if i not in known)
    if missing_ids:
        say("no such program: %s" % ", ".join(missing_ids))
        return 2
    rows = {"programs": programs, "aliases": aliases, "virus": viruses, "approvals": approvals}
    refs = references(rows, ids)

    bad = {}
    n_ok = 0
    for axp in sorted(refs):
        ref = refs[axp]
        for url in sorted(ref["urls"]):
            ok, detail = check_url(url)
            say("%s %-10s %s  %s" % ("ok  " if ok else "FAIL", axp, url, detail))
            n_ok += ok
            if not ok:
                bad.setdefault(axp, []).append("%s (%s)" % (url, detail))
        for nct in sorted(ref["ncts"]):
            ok, detail = check_nct(nct)
            say("%s %-10s %s  %s" % ("ok  " if ok else "FAIL", axp, nct, detail))
            n_ok += ok
            if not ok:
                bad.setdefault(axp, []).append("%s (%s)" % (nct, detail))
        for pmid in sorted(ref["pmids"]):
            ok, detail = check_pmid(pmid)
            say("%s %-10s PMID %s  %s" % ("ok  " if ok else "FAIL", axp, pmid, detail))
            n_ok += ok
            if not ok:
                bad.setdefault(axp, []).append("PMID %s (%s)" % (pmid, detail))

    say("")
    throttled_only = {a for a, ps in bad.items() if all("429" in p for p in ps)}
    say("%d reference(s) reached, %d program(s) with a problem%s"
        % (n_ok, len(bad),
           " (%d of them only throttled, so not shown to be wrong)" % len(throttled_only)
           if throttled_only else ""))
    for axp in sorted(bad):
        say("  %s: %s" % (axp, "; ".join(bad[axp])))
    if throttled_only:
        say("  a throttled host is not a dead link: re-run and these usually pass")

    if not args.accept:
        return 1 if bad else 0

    clean = sorted(i for i in refs if i not in bad)
    changed = 0
    for row in aliases:
        if row["axp_id"] in clean and row["status"] == "proposed":
            row["status"] = "accepted"
            changed += 1
    if changed:
        os.makedirs(args.backup_dir, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
        path = os.path.join(args.registry, "aliases.tsv")
        shutil.copy2(path, os.path.join(args.backup_dir, "aliases.tsv.bak-" + stamp))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\t".join(reg.ALIAS_COLUMNS) + "\n")
            for row in aliases:
                fh.write("\t".join(row.get(c, "") for c in reg.ALIAS_COLUMNS) + "\n")
    say("accepted %d alias row(s) across %d program(s); backup in %s"
        % (changed, len(clean), args.backup_dir))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
