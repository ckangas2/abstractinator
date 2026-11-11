# Tracker tools

Standard-library Python (3.8+) for the program registry and the trial change
log. Nothing to install.

| file | what it does |
|---|---|
| `registry.py` | alias keys and the registry validator (`validate`, `next-id`, `key`) |
| `snapshot_trials.py` | weekly ClinicalTrials.gov snapshot of the tracked topics |
| `snapshot_scope.tsv` | the queries that define "tracked topics" |
| `evidence.py` | weekly search of PubMed and NIH RePORTER for the papers and grants that name each program |
| `build_registry.py` | builds `registry.sqlite` under the state directory (programs, names, trial links, what changed) and the `www/changes.html` digest; layout in `REGISTRY_DB.md` |
| `site_pages.py` | writes the registry's web pages (`www/registry/`) from that database |
| `refcheck.py` | visits the links, NCT numbers and PMIDs a program cites; `--accept` promotes a program's proposed aliases once they all resolve |
| `tests/` | `python3 -m unittest discover -s tracker/tests` (no network) |

## Where the files live

The registry TSVs and the web pages (`www/changes.html`, `www/registry/`) are
part of the checkout. **State** is not: the snapshot, evidence and built
databases live under `$ABSTRACTINATOR_DATA_DIR` (`/var/lib/abstractinator` on
bigtop, set in the cron file), falling back to `<repo>/data` when that isn't
set, so a `git clean` or a re-clone can't delete it. `reg.data_dir()` is the
one place that decides this; logs go to `/var/log/abstractinator`.

The snapshot database is the only state that can't be rebuilt, since
ClinicalTrials.gov serves today's record and not last week's.
`deploy/keep_snapshots.sh` runs right after each snapshot and keeps the
newest 8 weekly copies, gzipped, in `$ABSTRACTINATOR_DATA_DIR/backups`.

## Trial snapshots

Runs every Sunday night from `deploy/abstractinator.cron` as the `shiny` user,
writing to one SQLite database outside the checkout (see above):
`$ABSTRACTINATOR_DATA_DIR/trial_snapshots/trials.sqlite`.

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

## Papers and grants (evidence)

`evidence.py` runs in the same Sunday cron line, after the snapshot and
before the registry build, and writes `evidence/evidence.sqlite` under the state directory
(gitignored; tables in `REGISTRY_DB.md`). For every active program's
preferred name and accepted aliases (except names whose alias key is under 4
characters), it searches:

