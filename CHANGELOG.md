# Changelog

Notable changes to The Abstractinator. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Development before v2.0.0 was untagged; see the git history for detail.

## [Unreleased]

### Fixed
- The Therapinator summary table errored on every search: a bare
  `validate()` resolved to jsonlite's JSON validator instead of Shiny's. Now
  `shiny::validate`, with a test that no server code uses the bare name.
- The Therapinator was empty, and the Deduplicatinator's merge log and trial
  phases missing, on the website: results are trimmed to a fixed column list
  before display, and the new columns weren't on it. They are now, with a
  test that checks the list.
- Europe PMC records without a DOI or PMID linked to `.../PMC/NA`; they now
  link by the record's own Europe PMC id (found in live testing).
- A paper abbreviating its ad libitum group as "Ad" ("Ad + HF") was tagged
  adenovirus; a bare "Ad" no longer counts in text that says "ad libitum".
- Combination trials were tagged by their chemotherapy backbone (an
  oncolytic virus trial with lymphodepleting chemotherapy came out as
  "Chemotherapy"). Chemotherapy and radiotherapy are now the main therapy only
  when nothing else scores, and "lymphodepleting chemotherapy" doesn't count.
- A database that failed part-way (an error on a later page), or that returned
  an HTTP error instead of raising one (OpenAlex, NSF, ClinicalTrials.gov, the
  bioRxiv index), was treated as a complete answer and cached for 7 days. It is
  now marked partial or failed, shown to the visitor, and not cached.
- OpenAlex open-access and retraction flags were always empty: the fields were
  read but never requested.
- The website and the API shared cache entries even though they tag
  differently (the API may look up new MeSH descriptors). Cache entries are now
  keyed by MeSH mode and by a fingerprint of the alias lists, so an alias edit
  also invalidates stale tags automatically.
- A cached result reported the time of the visit as its retrieval time; it now
  keeps the time the databases were actually queried.
- Tagging false positives found in review: "ad hoc" / "ad libitum" as
  adenovirus, "Washington, DC" and "DC current" as dendritic cells, vector
  parts ("CMV promoter", "SV40 NLS", "RSV-LTR") as viruses, negated mentions
  ("HIV-negative adults"), all-caps titles ("HEARING AIDS" as HIV), and
  "German measles" as measles (now its own Rubella category). These phrases
  are blanked before counting; the short aliases themselves stay, since in
  this field "Ad" and "DC" are overwhelmingly adenovirus and dendritic cells.

- Deduplication gaps found in review: a record without a DOI was compared
  only with other DOI-less records, by exact title, so it never merged with a
  DOI'd copy of the same paper; different NIH projects with the same generic
  title were merged; and titles differing only in hyphens, spacing or markup
  didn't match. Records now group by DOI, grants by funder project id (never
  by title), and DOI-less records by a letters-and-digits title key with a
  compatible year. Covered by new offline tests (`test-dedup.R`).

### Changed
- MCP tools describe every argument in their input schema (Field
  descriptions), instead of only in the docstring, so agent clients see what
  each parameter does when choosing values.
- The Therapinator tab is hidden on the website while it is developed further
  (`SHOW_THERAPINATOR` in `app.R`); its code and tests stay, and the therapy
  tags remain in the API and MCP results.
- The PubTator3 benchmark now leads with tag support and adds 95% confidence
  intervals, a frozen held-out set of searches that name no organism (figures
  only, no examples, so it can't be tuned on), and negative controls reported
  on their own. Disease mentions match as whole words, so "hepatitis C" no
  longer counts as support for a hepatitis B tag.

### Added
- The program registry's first 32 entries: oncolytic viruses (T-VEC,
  teserpaturev, H101, pelareorep, DNX-2401, CG0070, LOAd703, VCN-01,
  TILT-123, RP1, Pexa-Vec, enadenotucirev), CAR-T therapies (the approved
  CD19 and BCMA products plus anito-cel) and KRAS-targeted agents, with 116
  names, NCIt codes, UNIIs and Wikidata items.
- Program registry groundwork (`registry/`, `tracker/`): a specification for
  stable program IDs (`AXP000001`...) and aliases, the empty registry files,
  and a validator that runs in CI. Released under CC0.
