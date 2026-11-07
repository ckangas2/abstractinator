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
  # The signature format is pinned, but the schema version is read from the
  # constant rather than frozen: a deliberate bump must be allowed (it is how
  # a result-shape change invalidates stale entries), while an accidental
  # change to the signature itself still fails here.
  expected <- paste0(digest::digest(paste0(
    "oncolytic virus|elsevier:FALSE|uspto:FALSE|core:FALSE|schema:",
    CACHE_SCHEMA_VERSION), algo = "md5"), ".rds")
  expect_identical(std, expected)

  # Bumping the version must change the key -- that is the whole mechanism.
  withr::defer(assign("CACHE_SCHEMA_VERSION", CACHE_SCHEMA_VERSION, envir = globalenv()))
  assign("CACHE_SCHEMA_VERSION", CACHE_SCHEMA_VERSION + 1L, envir = globalenv())
  expect_false(identical(std, get_cache_key("Oncolytic Virus")))
})

test_that("BYOK flags give a search its own cache entry", {
  # A visitor supplying their own key gets extra sources, so the result shape
  # differs and must not share a cache entry with the keyless search.
  plain <- get_cache_key("Oncolytic Virus")
  expect_false(identical(plain, get_cache_key("Oncolytic Virus", has_core = TRUE)))
  expect_false(identical(plain, get_cache_key("Oncolytic Virus", has_uspto = TRUE)))
  expect_false(identical(plain, get_cache_key("Oncolytic Virus", has_elsevier = TRUE)))
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

# --- One record format across sources (normalize_records) -------------------

test_that("HTML entities in titles and abstracts are decoded once", {
  expect_equal(decode_html_entities("IL&lt;sup&gt;2&lt;/sup&gt; &amp; TGF-&#946; / &#x3B2;"),
               "IL<sup>2</sup> & TGF-β / β")
  # a double-encoded entity becomes the literal text it stood for
  expect_equal(decode_html_entities("p &amp;lt; 0.05"), "p &lt; 0.05")
  expect_equal(decode_html_entities(c("A & B", NA, "&bogus;")), c("A & B", NA, "&bogus;"))
})

test_that("DOIs are bare, whatever the source sent", {
  expect_equal(normalize_doi(c("https://doi.org/10.1/ABC", "http://dx.doi.org/10.1/x",
                               "doi: 10.1/y", " 10.1/z ", "", NA)),
               c("10.1/ABC", "10.1/x", "10.1/y", "10.1/z", NA, NA))
})

test_that("authors are separated by '; '", {
  expect_equal(normalize_authors(c("A;B", "A ;  B;", "A; B", "", NA)),
               c("A; B", "A; B", "A; B", NA, NA))
})

test_that("preprint search terms must start a word", {
  nk <- biorxiv_term_pattern("NK")
  expect_true(grepl(nk, "Exhausted NK cells", ignore.case = TRUE, perl = TRUE))
  expect_true(grepl(nk, "NKG2D ligands", ignore.case = TRUE, perl = TRUE))
  expect_false(grepl(nk, "an unknown link", ignore.case = TRUE, perl = TRUE))
  cd8 <- biorxiv_term_pattern("CD8+")
  expect_true(grepl(cd8, "CD8+ T cells", perl = TRUE))
  expect_false(grepl(cd8, "CD88 expression", perl = TRUE))
})
