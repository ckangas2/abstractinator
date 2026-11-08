# Therapeutic landscape: trial interventions, therapy-modality tags, and the
# "what's been tried" tables.

test_that("trial interventions and conditions are read from the registry's shape", {
  js <- '{"studies":[{"protocolSection":{
            "armsInterventionsModule":{"interventions":[
              {"type":"DRUG","name":"Pembrolizumab"},
              {"type":"RADIATION","name":"SBRT"},
              {"type":"DIETARY_SUPPLEMENT","name":"Vitamin D"}]},
            "conditionsModule":{"conditions":["Pancreatic Cancer","Metastatic Disease"]}}},
          {"protocolSection":{"conditionsModule":{"conditions":["Influenza"]}}}]}'
  st <- jsonlite::fromJSON(js)$studies
  iv <- st$protocolSection$armsInterventionsModule$interventions
  expect_equal(format_ctgov_interventions(iv[[1]]),
               "Pembrolizumab (Drug); SBRT (Radiation); Vitamin D (Dietary supplement)")
  expect_true(is.na(format_ctgov_interventions(iv[[2]])))
  expect_true(is.na(format_ctgov_interventions(NULL)))
  cond <- st$protocolSection$conditionsModule$conditions
  expect_equal(format_ctgov_conditions(cond[[1]]), "Pancreatic Cancer; Metastatic Disease")
  expect_true(is.na(format_ctgov_conditions(character(0))))
})

tag_mod <- function(title, abstract = "", interventions = NA_character_) {
  df <- data.frame(Title = title, Abstract = abstract, Interventions = interventions,
                   stringsAsFactors = FALSE)
  tag_modality(df)$primary_modality
}

test_that("therapy modality is tagged, more specific categories winning", {
  expect_equal(tag_mod(c("Dendritic cell vaccine for glioblastoma",
                         "Influenza vaccination in older adults",
                         "CAR-NK cells against solid tumours",
                         "CD19 CAR T cells in lymphoma",
                         "Trastuzumab deruxtecan in HER2-low breast cancer",
                         "Oncolytic adenovirus VCN-01 with nab-paclitaxel in pancreatic cancer")),
               c("Cancer vaccine", "Vaccine", "Other adoptive cell therapy", "CAR-T cell therapy",
                 "Antibody-drug conjugate", "Oncolytic virus"))
})

test_that("a trial is tagged from its registered interventions", {
  expect_equal(tag_mod("A Study in Participants With Advanced Pancreatic Cancer",
                       interventions = "MRTX1133 (Drug)"), "Targeted small molecule")
  # without interventions the title alone says nothing about the therapy
  expect_equal(tag_mod("A Study in Participants With Advanced Pancreatic Cancer"), "Non-descript")
})

test_that("everyday immunology words are not therapies", {
  expect_equal(tag_mod(c("Antiviral T cell responses in chronic infection",
                         "Antibiotic-treated mice lose colonisation resistance")),
               c("Non-descript", "Non-descript"))
})

test_that("records are placed on the path from grant to trial phase", {
  expect_equal(evidence_stage(c("NIH", "NSF", "Preprint (biorxiv)", "EPMC", "OpenAlex",
                                "clinicaltrials.gov", "clinicaltrials.gov", "clinicaltrials.gov",
                                "clinicaltrials.gov", "clinicaltrials.gov"),
                              c(NA, NA, NA, NA, NA, "Early Phase 1", "Phase 1/Phase 2",
                                "Phase 3", "Phase 4", NA)),
               c("Grant", "Grant", "Preprint", "Paper", "Paper", "Trial: phase 1", "Trial: phase 2",
                 "Trial: phase 3+", "Trial: phase 3+", "Trial: no phase"))
})

landscape_fixture <- function() {
  df <- data.frame(
    Source = c("EPMC", "NIH", "clinicaltrials.gov", "clinicaltrials.gov", "clinicaltrials.gov", "EPMC"),
    Phase = c(NA, NA, "Phase 2", "Phase 1", "Phase 3", NA),
    TrialStatus = c(NA, NA, "RECRUITING", "COMPLETED", "ACTIVE_NOT_RECRUITING", NA),
    TrialStart = c(NA, NA, "2024-01", "2022-05", "2023-02", NA),
    NCTId = c(NA, NA, "NCT00000002", "NCT00000001", "NCT00000003", NA),
    Interventions = c(NA, NA, "Pembrolizumab (Drug)", "VCN-01 (Biological)",
                      "Gemcitabine (Drug); Pembrolizumab (Drug)", NA),
    Conditions = c(NA, NA, "Pancreatic Cancer", "Pancreatic Cancer", "Pancreatic Cancer", NA),
    primary_modality = c("Checkpoint inhibitor", "Oncolytic virus", "Checkpoint inhibitor",
                         "Oncolytic virus", "Chemotherapy", "Non-descript"),
    stringsAsFactors = FALSE)
  df$modality_hits_combined <- list("Checkpoint inhibitor", "Oncolytic virus", "Checkpoint inhibitor",
                                    "Oncolytic virus", c("Chemotherapy", "Checkpoint inhibitor"), character(0))
  df
}

