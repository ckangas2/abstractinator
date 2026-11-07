#!/usr/bin/env Rscript
# Build master database from all sources

library(dplyr)
library(RSQLite)
library(DBI)
library(httr)
library(jsonlite)
library(future)
library(parallelly)
library(stringr)
library(aws.s3)
library(aws.signature)

plan(multisession)

# Load all extraction sources
source("epmc_standalone_extraction.R")
source("CORE_extraction.R")
source("clinicaltrials.gov_extraction.R")
source("scopus_extraction.R")
source("biorxiv_extraction.R")
source("patentsview_extraction.R")
source("other_sources.R")  # NIH and NSF extractors
source("deduplication.R")
source("scopus_abstract_extraction.R")
source("openalex_standalone_extraction.R")
source("aliases.R")

# Get credentials
elsevier_key <- Sys.getenv("ELSEVIER_API_KEY")
core_key <- Sys.getenv("CORE_API_KEY")
uspto_key <- Sys.getenv("USPTO_API_KEY")

# Configuration
OUTPUT_DIR <- "data"

if (!dir.exists(OUTPUT_DIR)) dir.create(OUTPUT_DIR, recursive = TRUE)

# === Function to normalize and add source to dataframe ===
normalize_df <- function(df, source_label) {
  if (is.null(df) || nrow(df) == 0) return(NULL)
  
  df <- df %>%
    mutate(
      Source = source_label,
      DOI = DOI %||% NA_character_,
      NCTId = NCTId %||% NA_character_,
      CORE_ID = CORE_ID %||% NA_character_,
      PublicationDate = PublicationDate %||% NA_character_,
      AdverseEvents = AdverseEvents %||% NA_character_,
      SeriousAdverseEvents = SeriousAdverseEvents %||% NA_character_,
      is_bioinformatics = is_bioinformatics %||% FALSE
    ) %>%
    select(Source, DOI, NCTId, CORE_ID, Title, Abstract, Authors, 
           PublicationDate, URL, AdverseEvents, SeriousAdverseEvents,
           primary_cell, primary_virus, is_bioinformatics, everything())
  
  return(df)
}

# === Step 1: Fetch all sources ===
cat("\n=== Starting Multi-Source Extraction ===\n\n")

# Public sources (EPMC, OpenAlex, CT.gov, CORE, Patents, biorxiv)
public_data <- list()

cat("1/7: EPMC...\n")
future_epmc <- future({ get_epmc_data("oncolytic virus", page_size = 1000, max_results = 50000) })

cat("2/7: OpenAlex...\n")
future_openalex <- future({ get_openalex_data("oncolytic virus", max_results = 50000) })

cat("3/7: ClinicalTrials.gov...\n")
future_clinical_trials <- future({ get_clinical_trials_data("oncolytic virus", limit = 50000) })

cat("4/7: bioRxiv...\n")
future_biorxiv <- future({ get_biorxiv_data("oncolytic virus", limit = 50000) })

cat("5/7: CORE...\n")
future_core <- if (!is.null(core_key) && nchar(core_key) > 0) {
  future({ get_core_data("oncolytic virus", limit = 50000, api_key = core_key) })
} else NULL

cat("6/7: PatentsView...\n")
future_patents <- if (!is.null(uspto_key) && nchar(uspto_key) > 0) {
  future({ get_patentsview_data("oncolytic virus", limit = 50000, api_key = uspto_key) })
} else NULL

cat("7/7: NIH Reporter...\n")
nih_data <- get_nih_reporter_data("oncolytic virus", desired_results = 300)

cat("8/8: NSF Awards...\n")
nsf_data <- get_nsf_awards_data("oncolytic virus", max_results = 100)

# Wait for futures
cat("\nWaiting for API responses...\n")
epmc <- value(future_epmc)
oa <- value(future_openalex)
ct <- value(future_clinical_trials)
bx <- value(future_biorxiv)
core <- if (!is.null(future_core)) value(future_core) else NULL
pt <- if (!is.null(future_patents)) value(future_patents) else NULL

cat("\n=== Combining Data ===\n")

# Normalize each source
all_sources <- list()

