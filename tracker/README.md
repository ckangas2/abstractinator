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
writing to `data/trial_snapshots/` in the live copy (gitignored):

```
data/trial_snapshots/2026-11-15/trials.jsonl.gz   one record per trial
data/trial_snapshots/2026-11-15/manifest.json     counts per query, complete or not
data/trial_snapshots/raw/NCT01234567/<hash>.json.gz   a trial's record, when it changed
```

A trial record keeps status, why it stopped, phases, enrolment, start and
completion dates (with actual/estimated), lead sponsor and collaborators,
interventions with their other names, conditions, a fingerprint of the
primary outcomes, whether results are posted, countries and site count, and
cited PMIDs. `content_hash` covers all of these, so comparing hashes between
weeks finds the trials that changed. Contact names, emails and phone numbers
are never stored.

Snapshots are never overwritten or deleted by the script. Check the latest:

```
python3 tracker/snapshot_trials.py --status
```

Changing `snapshot_scope.tsv` changes which trials are followed from the next
run on; trials that drop out of scope simply stop appearing.
