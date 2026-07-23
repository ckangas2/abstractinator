#!/usr/bin/env Rscript
# Run extraction for "oncolytic bacteria", build DB, and report
# Using fresh extraction (no cache) to match Shiny app behavior

library(dplyr)
library(RSQLite)
library(DBI)
library(httr)
library(jsonlite)
library(future)
library(parallelly)
library(stringr)

plan(multisession)

# Mock S3 functions to force fresh extraction
check_s3_cache <- function(...) FALSE
fetch_from_s3 <- function(...) NULL
save_to_s3 <- function(...) NULL

# Load all extraction sources
source("epmc_standalone_extraction.R")
source("CORE_extraction.R")
source("clinicaltrials.gov_extraction.R")
source("scopus_extraction.R")
source("biorxiv_extraction.R")
source("patentsview_extraction.R")
source("deduplication.R")
source("scopus_abstract_extraction.R")
source("openalex_standalone_extraction.R")
source("aliases.R")

# Load orchestration (uses mocked S3)
source("orchestrate_extraction.R")

# Get credentials from new env var names
elsevier_key <- Sys.getenv("ELSEVIER_API_KEY")
core_key <- Sys.getenv("CORE_API_KEY")
uspto_key <- Sys.getenv("USPTO_API_KEY")

# Configuration
SEARCH_TERM <- "oncolytic bacteria"
OUTPUT_DIR <- "data"

# Discord notification
WEBHOOK_URL <- Sys.getenv("DATA_WEBHOOK_URL")

send_discord_notify <- function(message) {
  if (WEBHOOK_URL == "") return()
  tryCatch({
    httr::POST(WEBHOOK_URL, body = list(content = message), httr::content("text"))
    cat("✓ Discord notification sent\n")
  }, error = function(e) {
    cat(sprintf("✗ Failed to send Discord: %s\n", e$message))
  })
}

# Step 1: Run extraction
cat(sprintf("\n=== Starting extraction for: %s ===\n\n", SEARCH_TERM))

tryCatch({
  result <- orchestrate_data_extraction_cached(
    search_term = SEARCH_TERM,
    elsevier_key = elsevier_key,
    core_key = core_key,
    uspto_key = uspto_key,
    update_progress = function(step_val = 0, detail_text = "") {
      cat(sprintf("Progress: %.0f%% - %s\n", step_val * 100, detail_text))
    }
  )
  
  if (is.null(result$deduplicated_data) || nrow(result$deduplicated_data) == 0) {
    cat("\nNo results found!\n")
    send_discord_notify("⚠️ No results found for: `" %s% SEARCH_TERM)
    quit(status = 1)
  }
  
  cat(sprintf("\n✓ Extraction complete: %d records\n\n", nrow(result$deduplicated_data)))
  
}, error = function(e) {
  cat(sprintf("\n✗ Extraction failed: %s\n", e$message))
  send_discord_notify("✗ Extraction failed for: `" %s% SEARCH_TERM)
  quit(status = 1)
})

# Step 2: Build SQLite database
cat("=== Building SQLite Database ===\n")

if (!dir.exists(OUTPUT_DIR)) dir.create(OUTPUT_DIR, recursive = TRUE)

db_path <- file.path(OUTPUT_DIR, "abstractinator_bacteria.sqlite")
con <- dbConnect(RSQLite::SQLite(), db_path)

documents <- result$deduplicated %>%
  mutate(
    id = paste0(Source_Label, "_", 
                ifelse(!is.na(DOI) & DOI != "", DOI, 
                       ifelse(!is.na(NCTId) & NCTId != "", paste0("NCT", NCTId), 
                              paste0(row_number())))),
    has_doi = !is.na(DOI) & DOI != "",
    has_nct = !is.na(NCTId) & NCTId != "",
    search_term = SEARCH_TERM,
    extracted_at = Sys.time()
  ) %>%
  select(id, Source_Label, DOI, NCTId, Title, Abstract, 
         Authors, PublicationDate, URL, AdverseEvents, SeriousAdverseEvents,
         primary_virus, primary_cell, is_bioinformatics, has_doi, has_nct, 
         search_term, extracted_at)

stopifnot(nrow(documents) > 0)
stopifnot(!any(is.na(documents$id)))

dbWriteTable(con, "documents", documents, overwrite = TRUE, temporary = FALSE, row.names = FALSE)
dbExecute(con, "CREATE INDEX idx_documents_source ON documents(Source_Label)")
dbExecute(con, "CREATE INDEX idx_documents_has_doi ON documents(has_doi)")
dbExecute(con, "CREATE INDEX idx_documents_bioinformatics ON documents(is_bioinformatics)")
dbExecute(con, "CREATE INDEX idx_documents_date ON documents(CAST(PublicationDate AS DATE))")
dbExecute(con, "CREATE INDEX idx_documents_search_term ON documents(search_term)")

dbDisconnect(con)

cat(sprintf("✓ Database built: %s (%d records)\n\n", db_path, nrow(documents)))

# Step 3: Report results
cat("=== RESULTS SUMMARY ===\n")
cat(sprintf("Total records: %d\n", nrow(documents)))

summary_stats <- data.frame(
  Source = names(table(documents$Source_Label)),
  Count = as.vector(table(documents$Source_Label))
)

cat("\nRecords by source:\n")
print(summary_stats)

send_discord_notify(sprintf("✅ Extraction complete: %s\n\nTotal: %d records\n\nBy source:\n%s", 
                           SEARCH_TERM, nrow(documents),
                           paste(sprintf("* %s: %d", summary_stats$Source, summary_stats$Count), collapse = "\n")))

cat("\n✓ Done!\n")