- Weekly ClinicalTrials.gov snapshots of oncolytic-virus, CAR-T and KRAS
  trials (`tracker/snapshot_trials.py`, Sundays via cron), keeping each
  trial's status, phase, enrolment, dates, interventions and sponsor so that
  changes can be detected later. Stored in one SQLite database where each
  version of a trial is kept once. Contact details are not stored.
- Trials keep their interventions' other names (development codes, brand
  names), lead sponsor, cited PMIDs and last-update date; API/MCP results
  gain `intervention_other_names`, `lead_sponsor` and `trial_references`.
  Other names also count when tagging a trial's therapy.
- `merged_from` in API/MCP results: the copies from other databases folded
  into each record.
- Optional free OpenAlex API key (`OPENALEX_API_KEY` in `.Renviron`), sent as
  a header: 10x the keyless daily allowance, and required for deep-search
  paging. OpenAlex 429s are retried twice briefly before the source is
  reported as failed.
- The Deduplicatinator is now a search report: the search as one flow line
  (matched in the databases -> retrieved -> duplicates merged -> unique
  works), a compact table per database (retrieved, matched, kept, merged,
  status, with trial phases on one line), and a log of merged records. It reads the per-source counts stored with each
  result, so a cached search reports the same numbers. Above the results,
  only a short warning remains, shown when a database didn't respond fully.
- **Therapinator** tab, "what's been tried": for the current results, a table
  of therapy x stage (grant, preprint, paper, trial phase 1 / 2 / 3+) with
  recruiting trials counted, and the trials themselves with their
  interventions, phase, status and conditions, most advanced first. Click a
  therapy to list its trials.
- A therapy-modality tag axis, `primary_modality` (oncolytic virus, CAR-T,
  other adoptive cell therapy, checkpoint inhibitor, cancer vaccine, vaccine,
  bispecific, antibody-drug conjugate, monoclonal antibody, cytokine,
  targeted small molecule, chemotherapy, radiotherapy, gene therapy (with
  viral-vector gene therapy, gene editing and RNA therapeutics split out),
  antiviral, antibiotic, microbiome). A trial's registered interventions
  count like its title.
- Clinical trials now carry `Interventions` and `Conditions` from the
  registry, in the API, MCP tool and exports.
- Provenance in reading-list exports: each item records the search that found
  it, when the databases were queried, and the copies merged into it (CSV
  columns and Markdown lines); the Markdown header gives the app version and
  a fingerprint of the tag vocabulary.
- `MergedFrom` on every deduplicated record: the source and id of each copy
  folded into it, so merges can be audited.
- Per-source coverage: how many records each database contributed out of how
  many it matched ("Europe PMC 50 of 12,431"), shown above the results and
  returned by the API (`sources`, `retrieved_at`). The Plotinator says its
  counts are within the retrieved records, not the whole literature.
- A caption under the title saying what the app is: "A search tool for
  biomedical literature".
- A **Look** choice in Settings -> Appearance: **Classic** (the default, as
  before: the mascot sets the colours) or **Gotham** (the season sets the
  colours and the mascot rides the moon), with a season picker (Auto by date,
  Everyday, Halloween, Thanksgiving, Christmas). Remembered in the visitor's
  browser.
- A "Welcome to Gotham" look for the home page, after the 1996 Batman
  Forever site: a glowing stencil title over a city reflected in water, a moon
  carrying the mascot's silhouette, and a neon skyline line over the feature
  cards. It changes with the calendar: Halloween (Oct 1 - Nov 1) adds
  jack-o'-lanterns and bats; Thanksgiving (Nov 2 - 30) turns amber with a
  harvest moon, hay, a rooftop turkey and falling leaves; Christmas (Dec 1 -
  Jan 1) adds snow, rooftop lights, a tree under the moon and a sleigh. The
  rest of the year shows the plain city. Preview any season with
  `?season=none|halloween|thanksgiving|christmas`. Lives in `www/gotham.css`,
  `www/gotham.js` and `app/partials/`; deleting the two `gotham` lines in
  `app/ui.R` switches it off.

## [2.1.0] - 2026-11-07

A day of review-driven fixes: tag matching, record format, concurrency, a
published PubTator3 benchmark, and a phone layout.

