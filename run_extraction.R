#!/usr/bin/env Rscript
# Run extraction for "oncolytic herpes virus", build DB, and notify

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

# Mock S3 functions before sourcing files
check_s3_cache <- function(...) TRUE
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

# Configuration
SEARCH_TERM <- "oncolytic herpes virus"
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

db_path <- file.path(OUTPUT_DIR, "abstractinator.sqlite")
con <- dbConnect(RSQLite::SQLite(), db_path)

# Check column names
cat("Column names in extracted data:\n")
print(names(result$deduplicated))

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

# Step 3: Send notification
cat("=== Sending Discord Notification ===\n")

summary_stats <- data.frame(
  Source = names(table(documents$Source_Label)),
  Count = as.vector(table(documents$Source_Label))
)

notification_msg <- sprintf(
  "✅ Extraction complete: **%s**\n\n"
  "📊 Results: %d records\n\n"
  "📁 Database: `%s`\n\n"
  "🔍 By Source:\n",
  SEARCH_TERM,
  nrow(documents),
  db_path
)

for (i in 1:nrow(summary_stats)) {
  notification_msg <- paste0(notification_msg, 
                             sprintf("* %s *: %d\n", 
                                     summary_stats$Source[i], 
                                     summary_stats$Count[i]))
}

send_discord_notify(notification_msg)

cat("✓ Done!\n")
