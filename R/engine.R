# R/engine.R
# The files that make up the search engine, in load order. The Shiny app, the
# REST API and the tests all load the engine through load_engine(), so adding
# a source means adding it here once.

ENGINE_FILES <- c(
  # one extractor per database
  "epmc_standalone_extraction.R", "openalex_standalone_extraction.R",
  "CORE_extraction.R", "clinicaltrials.gov_extraction.R", "biorxiv_extraction.R",
  "patentsview_extraction.R", "scopus_extraction.R", "scopus_abstract_extraction.R",
  "NIHReporter_extraction.R", "NSFAwards_extraction.R",
  # cache, logging, full text
  "R/db_utils_local.R", "R/log_utils_local.R", "fulltext_extraction.R",
  # dedup, tagging vocabulary, and the orchestrator that ties it together
  "deduplication.R", "aliases.R", "orchestrate_extraction.R"
)

load_engine <- function(root = ".") {
  for (f in ENGINE_FILES) source(file.path(root, f))
  invisible(ENGINE_FILES)
}
