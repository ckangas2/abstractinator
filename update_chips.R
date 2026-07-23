library(dplyr)
library(purrr)
library(arrow)
library(jsonlite)
library(httr)

# --- 1. CONFIGURATION & ENV ---
BUCKET_NAME <- Sys.getenv("BIORXIV_BUCKET_NAME", "biorxiv-2025-data")
FILE_NAME   <- Sys.getenv("BIORXIV_FILE_KEY", "biorxiv_db_2013_2026.parquet")
CHIPS_OUT   <- Sys.getenv("CHIPS_OUTPUT_PATH", "quick_launch_chips.json")
WEBHOOK_URL <- Sys.getenv("DATA_WEBHOOK_URL")

# --- 2. NOTIFICATION ALERTS ---
send_discord_alert <- function(status, message) {
  timestamp <- Sys.time()
  cat(sprintf("[%s] %s: %s\n", timestamp, status, message))
  
  if (nchar(WEBHOOK_URL) > 0) {
    color_code <- if(grepl("SUCCESS", status)) 5763719 else 15548997
    try({
      payload <- list(
        content = paste0("**Quick Launch Updater:** ", status),
        embeds = list(list(description = message, color = color_code))
      )
      POST(WEBHOOK_URL, body = payload, encode = "json", timeout(10))
    }, silent = TRUE)
  }
}

# --- 3. CORE EXECUTION ---
tryCatch({
  # Define target queries for the chips
  # Example topics aligned with system usage
  chip_queries <- list(
    "Oncolytic Virus" = "Oncolytic Virus",
    "T-VEC" = "T-VEC",
    "Melanoma" = "Melanoma",
    "scRNA-seq" = "scRNA-seq"
  )
  
  stopifnot("Queries must be a named list" = is.list(chip_queries) && length(names(chip_queries)) > 0)
  
  s3_uri <- paste0("s3://", BUCKET_NAME, "/", FILE_NAME)
  
  # Connect to existing Parquet dataset via Arrow (lazy evaluation)
  db <- tryCatch({
    arrow::open_dataset(s3_uri, format = "parquet")
  }, error = function(e) stop("S3 Connection Failed: ", e$message))
  
  # Compute latest papers for each chip 
  # Using standard map to return a named list of data frames
  chip_results <- imap(chip_queries, function(query_string, chip_name) {
    db %>%
      filter(grepl(!!query_string, Title, ignore.case = TRUE) | 
               grepl(!!query_string, Abstract, ignore.case = TRUE)) %>%
      arrange(desc(PublicationDate)) %>%
      head(25) %>% # Cache only top 25 for UI speed
      select(DOI, Title, PublicationDate, Source, URL) %>%
      collect()
  })
  
  # Validate structural integrity before writing
  stopifnot("Output length mismatch" = length(chip_results) == length(chip_queries))
  
  # Write to atomic JSON file
  write_json(chip_results, CHIPS_OUT, pretty = TRUE, auto_unbox = TRUE)
  
  send_discord_alert("SUCCESS", sprintf("Chips updated successfully. Wrote %d categories to %s.", length(chip_queries), CHIPS_OUT))
  
}, error = function(e) {
  send_discord_alert("CRITICAL FAILURE", e$message)
  quit(status = 1)
})

