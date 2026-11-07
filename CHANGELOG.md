# Changelog

Notable changes to The Abstractinator. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Development before v2.0.0 was untagged; see the git history for detail.

## [Unreleased]

### Added
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