- **papers** in [PubMed](https://www.ncbi.nlm.nih.gov/books/NBK25501/)
  (E-utilities: `esearch` for the PMIDs, up to 9,999 per search, then
  `efetch` XML in batches of 200, both as POST): records of every type whose
  title or abstract has the name, 20 names per query: `("a"[tiab] OR ...)`;
  a search with more than 9,999 hits is split in half until it fits. Each
  paper's `kind` comes from its publication types, so pages can show
  clinical papers first. `--clinical-only` restricts the search to clinical
  publication types: `... AND ("Clinical Trial"[pt] OR ... OR "Case Reports"[pt] ...)`.
  `--papers-from europepmc` uses the
  [Europe PMC REST API](https://europepmc.org/RestfulWebService) instead
  (`resultType=core`, 1000 per page, cursorMark paging), with the same
  names and types:
  `(TITLE:"a" OR ABSTRACT:"a" OR ...) AND SRC:MED AND (PUB_TYPE:"Clinical Trial" OR
  PUB_TYPE:"Clinical Trial, Phase I" ... OR PUB_TYPE:"Case Reports" OR
  PUB_TYPE:"Randomized Controlled Trial" OR PUB_TYPE:"Clinical Study" OR
  PUB_TYPE:"Observational Study")`. `kind` comes from the publication types:
  `clinical_trial`, `case_report`, `review`, `clinical_other`, `other`.
- **NIH grants** in the [RePORTER API v2](https://api.reporter.nih.gov/)
  (`projects/search`, `advanced_text_search` with operator `or` over
  `projecttitle,terms,abstracttext`, 25 quoted names per search, 500 per
  page, at most one request a second as NIH asks). Fiscal-year records are
  grouped by core project number: first and last fiscal year, and the latest
  year's title, organisation and contact PI. A search with more hits than
  RePORTER pages through (offset 14,999) is split in half until it fits.

A hit counts as `auto` when the name is an INN or brand, or a development
code of at least 6 characters, wherever it was found; a shorter code needs
the title. An ambiguous name counts only in a title: elsewhere it is dropped
rather than queued for review, because a generic synonym ("TK cells") matches
every paper about that kind of product, not about this one.

Each record that comes back is checked here with the same word matching
as trial titles (`window_keys`), never trusting the search engine's own
matching; `field` says where the name was (`title` beats `abstract` beats
`terms`). Two guards: a name with a key of 5 characters or fewer must be
written as itself (joined or hyphenated in any case, or spaced in the same
case: "ON-01", "T-Vec", but not "on 01 January"); and an ambiguous name never
counts in RePORTER's project terms, which are thesaurus tags with synonyms
(every West Nile virus grant is tagged "Egypt 101 virus"). It stores hits, not judgements: `build_registry.py` decides which
are `auto` and which `candidate`.

What is stored: titles, journal, year, publication kind and identifiers
(PMID, DOI, PMCID) of papers; titles, organisation, PI name, fiscal years and
the RePORTER link of grants. PubMed's and Europe PMC's metadata and NIH RePORTER's data
are public and may be reused this way; abstracts are read to find names but
never stored, since their copyright stays with publishers and authors.

Time limits: each request must finish within 90 seconds in total (a slow
trickle counts as a failure and is retried), and the whole run within 45
minutes (`--budget-minutes`). Progress lines are flushed as they happen.

Failures: if any request fails after retries (backoff on 429 and 5xx), or the
time budget runs out, nothing is written and last week's file stays for the build (exit 1). If a
search had more records than can be paged, the file is written with
`complete = 0` (exit 3). Check: `python3 tracker/evidence.py --status`
(exit 1 when older than 8 days or incomplete; the uptime probe runs it). Try
the APIs without writing anything: `python3 tracker/evidence.py --dry-run`.

## Registry database and digest

`build_registry.py` runs right after each snapshot (same cron line) and can be
run by hand any time. It rebuilds `registry/registry.sqlite` (under the state
directory) from scratch:

- **trial links**: a trial links to a program when one of the program's names
  is an intervention's name or other name (`auto`, confidence 0.95), appears
  inside an intervention name (0.8; `auto` for INNs and brands, and for codes
  the title also names), or appears only in the title (0.6; `auto` for INNs
  and brands, `candidate` for codes). Ambiguous names only ever give
  candidates. To review them, export them into your
  reports folder: `python3 tracker/build_registry.py --export-review
  ~/abstractinator-reports/link_review-$(date +%F).tsv` (one file, with the
  candidate papers and grants too; the `kind` column says which). Accepted
  fixes go into the registry (a missing name, or `ambiguous = 1`).
- **change events** between each pair of consecutive snapshots: status,
  phase, results posted, enrolment (±20% or estimated → actual), primary
  completion slipping by more than 90 days, sponsor, intervention added, new
  trials and dropped trials (only when both snapshots were complete).
- **digest**: `www/changes.html` (abstractinator.me/changes.html): the week's
  major changes by program, minor changes counted, and the tracked programs.

- **paper and grant links**: results papers cited by a linked trial's
  registration (`auto`), and the hits from `evidence.py` (see above).

The API serves the database read-only: `/program` (with its `papers` and
`grants`) and `/changes`, and the MCP tools of the same names.

## Registry web pages

`site_pages.py` (called by `build_registry.py` after the digest; `--site DIR`,
`""` to skip) writes static HTML into `www/registry/` (gitignored), which
Shiny serves at abstractinator.me/registry/index.html. Linked from the
settings menu and from `changes.html`.

- `index.html`: what the registry is, counts, a filter box, and every active
  program: therapeutic viruses by virus family and role, then the rest by
  modality, with key names, strain and replication, highest phase among
  confirmed trials, approvals and trial count.
- `AXP000001.html`, one per ID: names (ambiguous ones flagged), virus,
  NCIt/Wikidata/UNII links, approvals, trials (unconfirmed matches folded
  away), recent changes, papers and NIH grants (once `evidence.py` has run),
  notes, how to cite (release + versioned ID) and a "suggest a correction"
  issue link. Merged and retired IDs get a short page pointing to the
  survivor, so an ID that was ever valid never 404s.
- `disease/<slug>.html`: programs with a confirmed trial whose conditions or
  title mention the disease, grouped like the index. The views are the
  `DISEASE_VIEWS` table at the top of `site_pages.py` (pancreatic cancer for
  now: `("pancreatic-cancer", "Pancreatic cancer", ["pancrea"])`); add a row
  for another.

Links are relative, so the pages work under any prefix. The site is written
into `www/registry.tmp` and swapped in whole, so it is never half-written.
By hand: `python3 tracker/site_pages.py [--db FILE] [--out DIR]`.
