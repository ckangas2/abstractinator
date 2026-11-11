# Tracker tools

Standard-library Python (3.8+) for the program registry and the trial change
log. Nothing to install.

| file | what it does |
|---|---|
| `registry.py` | alias keys and the registry validator (`validate`, `next-id`, `key`) |
| `snapshot_trials.py` | weekly ClinicalTrials.gov snapshot of the tracked topics |
| `snapshot_scope.tsv` | the queries that define "tracked topics" |
| `build_registry.py` | builds `data/registry/registry.sqlite` (programs, names, trial links, what changed) and the `www/changes.html` digest; layout in `REGISTRY_DB.md` |
| `tests/` | `python3 -m unittest discover -s tracker/tests` (no network) |

## Trial snapshots

Runs every Sunday night from `deploy/abstractinator.cron` as the `shiny` user,
writing to one SQLite database in the live copy (gitignored):
`data/trial_snapshots/trials.sqlite`.

| table | one row per | holds |
|---|---|---|
| `snapshot` | weekly run | date, timings, complete or not, per-query counts (`manifest`, JSON) |
| `trial_version` | distinct version of a trial | the tracked fields (`record`, JSON) and the API record (`raw`, zlib-compressed JSON) |
| `observation` | trial per run | which version (`content_hash`) was seen that week, plus its last-update date |

A version is stored once, however many weeks it stays the same, so a quiet
week costs a row per trial and nothing else. Trials that changed between two
weeks: `CHANGES_SQL` in `snapshot_trials.py`.

A trial record keeps status, why it stopped, phases, enrolment, start and
completion dates (with actual/estimated), lead sponsor and collaborators,
interventions with their other names, conditions, a fingerprint of the
primary outcomes, whether results are posted, countries and site count, and
cited PMIDs. Contact names, emails and phone numbers are never stored.

Reading it: `sqlite3 trials.sqlite`, Python's `sqlite3`, R's `RSQLite`, or
DuckDB (`ATTACH 'trials.sqlite' (TYPE sqlite)`). `raw` is zlib-compressed;
in Python, `json.loads(zlib.decompress(raw))`.

Each run is one transaction, so a snapshot is either complete in the database
or absent, and rows are only ever added. Check the latest:

```
python3 tracker/snapshot_trials.py --status
```

What is followed: the keyword queries in `snapshot_scope.tsv`, plus an
intervention search for every name in the program registry (in batches of
15), so each registered program's trials are followed even when they never
use the topic's keywords. Adding a program or a name to the registry widens
the next snapshot automatically. Trials that come into scope this way are not
reported as "new" unless they were registered within the last 30 days.

## Registry database and digest

`build_registry.py` runs right after each snapshot (same cron line) and can be
run by hand any time. It rebuilds `data/registry/registry.sqlite` from scratch:

- **trial links**: a trial links to a program when one of the program's names
  is an intervention's name or other name (`auto`, confidence 0.95), appears
  inside an intervention name (0.8; `auto` for INNs and brands, and for codes
  the title also names), or appears only in the title (0.6; `auto` for INNs
  and brands, `candidate` for codes). Ambiguous names only ever give
  candidates. To review them, export them into your
  reports folder: `python3 tracker/build_registry.py --export-review
  ~/abstractinator-reports/link_review-$(date +%F).tsv`. Accepted fixes go
  into the registry (a missing name, or `ambiguous = 1`).
- **change events** between each pair of consecutive snapshots: status,
  phase, results posted, enrolment (±20% or estimated → actual), primary
  completion slipping by more than 90 days, sponsor, intervention added, new
  trials and dropped trials (only when both snapshots were complete).
- **digest**: `www/changes.html` (abstractinator.me/changes.html): the week's
  major changes by program, minor changes counted, and the tracked programs.

The API serves the database read-only: `/program` and `/changes`, and the MCP
tools of the same names.
