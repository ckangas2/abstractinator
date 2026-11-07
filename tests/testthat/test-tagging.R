# Category tagging: alias lists become whole-word patterns, and records are
# labelled with the category they match most strongly (title beats abstract).

test_that("alias lists become whole-word patterns", {
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

# --- Regressions found in review (2026-11-07) -------------------------------

tag_cells_and_viruses <- function(title, abstract = "") {
  df <- data.frame(Title = title, Abstract = abstract, stringsAsFactors = FALSE)
  perform_hit_detection(df, aliases_to_regex(immune_cell_alias_list),
                        aliases_to_regex(virus_alias_expanded))
}

test_that("aliases are literal text: the + in CD8+ is a plus sign", {
  rx <- aliases_to_regex(immune_cell_alias_list)
  expect_true(grepl(rx$`CD8+ T cell`, "Exhausted CD8+ T cells in chronic infection", perl = TRUE))
  expect_true(grepl(rx$`CD8+ T cell`, "CD8 T-cell responses", perl = TRUE))
  expect_false(grepl(rx$`CD8+ T cell`, "CD88 T cells", perl = TRUE))
})

test_that("a specific cell type beats the generic one it contains", {
  out <- tag_cells_and_viruses(
    "Exhaustion of CD8+ T cells in chronic infection",
    "CD8+ T cells lose function. Other T cells were not studied.")
  expect_equal(out$primary_cell, "CD8+ T cell")
})

test_that("short acronyms match only in their own case", {
  out <- tag_cells_and_viruses(
    c("Microglia in Alzheimer's disease (AD): a review",
      "An oncolytic Ad5 vector armed with IL-12",
      "Right ventricle (RV) function after mechanical ventilation (MV)"),
    c("AD progression and microglial activation in AD.",
      "Ad infection of tumour cells.",
      "RV and MV outcomes."))
  expect_equal(out$primary_virus, c("Non-descript", "Adenovirus", "Non-descript"))
})

test_that("herpes zoster is not tagged as herpes simplex", {
  expect_false(identical(tag_cells_and_viruses("Herpes zoster after vaccination")$primary_virus,
                         "Herpes Simplex Virus"))
  expect_equal(tag_cells_and_viruses("HSV-2 shedding in women")$primary_virus,
               "Herpes Simplex Virus 2")
})

test_that("no alias is claimed by two categories", {
  for (lst in list(immune_cell_alias_list, virus_alias_expanded, bacteria_alias_expanded)) {
    a <- tolower(unlist(lst, use.names = FALSE))
    owner <- rep(names(lst), lengths(lst))
    shared <- unique(a[duplicated(a)])
    clash <- shared[vapply(shared, function(x) length(unique(owner[a == x])) > 1, logical(1))]
    expect_length(clash, 0)
  }
})

test_that("aliases of three characters or fewer contain a capital, so they match case-sensitively", {
  all_aliases <- unlist(c(immune_cell_alias_list, virus_alias_expanded, bacteria_alias_expanded),
                        use.names = FALSE)
  short <- all_aliases[nchar(all_aliases) <= 3]
  expect_true(all(grepl("[A-Z]", short)), info = paste(short[!grepl("[A-Z]", short)], collapse = ", "))
})
