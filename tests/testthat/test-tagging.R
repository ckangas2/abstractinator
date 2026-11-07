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

test_that("common human pathogens and immunology model viruses are tagged", {
  out <- tag_cells_and_viruses(
    c("CD8 T cell exhaustion in chronic hepatitis B",
      "RSV vaccine in older adults",
      "NKG2C+ NK cells expand after CMV infection",
      "Herpes zoster after vaccination",
      "T cell exhaustion during chronic LCMV infection"))
  expect_equal(out$primary_virus,
               c("Hepatitis B Virus", "Respiratory Syncytial Virus", "Cytomegalovirus",
                 "Varicella-Zoster Virus", "Lymphocytic Choriomeningitis Virus"))
})

test_that("cell subsets win over their parent type", {
  out <- tag_cells_and_viruses(
    c("Microglia in Alzheimer's disease",
      "Plasmacytoid dendritic cells produce type I interferon",
      "γδ T cells in tumour immunity",
      "Follicular helper T cells in germinal centres"))
  expect_equal(out$primary_cell,
               c("Microglia", "Plasmacytoid dendritic cell", "Gamma delta T cell",
                 "T follicular helper cell"))
})

# --- Regressions found by the PubTator3 benchmark (2026-11-07) ---------------

test_that("herpes simplex virus type 2 written out is HSV-2, not HSV-1", {
  expect_equal(tag_cells_and_viruses("A novel oncolytic herpes simplex virus type 2 remodels the tumour")$primary_virus,
               "Herpes Simplex Virus 2")
})

test_that("MeSH replaces a regex tag only with one of our categories", {
  # Stand-ins for the MeSH lookups, so the test needs no network.
  fake <- list(
    mesh_lookup      = function(t) list(terms = character(0)),
    mesh_is_cached   = function(t) TRUE,
    mesh_axis        = function(t, rec) "virus",
    mesh_to_category = function(t, rx, rec) if (t == "Measles virus") "Measles Virus" else t
  )
  had <- vapply(names(fake), exists, logical(1), envir = globalenv(), inherits = FALSE)
  old <- lapply(names(fake)[had], get, envir = globalenv()); names(old) <- names(fake)[had]
  for (n in names(fake)) assign(n, fake[[n]], envir = globalenv())
  withr::defer({
    rm(list = names(fake), envir = globalenv())
    for (n in names(old)) assign(n, old[[n]], envir = globalenv())
  })

  df <- data.frame(
    primary_virus    = c("Measles Virus", "Measles Virus", "Non-descript", "Non-descript"),
    primary_cell     = "Non-descript", primary_bacteria = "Non-descript",
    MeSH_Major       = c("Oncolytic Viruses", "Oncolytic Viruses; Measles virus",
                         "Bluetongue virus", "Viruses"),
    stringsAsFactors = FALSE)
  expect_equal(apply_mesh_tags(df)$primary_virus,
               c("Measles Virus",      # a grouping never overrides the regex tag
                 "Measles Virus",      # the descriptor that maps to a category wins
                 "Bluetongue virus",   # an unlisted organism fills in when regex found none
                 "Non-descript"))      # "Viruses" is too broad to be a tag
})

# --- Regressions from the second review (2026-11-07) -------------------------

test_that("markup in titles doesn't hide a tag", {
  expect_equal(tag_cells_and_viruses("GPR82 drives CD8<sup>+</sup> T cell dysfunction")$primary_cell,
               "CD8+ T cell")
})

test_that("disease names tag the organism that causes them", {
  out <- tag_cells_and_viruses(c("Tissue-resident monocytes following influenza infection",
                                 "COVID-19 vaccine T cell responses",
                                 "Haemophilus influenzae colonisation",
                                 "Hearing aids in older adults"))
  expect_equal(out$primary_virus, c("Influenza", "SARS-CoV-2", "Non-descript", "Non-descript"))
  df <- data.frame(Title = c("HIV and tuberculosis co-infection trial", "Lyme disease in children"),
                   Abstract = "", stringsAsFactors = FALSE)
  expect_equal(tag_with_alias_list(df, bacteria_alias_expanded, "bacteria")$primary_bacteria,
               c("Mycobacterium tuberculosis", "Borrelia burgdorferi"))
})

test_that("the bioinformatics flag needs a specific computational phrase", {
  expect_equal(
    flag_bioinformatics(c("Palivizumab adherence: a claims database study", "Misalignment of care",
                          "Single-cell RNA-seq of tumour-infiltrating T cells", "An R package for flow cytometry",
                          "In silico epitope prediction", NA),
                        c("", "", "", "", "", "Molecular docking of inhibitors")),
    c(FALSE, FALSE, TRUE, TRUE, TRUE, TRUE))
})

test_that("retracted records are flagged by source or by title", {
  df <- data.frame(Title = c("Retracted: CD8+ T cell exhaustion in HBV", "A normal paper",
                             "[WITHDRAWN] Another", "Retraction rates in immunology"),
                   IsRetracted = c(NA, TRUE, FALSE, FALSE), stringsAsFactors = FALSE)
  expect_equal(normalize_records(df)$IsRetracted, c(TRUE, TRUE, TRUE, FALSE))
  expect_equal(normalize_records(data.frame(Title = "Retracted: x"))$IsRetracted, TRUE)
})

test_that("a MeSH lookup that fails on the network is queued, not cached", {
  skip_if_not(exists("local_mocked_bindings", envir = asNamespace("testthat")))
  e <- new.env()
  sys.source(file.path(repo_root, "R", "mesh_utils.R"), envir = e)
  unlink(e$mesh_pending_path())
  withr::defer(unlink(e$mesh_pending_path()))
  local_mocked_bindings(GET = function(...) stop("NLM is down"), .package = "httr")

  rec <- e$mesh_lookup("Some Descriptor Nobody Cached")
  expect_length(rec$trees, 0)
  expect_false(e$mesh_is_cached("Some Descriptor Nobody Cached"))
  expect_equal(readLines(e$mesh_pending_path()), "Some Descriptor Nobody Cached")
})
