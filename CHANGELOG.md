# Changelog

Notable changes to The Abstractinator. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Development before v2.0.0 was untagged; see the git history for detail.

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
