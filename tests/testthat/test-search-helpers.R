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

test_that("dates with a time part become plain ISO dates", {
  expect_equal(normalize_date(c("2024-06-01T00:00:00", "2024-06-01T13:45:10Z", "2024-06-01",
                                "2024-06", "07/15/2023", NA)),
               c("2024-06-01", "2024-06-01", "2024-06-01", "2024-06", "07/15/2023", NA))
})

# --- Per-source counts, partial results and cache variants ------------------

test_that("per-source counts report retrieved, total and status", {
  ok      <- structure(data.frame(x = 1:3), total_hits = 1200)
  partial <- structure(data.frame(x = 1:2), total_hits = 40, source_failed = TRUE)
  failed  <- structure(data.frame(), source_failed = TRUE)
  vals <- list(EPMC = ok, OpenAlex = partial, NIH = failed,
               bioRxiv = data.frame(x = 1), Scopus = NULL)
  sc <- summarise_sources(vals)
  expect_equal(sc$source, c("EPMC", "OpenAlex", "NIH", "bioRxiv", "Scopus"))
  expect_equal(sc$retrieved, c(3L, 2L, 0L, 1L, 0L))
  expect_equal(sc$total, c(1200, 40, NA, NA, NA))
  expect_equal(sc$status, c("ok", "partial", "failed", "ok", "ok"))

  expect_equal(source_coverage_items(sc[1:4, ]),
               c("Europe PMC 3 of 1,200", "OpenAlex 2 of 40 (stopped early)",
                 "NIH RePORTER: no response", "bioRxiv/medRxiv 1"))
  expect_equal(incomplete_source_labels(sc), c("OpenAlex", "NIH RePORTER"))
  expect_equal(source_coverage_items(NULL), character(0))
})

test_that("cache entries are separated by MeSH mode and alias version", {
  plain <- get_cache_key("Oncolytic Virus")
  web   <- get_cache_key("Oncolytic Virus", variant = cache_variant(0L))
  api   <- get_cache_key("Oncolytic Virus", variant = cache_variant(60L))
  expect_false(identical(web, api))
  expect_false(identical(plain, web))
  expect_match(cache_variant(0L), "^mesh:cached\\|aliases:[0-9a-f]{10}$")
  expect_match(cache_variant(60L), "^mesh:live\\|aliases:")
})

test_that("a partial source result is shown but not cached; a clean one is cached with its counts", {
  withr::local_envvar(INTEGRATE_NIH_NSF = "")
  rec <- function(i) data.frame(
    Title = paste("Interferon signalling in CD8+ T cells, study", i),
    Abstract = "We studied influenza virus infection.",
    DOI = paste0("10.9999/test.", i), Authors = "A; B",
    PublicationDate = "2024-01-01", Source = "EPMC", stringsAsFactors = FALSE)
  epmc <- structure(rbind(rec(1), rec(2)), total_hits = 512)

  # Clean run: cached, with counts and retrieval time stored on the result.
  out <- suppressMessages(finish_extraction("zz test clean", list(EPMC = epmc), 50,
                                            NULL, NULL, NULL, mesh_lookups = 0L))
  expect_equal(nrow(out$deduplicated_data), 2)
  expect_equal(out$source_counts$total, 512)
  expect_true(inherits(out$metadata$retrieved_at, "POSIXct"))
  hit <- get_cached_extraction("zz test clean", 50, NULL, NULL, NULL, variant = cache_variant(0L))
  expect_false(is.null(hit))
  expect_equal(hit$source_counts$status, "ok")
  expect_equal(hit$metadata$retrieved_at, out$metadata$retrieved_at)

  # Same records, but the source stopped part-way: still returned, never cached.
  partial <- structure(epmc, source_failed = TRUE)
  out2 <- suppressMessages(finish_extraction("zz test partial", list(EPMC = partial), 50,
                                             NULL, NULL, NULL, mesh_lookups = 0L))
  expect_equal(nrow(out2$deduplicated_data), 2)
  expect_equal(out2$failed_sources, "EPMC")
  expect_equal(out2$source_counts$status, "partial")
  expect_null(get_cached_extraction("zz test partial", 50, NULL, NULL, NULL, variant = cache_variant(0L)))
})

test_that("the search report counts retrieved, kept and merged per database", {
  counts <- data.frame(source = c("EPMC", "OpenAlex", "bioRxiv", "NIH", "NSF"),
                       retrieved = c(50L, 0L, 50L, 50L, 1L),
                       total = c(21378, NA, NA, 1446, 1),
                       status = c("ok", "failed", "ok", "ok", "ok"), stringsAsFactors = FALSE)
  dedup <- data.frame(Source = c(rep("EPMC", 48), rep("Preprint (biorxiv)", 40),
                                 rep("Preprint (medrxiv)", 7), rep("NIH", 45), "NSF"))
  st <- dedup_source_stats(counts, dedup)
  expect_equal(st$Source, c("bioRxiv/medRxiv", "Europe PMC", "NIH RePORTER", "NSF", "OpenAlex"))
  row <- function(nm) st[st$Source == nm, ]
  expect_equal(c(row("Europe PMC")$Unique, row("Europe PMC")$Merged), c(48L, 2L))
  expect_equal(c(row("bioRxiv/medRxiv")$Unique, row("bioRxiv/medRxiv")$Merged), c(47L, 3L))
  expect_equal(row("OpenAlex")$Status, "No response")

  flow <- dedup_flow(st, nrow(dedup))
  expect_equal(flow$retrieved, 151L)
  expect_equal(flow$unique, 141L)
  expect_equal(flow$merged, 10L)
  expect_equal(flow$matched, 21378 + 1446 + 1)
  expect_false(flow$matched_complete)   # bioRxiv has no total and OpenAlex failed
  expect_equal(nrow(dedup_source_stats(NULL, dedup)), 0)
})

test_that("an OpenAlex key goes in a header, and no key means no header", {
  expect_null(openalex_auth(NULL))
  expect_null(openalex_auth(""))
  expect_null(openalex_auth(NA_character_))
  h <- openalex_auth(" abc123 ")
  expect_equal(unname(h$headers[["Authorization"]]), "Bearer abc123")
})