### Fixed
- NIH dates arrived as `2024-06-01T00:00:00`; dates are now plain ISO (#7).
- OpenAlex records never carried `pmid`, `pmcid` or `is_open_access`, and
  linked to their OpenAlex page rather than the paper. All three are filled
  and the link prefers the DOI (#25). Cache schema 11.
- Deduplication's source priority misspelled the trials source and left out
  OpenAlex, NIH and NSF. A published record now wins over its preprint.
- The help menu's citation said 2025, version 1.4.0 and an old URL; the
  footer said v2.0. Both now read one version setting (#12).
- The site on phones (#17): the search box is full width with the Search
  button below it, the "search complete" narwhals are phone-sized and flank the
  button instead of covering the page, the tabs are one swipeable row, the
  table toolbar sits under the tabs, results show as cards (title, authors,
  date, a six-line abstract), and the Plotinator's legend moves under the plot.
- Tags missed when a title carried markup ("CD8<sup>+</sup> T cells") or named
  the disease rather than the organism ("influenza", "tuberculosis",
  "COVID-19", "Lyme disease"). Markup is ignored when matching, and common
  disease names now tag their organism.
- `is_bioinformatics` matched generic words anywhere ("database",
  "annotation", "simulation"), flagging clinical studies. It now needs a
  specific computational phrase, matched as whole words.
- A MeSH lookup that failed on a network error was cached as "not an
  organism" for good. Failures are no longer cached, and are retried nightly.
- The website no longer waits on NLM: it reads MeSH from the local cache, and
  new descriptors are looked up by a nightly job (`deploy/warm_mesh.R --pending`).
- MeSH subjects replaced a correct regex tag with a vaguer or non-organism
  descriptor (Measles Virus became "Oncolytic Viruses", SARS-CoV-2 became
  "Betacoronavirus"). MeSH now replaces a tag only with one of our categories;
  an unlisted organism fills in only when the regex found nothing, and broad
  groupings ("Viruses", "Bacteria", "Oncolytic Viruses") are never used.
  "Herpes simplex virus type 2" is tagged HSV-2. Found by the PubTator3
  benchmark. Cached results are refreshed (cache schema 8).
- Tags for "CD8+ T cell" and "CD4+ T cell" never matched: the `+` in each
  alias was read as a regex operator. Aliases are now literal text.
- Short acronyms matched in any case, so Alzheimer's disease ("AD") was tagged
  as adenovirus ("Ad"). Acronyms with a capital letter now match only in that
  case, and ones common in other fields (RV, MV, LV, CV, VV, AV) are removed.
- A specific category now beats the general one it contains: "CD8+ T cells"
  no longer also counts toward "T cell", and herpes zoster is no longer
  tagged as herpes simplex.
- Europe PMC outages are reported in `unavailable_sources` and are not
  cached, instead of looking like zero results.
- Preprint search matched words inside other words ("NK" in "unknown"), which
  let unrelated preprints through. Terms must now start a word, and preprints
  are returned newest first instead of in storage order.
- Full text retries once more on transient Europe PMC errors (500, 502, 504),
  not only 429 and 503.

### Added
- `CITATION.cff`, for GitHub's "Cite this repository" button.
- `is_retracted` on search results, from Europe PMC publication types,
  OpenAlex, or a "Retracted:"/"Withdrawn" title. Cache schema 9.
- `pmid` on search results (PubMed ID, from Europe PMC), kept through
  deduplication. Cached results are refreshed (cache schema 7).
- `deploy/benchmark_pubtator.py`: compares the virus and bacterium tags with
  PubTator3's species annotations and writes `benchmark/pubtator.md`.
- Markdown export of the reading list, for notes apps, GitHub and AI chats:
  title, authors, date, source, DOI link, tags and the full abstract.
- Virus tags for the major human pathogens and immunology model viruses (HBV,
  HCV, CMV, EBV, VZV, KSHV, RSV, hMPV, HPV, MERS-CoV, SIV, LCMV, dengue, Zika,
  yellow fever, chikungunya, Ebola, mpox, enteroviruses) and immune cell tags
  for microglia, gamma delta T, NKT, MAIT, Tfh, Th17, pDC and MDSC. Cached
  results are refreshed (cache schema 5).

### Changed
- Settings button and menu restyled to match the app: a round frosted-glass
  button, and a menu with the search card's glass, pill tabs, a list of
  connected sources (now including NIH and NSF), and a teal Save pill.
- The loading screen's glow is denser, and sized to the smaller narwhal on
  phones, so the line art reads clearly.
- **API record format.** Clinical-trial titles are plain text (they were a
  Markdown link), `publication_date` is the trial's start date (it was a
  "Start: … | End: … | Status: …" label), and trials carry `trial_status`,
  `trial_start`, `trial_end` and `phase`. Every record now has every key, with
  `null` for missing values, and an empty result carries the paging fields.
  The website shows trials as before. Cache schema 10.
- `app.R` (2,600 lines) is split into `app/ui.R`, `app/dt_options.R` and
  seven `app/server/*.R` parts, moved verbatim. Unused code was removed. A
  test now checks that the server starts.
- The REST API runs as three processes, and the MCP server sends each request
  to the least busy one, so one slow search no longer blocks the others.
  Cache writes are atomic, since the processes share the cache.
- Spaces and hyphens in aliases are interchangeable ("T cell" = "T-cell").
- Records are normalised across sources: DOIs are bare (`10.…`, not
  `https://doi.org/10.…`), HTML entities in titles and abstracts are decoded,
  and authors are always separated by `; `. Cached results are refreshed
  (cache schema 6).
- API errors no longer include internal details; they are logged instead.
- Retired code moved to `archive/`; line endings normalised to LF.

## [2.0.0] - 2026-10-21

First tagged release. Searches Europe PMC, OpenAlex, ClinicalTrials.gov,
bioRxiv/medRxiv, NIH RePORTER and NSF Awards in parallel, deduplicates across
them, and tags each record by immune cell type, virus and bacterium. Available
as a Shiny web app and as a remote MCP server with two tools
(`search_literature`, `get_fulltext`).

### Added
- `sources=` on search, restricting results to groups (`papers`, `grants`,
  `preprints`, `trials`) or named sources. Filters the result set rather than
  the dispatch, so one cache entry per query serves every combination.
- `offset=` paging, with `available` and `has_more` in the response.
  `total_found` is the whole deduplicated pool; `available` is what is
  pageable after a `sources=` filter.
- Organism tagging from MeSH. Europe PMC returns descriptors assigned by human
  indexers with a major-topic flag; these are now captured and classified by
  MeSH tree position (B03 bacteria, B04 virus, A11+A15 immune cell) rather
  than by a hand-maintained alias list. Lookups are cached on disk and bounded
  per search. `deploy/warm_mesh.R` pre-populates the cache;
  `deploy/propose_aliases.R` reports coverage gaps ranked by occurrence.
- Six virus and two immune cell categories, chosen by frequency in the corpus:
  Norovirus, SARS-CoV-2, Rotavirus, Bacteriophage, Influenza, Sapovirus,
  Tumor-infiltrating lymphocyte, PBMC.
- `get_fulltext` for open-access articles, with its own rate limit and cache.
- Cache keys carry a schema version, so a change to the result shape
  invalidates stale entries instead of serving records missing new fields.
- Invisible and bidirectional control characters are stripped from
  agent-facing text, and tool descriptions and `llms.txt` state that records
  are untrusted third-party data rather than instructions.

### Changed
- NSF Awards: query terms are now joined with `AND`. research.gov's keyword
  parameter defaults to OR and sorts by date, so a multi-word query returned
  the newest awards matching any single word.
- Organism tagging scores by occurrence count rather than presence. A term
  mentioned once in an abstract no longer outranks the record's actual
  subject, and must appear in the title or at least twice in the abstract to
  be called primary. Terms below that still appear in `*_hits_combined`.
- ClinicalTrials.gov records carry a trial phase, summarised in the
  Deduplicatinator.

### Fixed
- `/fulltext` returned "could not find function strip_invisible": the function
  was defined inside the plumber file while its caller lived in the global
  environment.
- Deduplication dropped trailing punctuation from titles only when followed by
  a space, so near-duplicate titles were not matched. Abstracts, PMCIDs and
  open-access flags are now cross-filled between duplicate records before a
  winner is chosen.
- Hidden result-table columns and the default sort were silently discarded by
  `modifyList`, which recurses into unnamed lists.