test_that("the landscape counts each record once, under its main therapy", {
  tab <- therapy_landscape(landscape_fixture())
  expect_equal(tab$Therapy, c("Checkpoint inhibitor", "Oncolytic virus", "Chemotherapy"))
  expect_equal(tab$Total, c(2L, 2L, 1L))
  ci <- tab[tab$Therapy == "Checkpoint inhibitor", ]
  expect_equal(c(ci$Paper, ci$`Trial: phase 2`, ci$Recruiting), c(1L, 1L, 1L))
  ov <- tab[tab$Therapy == "Oncolytic virus", ]
  expect_equal(c(ov$Grant, ov$`Trial: phase 1`, ov$Recruiting), c(1L, 1L, 0L))
  expect_false("Non-descript" %in% tab$Therapy)
  expect_equal(nrow(therapy_landscape(NULL)), 0)
})

test_that("trials are listed most advanced first, and filter by any matching therapy", {
  t <- trials_tried(landscape_fixture())
  expect_equal(t$Trial, c("NCT00000003", "NCT00000002", "NCT00000001"))
  expect_equal(t$Status[2], "Recruiting")
  # the phase 3 combination trial counts as a checkpoint-inhibitor trial too
  expect_equal(trials_tried(landscape_fixture(), "Checkpoint inhibitor")$Trial,
               c("NCT00000003", "NCT00000002"))
  expect_equal(nrow(trials_tried(landscape_fixture(), "Gene therapy")), 0)
})

test_that("gene and RNA therapies split by kind, and research tools aren't therapies", {
  expect_equal(tag_mod(c("AAV gene therapy for haemophilia B",
                         "CRISPR gene editing therapy for sickle cell disease",
                         "An siRNA therapeutic for hereditary amyloidosis",
                         "Gene therapy for inherited retinal disease",
                         "A genome-wide CRISPR screen of T cell exhaustion")),
               c("Viral vector gene therapy", "Gene editing therapy", "RNA therapeutic",
                 "Gene therapy", "Non-descript"))
})

test_that("chemotherapy is the backbone, not the headline, of a combination trial (live cases)", {
  expect_equal(tag_mod(
    c("Oncolytic Adenovirus TILT-123 in Combination With Lymphocyte-depleting Chemotherapy and Tumor-infiltrating Lymphocytes in Melanoma",
      "Neoadjuvant Intravesical NIS Measles Virus (MV-NIS) in Patients Ineligible for Neoadjuvant Cisplatin-based Chemotherapy",
      "Gemcitabine plus nab-paclitaxel in metastatic pancreatic cancer"),
    interventions = c("TILT-123 (Biological); TIL (Biological); Cyclophosphamide (Drug); Fludarabine (Drug)",
                      "MV-NIS (Biological)", "Gemcitabine (Drug); Nab-paclitaxel (Drug)")),
    c("Oncolytic virus", "Oncolytic virus", "Chemotherapy"))
  # chemotherapy is still recorded among the therapies the trial uses
  df <- data.frame(Title = "TILT-123 with lymphodepleting chemotherapy", Abstract = "",
                   Interventions = "TILT-123 (Biological); Cyclophosphamide (Drug)")
  expect_true("Chemotherapy" %in% tag_modality(df)$modality_hits_combined[[1]])
})

test_that("trial phases summarise earliest first, with unphased trials last", {
  df <- data.frame(Source = c(rep("clinicaltrials.gov", 7), "EPMC"),
                   Phase = c("Phase 2", "Phase 1", "Phase 1/Phase 2", NA, "Early Phase 1",
                             "Phase 1", "Phase 3", NA))
  expect_equal(trial_phase_summary(df),
               c("Early Phase 1" = 1L, "Phase 1" = 2L, "Phase 1/2" = 1L, "Phase 2" = 1L,
                 "Phase 3" = 1L, "Not applicable" = 1L))
  expect_length(trial_phase_summary(data.frame(Source = "EPMC")), 0)
})
