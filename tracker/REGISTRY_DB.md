# registry.sqlite: the derived database

Built by `tracker/build_registry.py` from `registry/*.tsv` and the trial
snapshot database, into `registry/registry.sqlite` under the state directory
(`$ABSTRACTINATOR_DATA_DIR`, `/var/lib/abstractinator` on bigtop; gitignored
`<repo>/data` when unset). It is rebuilt from scratch on every run and swapped in by an
atomic rename, so readers (the API) open it read-only and never see a
half-written file. Nothing in it is hand-edited: change the TSVs instead.

Readers must open it read-only (`file:...?mode=ro` URI in SQLite).

## Tables

### meta
| key | value |
|---|---|
| `schema_version` | `4` (2 added `virus` and `approval`; 3 added `trial.conditions`, papers and grants; 4 added `virus.host` and `virus.host_taxon`) |
| `built_at` | UTC ISO 8601 |
| `registry_release` | `YYYY-MM-DD+<first 12 hex of sha256 of programs.tsv + aliases.tsv>` |
| `latest_snapshot` | the newest snapshot date used, or empty |
| `previous_snapshot` | the one before it, or empty |

### program
Every row of `programs.tsv` (all statuses), same column names.
`entry_version` is an INTEGER; everything else TEXT ('' stays '').

### alias
Accepted aliases only, plus each active program's preferred name.

| column | |
|---|---|
| `axp_id` | |
| `alias` | |
| `alias_key` | `alias_key(alias)`, see SPEC section 5 |
| `alias_type` | as in aliases.tsv; `preferred` for the preferred name |
| `source`, `source_record`, `licence`, `evidence_url` | as in aliases.tsv |
| `ambiguous` | INTEGER 0/1 |

Index on `alias_key`.

### virus, approval
`virus.tsv` and `approvals.tsv` as they are (TEXT columns, '' for empty).
`virus` has one row per virus-based program (PRIMARY KEY `axp_id`);
`approval` any number per program.

### trial
The latest observation of every trial in the newest snapshot.

| column | |
|---|---|
| `nct_id` | PRIMARY KEY |
| `snapshot_date` | |
| `brief_title`, `overall_status`, `why_stopped`, `study_type`, `lead_sponsor` | TEXT |
| `phases` | TEXT, e.g. `PHASE1/PHASE2` ('' when none) |
| `start_date`, `primary_completion_date`, `completion_date` | TEXT (YYYY-MM or YYYY-MM-DD) |
| `enrollment_count` | INTEGER or NULL |
| `has_results` | INTEGER 0/1 |
| `last_update_post_date` | TEXT |
| `first_seen` | first snapshot date we saw this trial |
| `conditions` | JSON list of the conditions studied (for disease views, e.g. pancreatic cancer) |

### trial_link
Which trials are about which programs.

