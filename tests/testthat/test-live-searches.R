# Live end-to-end searches against the real databases: the five edge cases
# that each exposed a bug on 4 October 2026. These need internet access and
# take a minute, so they only run when asked:
#   ABSTRACTINATOR_LIVE_TESTS=1 Rscript -e 'testthat::test_dir("tests/testthat")'

skip_if_not(Sys.getenv("ABSTRACTINATOR_LIVE_TESTS") == "1",
            "Live tests skipped (set ABSTRACTINATOR_LIVE_TESTS=1 to run)")

withr::local_dir(repo_root)  # extractors use paths relative to the repo root
suppressPackageStartupMessages({
  for (f in c("epmc_standalone_extraction.R", "CORE_extraction.R",
              "clinicaltrials.gov_extraction.R", "scopus_extraction.R",
              "patentsview_extraction.R", "deduplication.R",
              "scopus_abstract_extraction.R", "openalex_standalone_extraction.R",
              "aliases.R", "NIHReporter_extraction.R", "NSFAwards_extraction.R",
              "orchestrate_extraction.R")) {
    source(f)
  }
})
assign("CACHE_DIR", file.path(tempdir(), "abstractinator-live-cache"), envir = globalenv())
dir.create(get("CACHE_DIR", envir = globalenv()), recursive = TRUE, showWarnings = FALSE)
withr::local_envvar(INTEGRATE_NIH_NSF = "1")
future::plan(future::sequential)

run_search <- function(term, limit = 50) {
  msgs <- character(0)
  res <- withCallingHandlers(
    suppressWarnings(utils::capture.output(
      out <- orchestrate_data_extraction_cached(term, limit = limit)
    )),
    message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") }
  )
  list(result = out, failed = grep("FAILED", msgs, value = TRUE))
}

test_that("nonsense terms return no results, without errors", {
  s <- run_search("zxqvbnm floopwhistle")
  expect_null(s$result$deduplicated_data)
  expect_length(s$failed, 0)
})

test_that("a trial ID finds that trial", {
  s <- run_search("NCT02779855")
  expect_length(s$failed, 0)
  expect_true("NCT02779855" %in% s$result$deduplicated_data$NCTId)
})

test_that("punctuation-heavy queries work in every source", {
  s <- run_search('IL-2 & "regulatory T cells" (CD25+)')
  expect_length(s$failed, 0)
  expect_gt(nrow(s$result$deduplicated_data), 0)
})

test_that("non-English characters survive the round trip", {
  s <- run_search("\u03b2-catenin interf\u00e9ron")
  expect_length(s$failed, 0)
  titles <- s$result$deduplicated_data$Title
  expect_gt(length(titles), 0)
  expect_true(all(validUTF8(titles[!is.na(titles)])))
})

test_that("a deep search on a broad topic returns a large result set", {
  s <- run_search("COVID-19", limit = 250)
  expect_length(s$failed, 0)
  expect_gt(nrow(s$result$deduplicated_data), 500)
})
