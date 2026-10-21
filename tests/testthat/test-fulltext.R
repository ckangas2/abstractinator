# Guards the /fulltext path, which shipped once without a test and broke:
# strip_invisible() was defined inside the plumber file while its caller lived
# in the global environment, so every call failed with "could not find
# function". These tests need no network.

source(file.path("..", "..", "fulltext_extraction.R"))

test_that("strip_invisible is reachable from this file alone", {
  # The regression guard: fetch_epmc_fulltext() calls it, and sourcing only
  # this file must be enough for that call to resolve.
  expect_true(exists("strip_invisible"))
  expect_true(is.function(strip_invisible))
})

test_that("strip_invisible removes invisible characters and nothing else", {
  probe <- paste0("Listeria", "\u200b", " monocytogenes", "\u202e", "evil")
  out <- strip_invisible(probe)
  expect_false(grepl("\u200b", out, fixed = TRUE))
  expect_false(grepl("\u202e", out, fixed = TRUE))
  expect_equal(out, "Listeria monocytogenesevil")
  expect_true(is.na(strip_invisible(NA_character_)))
  expect_equal(strip_invisible("plain <i>text</i>"), "plain <i>text</i>")
  expect_equal(strip_invisible(42), 42)
})

test_that("a malformed pmcid is rejected before any request", {
  r <- fetch_epmc_fulltext("../../etc/passwd", use_cache = FALSE)
  expect_equal(r$status, "failed")
  expect_match(r$error, "PMC")

  r2 <- fetch_epmc_fulltext("not-a-pmcid", use_cache = FALSE)
  expect_equal(r2$status, "failed")
})

test_that("truncation honours the floor and reports its own length", {
  rec <- list(pmcid = "PMC1", status = "success",
              full_text = paste(rep("x", 5000), collapse = ""))

  # NOTE: the 500 floor is applied in fetch_epmc_fulltext(), not here, so
  # .ft_finish() honours whatever it is handed. What must always hold is that
  # the reported char count equals the string actually returned.
  short <- .ft_finish(rec, 100L, from_cache = TRUE)
  expect_true(short$truncated)
  expect_equal(short$chars, nchar(short$full_text))
  expect_equal(short$chars, 100L + nchar("\n\n[truncated]"))

  big <- .ft_finish(rec, 1000L, from_cache = TRUE)
  expect_equal(big$chars, nchar(big$full_text))
  expect_gt(big$chars, short$chars)

  whole <- .ft_finish(rec, 100000L, from_cache = TRUE)
  expect_false(whole$truncated)
  expect_equal(whole$chars, 5000L)
})
