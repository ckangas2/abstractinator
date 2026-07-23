# log_utils_aws.R
# Protocol: Event Logging with Metadata
# Dependencies: jsonlite, uuid, dplyr, purrr

library(jsonlite)
library(uuid)
library(dplyr)
library(purrr)

#' Log search event locally (Overriding S3 version)
#' @param search_term String: The user input
#' @param duration_sec Numeric: Time taken
#' @param result_count Integer: Number of rows found
#' @param source_type String: "CACHE" or "API"
#' @param elsevier_key String: The active key (used to log TRUE/FALSE)
#' @param uspto_key String: The active key (used to लाभ TRUE/FALSE)
#' @return Logical: TRUE if upload succeeded
log_search_to_s3 <- function(search_term, duration_sec, result_count, source_type, elsevier_key = NULL, uspto_key = NULL, core_key = NULL) {
  
  message("[Logger] Redirecting search log to local file (S3 Disabled)...")
  
  # 1. Calculate Metadata
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  # 2. Prepare Payload
  log_data <- list(
    term = search_term,
    timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
    duration = round(duration_sec, 2),
    n_results = result_count,
    source = source_type,
    has_elsevier = has_elsevier,
    has_uspto = has_uspto,
    has_core = has_core,
    session_id = paste(Sys.info()[["user"]], Sys.getpid(), sep="_")
  )
  
  json_payload <- jsonlite::toJSON(log_data, auto_unbox = TRUE, pretty = TRUE)
  
  # 3. Save to local logs directory
  log_dir <- "logs"
  if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)
  
  date_path <- format(Sys.time(), "%Y-%m-%d")
  unique_id <- uuid::UUIDgenerate()
  
  # Create directory for the day
  day_folder <- file.path(log_dir, date_path)
  if (!dir.exists(day_folder)) dir.create(day_folder, recursive = TRUE)
  
  file_name <- file.path(day_folder, sprintf("search_%s_%s.json", as.numeric(Sys.time()), unique_id))
  
  tryCatch({
    write(json_payload, file = file_name)
    TRUE
  }, error = function(e) {
    warning(paste("[Logger] Local Save Failed:", e$message))
    FALSE
  })
}

#' Admin tool: Fetch local search logs
fetch_search_logs <- function() {
  log_dir <- "logs"
  if (!dir.exists(log_dir)) return(NULL)
  
  files <- list.files(log_dir, recursive = TRUE, full.names = TRUE, pattern = "*.json")
  
  if (length(files) == 0) {
    message("No logs found.")
    return(NULL)
  }
  
  logs_df <- purrr::map_df(files, function(f) {
    tryCatch({
      jsonlite::fromJSON(f)
    }, error = function(e) NULL)
  })
  
  if (nrow(logs_df) > 0) {
    logs_df <- logs_df %>%
      as_tibble() %>%
      mutate(
        timestamp = as.POSIXct(timestamp, format = "%Y-%m-%d %H:%M:%S %Z", tz = "UTC"),
        duration = as.numeric(duration),
        n_results = as.integer(n_results)
      ) %>%
      arrange(desc(timestamp))
  }
  
  return(logs_df)
}