| column | |
|---|---|
| `nct_id`, `axp_id` | PRIMARY KEY together |
| `method` | `intervention_name` (an intervention's name or other name is the alias), `intervention_text` (alias found inside an intervention name), `title` (alias found only in the title) |
| `matched` | the alias text that matched |
| `confidence` | REAL: 0.95, 0.8, 0.6 for the three methods |
| `status` | `auto` (used for counts and change feeds) or `candidate` (shown, flagged for review) |

`auto` when an intervention is named by the alias; when an INN or brand
appears inside an intervention name or in the title; or when a code appears
inside an intervention name and the title names it too. Codes seen only in a
title, short names and ambiguous names stay `candidate`.

### paper, paper_link
Papers of every kind that name programs (clinical first on pages and in the
API: `kind` clinical_trial, case_report or clinical_other, or a
`trial_reference` link). `paper` (pmid PRIMARY KEY, title, journal,
year INTEGER, kind, doi, pmcid) holds metadata fetched by `tracker/evidence.py`
(absent until it has run: a link may have no `paper` row yet). `kind` is one
of `clinical_trial`, `case_report`, `clinical_other`, `review`, `other`.

`paper_link` (axp_id, pmid, method, matched, nct_id, confidence, status):

| method | confidence | status |
|---|---|---|
| `trial_reference`: a RESULT/DERIVED reference in an auto-linked trial's registration (`nct_id` says which) | 0.9 | auto |
| `title`: a program name in the paper's title | 0.85 | auto unless the name is ambiguous or under 4 characters |
| `abstract`: only in the abstract | 0.6 | auto for INNs, brands and development codes of 6 characters or more; candidate for shorter codes. An ambiguous name outside a title is not recorded at all |

### grant_award, grant_link
NIH grants about programs, from NIH RePORTER via `tracker/evidence.py`.
`grant_award` (core_project_num PRIMARY KEY, title, org, pi, first_fy, last_fy,
url); `grant_link` (axp_id, core_project_num, method `title`/`abstract`/`terms`,
matched, confidence, status), with the same rules as papers.

## evidence.sqlite (input, written by tracker/evidence.py on bigtop)

`evidence/evidence.sqlite` under the state directory, rebuilt weekly before
the registry build.
It stores search hits, not judgements: build_registry decides auto/candidate.
Abstracts are never stored (licensing): `field` records where the name was found.

| table | columns |
|---|---|
| `meta` | key, value (`schema_version` = `1`, `fetched_at`, `complete` = `1`/`0`) |
| `paper` | pmid PRIMARY KEY, title, journal, year INTEGER, kind, doi, pmcid |
| `paper_hit` | pmid, axp_id, matched (the alias text searched), field (`title`/`abstract`), PRIMARY KEY (pmid, axp_id) |
| `grant_award` | core_project_num PRIMARY KEY, title, org, pi, first_fy INTEGER, last_fy INTEGER, url |
| `grant_hit` | core_project_num, axp_id, matched, field (`title`/`abstract`/`terms`), PRIMARY KEY (core_project_num, axp_id) |

When a name matches in both title and abstract, `field` is `title`.

### change_event
What changed between the two newest snapshots (and kept from earlier runs:
events accumulate; a rebuild recomputes every consecutive pair).

| column | |
|---|---|
| `event_id` | `AXE-<snapshot_date>-<nct_id>-<type>` (stable across rebuilds) |
| `snapshot_date` | the snapshot where the change was seen |
| `previous_date` | the snapshot compared against |
| `nct_id` | |
| `type` | see below |
| `significance` | `major`, `minor` or `info` |
| `field`, `before`, `after` | TEXT (JSON for lists) |
| `axp_ids` | JSON list of linked programs (auto links), possibly `[]` |

Index on `snapshot_date`, and on `nct_id`.

Event types:

| type | significance | when |
|---|---|---|
| `trial.new` | minor | a trial appears for the first time and was first posted within 30 days before the previous snapshot (older trials that merely came into scope are not events) |
| `trial.status_changed` | major if to TERMINATED, WITHDRAWN, SUSPENDED, COMPLETED or ACTIVE_NOT_RECRUITING; else minor | overall_status differs |
| `trial.phase_changed` | major | phases differ |
| `trial.results_posted` | major | has_results false → true |
| `trial.enrollment_changed` | minor | count changes by ≥20%, or type ESTIMATED → ACTUAL |
| `trial.completion_slipped` | minor | primary completion date moves later by > 90 days |
| `trial.sponsor_changed` | minor | lead sponsor differs |
| `trial.intervention_added` | minor | an intervention name appears |
| `trial.dropped` | info | a trial matched last time and not this time, when both snapshots are complete |

## API contract (served by agent/api.R)

`GET /program?id=<AXP id or any name>` →
```json
{"registry_release": "...", "query": "TILT-123",
 "program": {"axp_id": "AXP000009", "preferred_name": "...", "status": "active", "modality": "...",
             "platform": "...", "targets": ["TNF","IL2"], "originator": "...", "sponsor": "...",
             "ncit": "...", "wikidata": "...", "unii": "...", "entry_version": 1, "notes": "..."},
 "virus": {"role": "oncolytic", "virus_family": "Adenoviridae", "virus": "human adenovirus 5", "ncbi_taxon": "28285",
           "host": "", "host_taxon": "",
           "strain": "Ad5/3 chimera", "replication": "conditionally_replicating", "modifications": "...",
           "transgenes": ["TNF", "IL2"], "route": ["intratumoral", "intravenous"], "carrier": "", "evidence_url": "..."},
 "approvals": [{"agency": "FDA", "region": "US", "date": "2015-10-27", "status": "approved", "brand": "Imlygic",
                "indication": "...", "evidence_url": "..."}],
 "aliases": [{"alias": "TILT-123", "alias_type": "code", "ambiguous": false, "source": "...", "evidence_url": "..."}],
 "trials": [{"nct_id": "...", "brief_title": "...", "overall_status": "...", "phases": "...", "start_date": "...",
             "primary_completion_date": "...", "enrollment_count": 20, "has_results": false,
             "lead_sponsor": "...", "link_method": "intervention_name", "link_confidence": 0.95, "link_status": "auto"}],
 "recent_changes": [ ...change_event rows for its auto-linked trials, newest first, max 50... ],
 "merged_from": null}
```
- `virus` is null for programs that aren't virus-based; `approvals` is `[]` when none.
- `virus.host` and `virus.host_taxon` name the organism the product is aimed at, which in
  practice means the target bacterium of a phage; they are empty for every other kind of
  row, whose host is the patient. A cocktail lists several, `; `-separated.
- `papers`: `[{pmid, title, journal, year, kind, link_method, link_confidence, link_status, nct_id}]`,
  auto links first, then clinical papers, then by year (newest first), max 200; `grants`: `[{core_project_num, title, org, pi,
  first_fy, last_fy, url, link_method, link_confidence, link_status}]`, newest first, max 100.
- A merged ID resolves to its survivor and says so in `merged_from`.
- A name matching several programs (ambiguous alias) returns 200 with
  `"program": null` and `"candidates": [{axp_id, preferred_name}]`.
- No match: 404 with `{"error": "...", "query": "..."}`.

`GET /changes?since=YYYY-MM-DD&program=<id or name>&modality=<category>&significance=major|minor|info&limit=100` →
`{"registry_release", "latest_snapshot", "since", "count", "events": [{event_id, snapshot_date, previous_date, nct_id, brief_title, type, significance, field, before, after, programs: [{axp_id, preferred_name}]}]}`
`since` defaults to 30 days ago. `significance=major` means major only;
`minor` means major and minor; `info` means all.