if (!is.null(epmc) && nrow(epmc) > 0) all_sources$EPMC <- normalize_df(epmc, "EPMC")
if (!is.null(oa) && nrow(oa) > 0) all_sources$OpenAlex <- normalize_df(oa, "OpenAlex")
if (!is.null(ct) && nrow(ct) > 0) all_sources$clinicaltrials <- normalize_df(ct, "clinicaltrials.gov")
if (!is.null(bx) && nrow(bx) > 0) all_sources$biorxiv <- normalize_df(bx, "Preprint (biorxiv)")
if (!is.null(core) && nrow(core) > 0) all_sources$core <- normalize_df(core, "CORE")
if (!is.null(pt) && nrow(pt) > 0) all_sources$patents <- normalize_df(pt, "Patent")

if (!is.null(nih_data) && nrow(nih_data) > 0) {
  all_sources$nih <- nih_data %>%
    select(Source, DOI, NCTId, Title, Abstract, Authors, 
           PublicationDate, URL, AdverseEvents, SeriousAdverseEvents,
           primary_cell, primary_virus, is_bioinformatics, has_nih, projectId, piName, orgName) %>%
    mutate(Source = "NIH", DOI = NA_character_, NCTId = NA_character_)
}

if (!is.null(nsf_data) && nrow(nsf_data) > 0) {
  all_sources$nsf <- nsf_data %>%
    select(Source, DOI, NCTId, Title, Abstract, Authors, 
           PublicationDate, URL, AdverseEvents, SeriousAdverseEvents,
           primary_cell, primary_virus, is_bioinformatics, has_nsf, awardID, awardeeName) %>%
    mutate(Source = "NSF", DOI = NA_character_, NCTId = NA_character_)
}

# Combine all
cat("\nBinding all sources...\n")
combined_data <- bind_rows(all_sources, .id = "Source_Label")

cat(sprintf("Total combined records: %d\n", nrow(combined_data)))

# === Step 2: Deduplicate ===
cat("\n=== Deduplicating ===\n")

dedup_results <- deduplicate_data(combined_data)
final_data <- dedup_results$deduplicated

cat(sprintf("After deduplication: %d unique records\n", nrow(final_data)))

# === Step 3: Build master database ===
cat("\n=== Building Master Database ===\n")

db_path <- file.path(OUTPUT_DIR, "master_abstractinator.sqlite")
con <- dbConnect(RSQLite::SQLite(), db_path)

documents <- final_data %>%
  mutate(
    id = paste0(Source, "_", 
                ifelse(!is.na(DOI) & DOI != "", DOI, 
                       ifelse(!is.na(NCTId) & NCTId != "", paste0("NCT", NCTId), 
                              paste0(row_number())))),
    has_doi = !is.na(DOI) & DOI != "",
    has_nct = !is.na(NCTId) & NCTId != "",
    extracted_at = Sys.time()
  ) %>%
  select(id, Source, DOI, NCTId, Title, Abstract, 
         Authors, PublicationDate, URL, AdverseEvents, SeriousAdverseEvents,
         primary_cell, primary_virus, is_bioinformatics, has_doi, has_nct, extracted_at)

stopifnot(nrow(documents) > 0)
stopifnot(!any(is.na(documents$id)))

dbWriteTable(con, "documents", documents, overwrite = TRUE, temporary = FALSE, row.names = FALSE)
dbExecute(con, "CREATE INDEX idx_documents_source ON documents(Source)")
dbExecute(con, "CREATE INDEX idx_documents_has_doi ON documents(has_doi)")
dbExecute(con, "CREATE INDEX idx_documents_bioinformatics ON documents(is_bioinformatics)")
dbExecute(con, "CREATE INDEX idx_documents_date ON documents(CAST(PublicationDate AS DATE))")

# Summary
cat("\n=== SUMMARY ===\n")
summary_stats <- dbGetQuery(con, "SELECT Source, COUNT(*) as count FROM documents GROUP BY 1 ORDER BY 2 DESC")
print(summary_stats)

cat(sprintf("\n✓ Master database built: %s (%d records)\n", db_path, nrow(documents)))

dbDisconnect(con)

cat("\n✓ Done!\n")
cat("\n=== RAG-Ready Database Ready ===\n")
cat("To query:\n")
cat(sprintf("con <- dbConnect(RSQLite::SQLite(), '%s')\n", db_path))
cat("dbGetQuery(con, 'SELECT * FROM documents WHERE is_bioinformatics = TRUE LIMIT 10')\n")
