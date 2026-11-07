# Deduplication: which records count as the same work, which copy is kept,
# what is filled in from the others, and what is recorded about the merge.

rec <- function(Title, Source, DOI = NA_character_, Abstract = NA_character_,
                PublicationDate = "2024-03-01", ...) {
  data.frame(Title = Title, Source = Source, DOI = DOI, Abstract = Abstract,
             PublicationDate = PublicationDate, ..., stringsAsFactors = FALSE)
}
# deduplicate_data() prints a summary line; keep test output quiet.
dedup <- function(...) {
  df <- dplyr::bind_rows(...)
  res <- NULL
  invisible(capture.output(res <- deduplicate_data(df)))
  res
}

test_that("DOI spelling variants are one work", {
  out <- dedup(rec("Paper A", "EPMC", "10.1000/ABC"),
               rec("Paper A", "OpenAlex", "https://doi.org/10.1000/abc"),
               rec("Paper A", "CORE", "doi: 10.1000/abc"))
  expect_equal(nrow(out$deduplicated), 1)
  expect_equal(out$removed, 2)
  expect_equal(out$deduplicated$Source, "EPMC")
})

test_that("the most trusted copy is kept, with gaps filled from the others", {
  out <- dedup(rec("Paper B", "OpenAlex", "10.1000/b", Abstract = "Full abstract from OpenAlex."),
               rec("Paper B", "EPMC", "10.1000/b", PMCID = "PMC123"))
  d <- out$deduplicated
  expect_equal(d$Source, "EPMC")
  expect_equal(d$Abstract, "Full abstract from OpenAlex.")
  expect_equal(d$PMCID, "PMC123")
  expect_match(d$MergedFrom, "^OpenAlex: 10.1000/b$")
})

test_that("a preprint groups with its published version", {
  out <- dedup(rec("Preprint title", "Preprint (biorxiv)", "10.1101/2024.01.01.1",
                   Published_DOI_biorxiv = "10.1000/pub", PublicationDate = "2023-12-01"),
               rec("Published title", "EPMC", "10.1000/pub"))
  expect_equal(nrow(out$deduplicated), 1)
  expect_equal(out$deduplicated$Source, "EPMC")
  expect_match(out$deduplicated$MergedFrom, "Preprint \\(biorxiv\\)")
})

test_that("a copy without a DOI joins the DOI'd copy of the same title", {
  out <- dedup(rec("IL2 in vivo - a T cell review of cytokine therapy", "EPMC", "10.1000/c"),
               rec("IL-2 <i>in vivo</i>: a T-cell review of cytokine therapy.", "CORE"))
  expect_equal(nrow(out$deduplicated), 1)
  expect_equal(out$deduplicated$Source, "EPMC")
  expect_match(out$deduplicated$MergedFrom, "^CORE: ")
})

test_that("title matching is guarded: different DOIs, generic titles, distant years", {
  # Two DOIs are two works, even with the same title
  out <- dedup(rec("Same title for two different papers", "EPMC", "10.1000/d1"),
               rec("Same title for two different papers", "OpenAlex", "10.1000/d2"))
  expect_equal(nrow(out$deduplicated), 2)
  # Short generic titles never match
  out <- dedup(rec("Editorial", "CORE"), rec("Editorial", "OpenAlex"))
  expect_equal(nrow(out$deduplicated), 2)
  # Same long title, years far apart: different works
  out <- dedup(rec("Annual report on viral immunology research", "CORE", PublicationDate = "2015-01-01"),
               rec("Annual report on viral immunology research", "OpenAlex", PublicationDate = "2024-01-01"))
  expect_equal(nrow(out$deduplicated), 2)
  # Adjacent years (online first vs issue date) still match
  out <- dedup(rec("Interferon signalling in exhausted T cells", "CORE", PublicationDate = "2023-12-20"),
               rec("Interferon signalling in exhausted T cells", "OpenAlex", PublicationDate = "2024-01-05"))
  expect_equal(nrow(out$deduplicated), 1)
})

test_that("grants merge by funder project id, never by title", {
  out <- dedup(
    rec("Mechanisms of viral immunity", "NIH", GrantID = "R01AI000001", PublicationDate = "2022-07-01",
        Abstract = "Year 1 abstract."),
    rec("Mechanisms of viral immunity", "NIH", GrantID = "R01AI000001", PublicationDate = "2024-07-01",
        Abstract = "Year 3 abstract."),
    rec("Mechanisms of viral immunity", "NIH", GrantID = "R21AI999999", PublicationDate = "2024-07-01"),
    rec("Mechanisms of viral immunity", "NSF", GrantID = "2012345"))
  d <- out$deduplicated
  expect_equal(nrow(d), 3)
  r01 <- d[d$GrantID == "R01AI000001", ]
  expect_equal(nrow(r01), 1)
  expect_equal(r01$PublicationDate, "2024-07-01")   # the most recent year is kept
  expect_match(r01$MergedFrom, "^NIH: R01AI000001$")
})

test_that("records with nothing to merge are untouched and say so", {
  out <- dedup(rec("A lone paper about dendritic cells", "EPMC", "10.1000/e"))
  expect_equal(nrow(out$deduplicated), 1)
  expect_true(is.na(out$deduplicated$MergedFrom))
  expect_false(any(c("dup_group", "title_key", "DOI_clean") %in% names(out$deduplicated)))
})

test_that("an empty input returns an empty result", {
  out <- deduplicate_data(data.frame())
  expect_equal(nrow(out$deduplicated), 0)
  expect_equal(out$removed, 0)
})

test_that("title keys ignore case, markup, punctuation and spacing", {
  expect_equal(normalize_title_key(c("IL-2 <i>in vivo</i>: a T-cell review.", "IL2 in vivo - a T cell review")),
               c("il2invivoatcellreview", "il2invivoatcellreview"))
  expect_true(is.na(normalize_title_key(c("", NA))[1]))
})
