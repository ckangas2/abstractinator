# log_utils_local.R
# Protocol: Local Event Logging (Mimicking S3 structure)

library(jsonlite)
library(uuid)
library(dplyr)
library(purrr)

LOG_DIR <- ".cache/s3_mimic/logs/"
if (!dir.exists(LOG_DIR)) dir.create(LOG_DIR, recursive = TRUE)

#' Log search event locally
#' channel: "website" (Shiny app) or "agent" (REST API / MCP connector)
log_search_to_s3 <- function(search_term, duration_sec, result_count, source_type, elsevier_key = NULL, uspto_key = NULL, core_key = NULL, channel = "website") {
  
  message("[Logger] Writing log to local cache mimic...")
  
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
    channel = channel,
    has_elsevier = has_elsevier,
    has_uspto = has_uspto,
    has_core = has_core,
    session_id = paste(Sys.info()[["user"]], Sys.getpid(), sep="_")
  )
  
  json_payload <- jsonlite::toJSON(log_data, auto_unbox = TRUE, pretty = TRUE)
  
  # 3. Save to mimic directory
  date_path <- format(Sys.time(), "%Y-%m-%d")
  day_folder <- file.path(LOG_DIR, date_path)
  if (!dir.exists(day_folder)) dir.create(day_folder, recursive = TRUE)
  
  unique_id <- uuid::UUIDgenerate()
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
  if (!dir.exists(LOG_DIR)) return(NULL)
  
  files <- list.files(LOG_DIR, recursive = TRUE, full.names = TRUE, pattern = "*.json")
  
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
    # Logs written before the channel field existed all came from the website
    if (!"channel" %in% names(logs_df)) logs_df$channel <- "website"
    logs_df$channel[is.na(logs_df$channel)] <- "website"
  }
  
  return(logs_df)
}

#' Admin tool: searches per day, split by website vs AI agent
#' Example: Rscript -e 'source("R/log_utils_local.R"); print(summarize_search_logs())'
summarize_search_logs <- function() {
  logs <- fetch_search_logs()
  if (is.null(logs) || nrow(logs) == 0) return(NULL)
  logs %>%
    mutate(day = as.Date(timestamp)) %>%
    count(day, channel, name = "searches") %>%
    tidyr::pivot_wider(names_from = channel, values_from = searches, values_fill = 0) %>%
    arrange(desc(day))
}
