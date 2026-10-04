# Category tagging: alias lists become whole-word patterns, and records are
# labelled with the category they match most strongly (title beats abstract).

test_that("alias lists become whole-word, case-insensitive patterns", {
  rx <- aliases_to_regex(list(Salmonella = c("salmonella", "VNP20009")))
  expect_true(grepl(rx$Salmonella, "attenuated salmonella strain", perl = TRUE))
  expect_true(grepl(rx$Salmonella, "treated with vnp20009", perl = TRUE))
  # not a match inside a longer word
  expect_false(grepl(rx$Salmonella, "salmonellosis outbreak", perl = TRUE))
})

test_that("multi-word aliases tolerate extra whitespace", {
  rx <- aliases_to_regex(list(`E. coli` = "escherichia coli"))
  expect_true(grepl(rx$`E. coli`, "escherichia  coli nissle", perl = TRUE))
})

test_that("records are tagged with the strongest match", {
  df <- data.frame(
    Title = c("Salmonella therapy for colorectal cancer",
              "A study of tumour perfusion",
              "Listeria vaccine platform"),
    Abstract = c("We also mention Listeria once.",
                 "No organisms here.",
                 "Listeria monocytogenes was used throughout."),
    stringsAsFactors = FALSE
  )
  out <- tag_with_alias_list(df, bacteria_alias_expanded, "bacteria")

  # Title hit outweighs an abstract mention of another category
  expect_equal(out$primary_bacteria[1], "Salmonella")
  expect_equal(out$primary_bacteria[2], "Non-descript")
  expect_equal(out$primary_bacteria[3], "Listeria")
  # Both categories recorded for the first record
  expect_setequal(out$bacteria_hits_combined[[1]], c("Salmonella", "Listeria"))
  expect_length(out$bacteria_hits_combined[[2]], 0)
})

test_that("tagging handles empty input and missing text", {
  expect_equal(nrow(tag_with_alias_list(data.frame(), bacteria_alias_expanded, "bacteria")), 0)
  df <- data.frame(Title = NA_character_, Abstract = NA_character_)
  expect_equal(tag_with_alias_list(df, bacteria_alias_expanded, "bacteria")$primary_bacteria,
               "Non-descript")
})

test_that("the bacteria list is well formed", {
  expect_true(exists("bacteria_alias_expanded"))
  expect_gt(length(bacteria_alias_expanded), 20)
  expect_true(all(nzchar(names(bacteria_alias_expanded))))
  all_aliases <- unlist(bacteria_alias_expanded, use.names = FALSE)
  expect_false(any(duplicated(tolower(all_aliases))))
  # very short aliases match too much text, so require at least 3 characters
  expect_true(all(nchar(all_aliases) >= 3))
})

test_that("the plot's pathogen axis follows whichever pool is chosen", {
  df <- data.frame(
    Title = c("Salmonella therapy", "HSV therapy"),
    primary_cell = c("T cell", "Dendritic cell"),
    primary_virus = c("Non-descript", "Herpes Simplex Virus"),
    primary_bacteria = c("Salmonella", "Non-descript"),
    Authors = "A", URL = "https://example.org", SortDate = Sys.Date(), DOI = "10.1/x",
    stringsAsFactors = FALSE
  )
  virus_mode <- prepare_plot_data(df, "primary_virus")
  bact_mode  <- prepare_plot_data(df, "primary_bacteria")
  expect_equal(virus_mode$primary_pathogen, df$primary_virus)
  expect_equal(bact_mode$primary_pathogen, df$primary_bacteria)
})

test_that("an unknown pool column falls back to viruses", {
  df <- data.frame(
    Title = "x", primary_cell = "T cell", primary_virus = "Measles Virus",
    Authors = "A", URL = "https://example.org", SortDate = Sys.Date(), DOI = "10.1/x",
    stringsAsFactors = FALSE
  )
  expect_equal(prepare_plot_data(df, "primary_fungi")$primary_pathogen, "Measles Virus")
})
