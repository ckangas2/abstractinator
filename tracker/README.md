# Tracker tools

Standard-library Python (3.8+) for the program registry and the trial change
log. Nothing to install.

| file | what it does |
|---|---|
| `registry.py` | alias keys and the registry validator (`validate`, `next-id`, `key`) |
| `snapshot_trials.py` | weekly ClinicalTrials.gov snapshot of the tracked topics |
| `snapshot_scope.tsv` | the queries that define "tracked topics" |
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

Changing `snapshot_scope.tsv` changes which trials are followed from the next
run on; trials that drop out of scope simply stop appearing.
