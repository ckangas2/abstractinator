# helper-setup.R -- loaded automatically by testthat before the test files.
# Loads the parts of The Abstractinator the tests exercise, without starting
# the Shiny app. Run all tests from the repo root with:
#   Rscript -e 'testthat::test_dir("tests/testthat")'

repo_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))

suppressPackageStartupMessages({
  for (f in c("R/display_utils.R", "R/db_utils_local.R",
              "orchestrate_extraction.R", "biorxiv_extraction.R")) {
    source(file.path(repo_root, f))
  }
})

# Keep test runs from writing into the real cache
assign("CACHE_DIR", file.path(tempdir(), "abstractinator-test-cache"), envir = globalenv())
dir.create(get("CACHE_DIR", envir = globalenv()), recursive = TRUE, showWarnings = FALSE)
