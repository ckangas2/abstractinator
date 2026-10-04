# Search plumbing: query parsing, cache keys, the per-source safety net,
# and grant record transforms.

test_that("bioRxiv queries split into terms that must all match", {
  expect_equal(biorxiv_query_terms("IL-2 (CD25)"), c("IL-2", "CD25"))
  expect_equal(biorxiv_query_terms('"oncolytic virus" melanoma'), c("oncolytic virus", "melanoma"))
  expect_equal(biorxiv_query_terms("T-VEC"), "T-VEC")
  expect_equal(biorxiv_query_terms("CAR-T AND (lymphoma OR leukemia)"), c("CAR-T", "lymphoma", "leukemia"))
})

test_that("cache keys separate standard and deep searches", {
  std  <- get_cache_key("Oncolytic Virus")
  deep <- get_cache_key("Oncolytic Virus", limit = 250)
  expect_false(identical(std, deep))
  # case and surrounding spaces don't matter
  expect_identical(std, get_cache_key("  oncolytic virus "))
  # standard searches keep the original signature, so old cache files stay valid
  legacy <- paste0(digest::digest("oncolytic virus|elsevier:FALSE|uspto:FALSE|core:FALSE", algo = "md5"), ".rds")
  expect_identical(std, legacy)
})

test_that("safe_source turns a crash into a marked, empty result", {
  res <- suppressMessages(safe_source("Test", stop("boom")))
  expect_true(source_failed(res))
  expect_equal(nrow(res), 0)
  expect_message(safe_source("Test", stop("boom")), "\\[Test\\] FAILED: boom")
})

test_that("safe_source passes successful results through untouched", {
  df <- data.frame(Title = "ok")
  expect_identical(safe_source("Test", df), df)
  expect_false(source_failed(df))
})

test_that("NIH and NSF records get links", {
  nih <- transform_nih_to_schema(data.frame(project_title = "Grant", appl_id = "1234567"))
  expect_equal(nih$URL, "https://reporter.nih.gov/project-details/1234567")
  nsf <- transform_nsf_to_schema(data.frame(title = "Award", id = "2012345"))
  expect_equal(nsf$URL, "https://www.nsf.gov/awardsearch/showAward?AWD_ID=2012345")
})

test_that("empty or failed grant sources merge to zero rows without error", {
  failed <- structure(data.frame(), source_failed = TRUE)
  merged <- merge_nih_nsf_to_schema(failed, NULL)
  expect_equal(nrow(merged), 0)
  expect_true(all(c("Title", "URL", "Source") %in% names(merged)))
})
