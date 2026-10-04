# ==========================================================================
# 1. ENVIRONMENT SETUP
# ==========================================================================
library(tidyverse)
library(httr)      # Required for POST()
library(jsonlite)  # Required for fromJSON()
library(lubridate) # Handy for date parsing if needed later

# ==========================================================================
# 2. FUNCTION DEFINITION
# ==========================================================================
get_nih_reporter_data <- function(search_term, desired_results = 300) {
  
  # --- Config ---
  api_url <- "https://api.reporter.nih.gov/v2/projects/search"
  limit <- 100
  offset <- 0
  
  # Initialize an empty list to store page results (more efficient than growing a DF)
  results_accumulator <- list()
  
  # Clean search term. NIH's text search returns server errors (500) on some
  # punctuation, so reduce it to plain words: & " ( ) + [ ] { } < > become spaces.
  search_term <- enc2utf8(tolower(search_term))
  search_term <- trimws(gsub("[[:space:]]+", " ", gsub("[&\"()+{}<>]|\\[|\\]", " ", search_term)))
  if (!nzchar(search_term)) return(data.frame())
  
  message(sprintf("--- Starting NIH RePORTER extraction for: '%s' ---", search_term))
  
  # --- Pagination Loop ---
  repeat {
    
    # Define Payload (Advanced Text Search)
    # - Uses "advanced_text_search" operator
    request_body <- list(
      criteria = list(
        advanced_text_search = list(
          operator = "and",
          search_field = "projecttitle,abstracttext", 
          search_text = search_term
        )
      ),
      offset = offset,
      limit = limit,
      sort_field = "project_start_date",
      sort_order = "desc"
    )
    
    # Execute API Call (Defensive, with retries)
    # Up to 3 attempts with a 20s timeout: brief DNS/network hiccups reaching
    # api.reporter.nih.gov otherwise drop NIH from the whole search.
    response <- NULL
    for (attempt in 1:3) {
      response <- tryCatch({
        httr::POST(
          url = api_url,
          body = jsonlite::toJSON(request_body, auto_unbox = TRUE),
          encode = "json",
          timeout(20),
          add_headers("Content-Type" = "application/json", "Accept" = "application/json")
        )
      }, error = function(e) {
        message(sprintf("NIH API connection error (attempt %d/3): %s", attempt, e$message))
        NULL
      })
      if (!is.null(response) && httr::status_code(response) < 500) break
      if (attempt < 3) Sys.sleep(2 * attempt)
    }
    
    # Check Status
    if (is.null(response) || httr::http_error(response)) {
      status_txt <- if (is.null(response)) "no response" else as.character(httr::status_code(response))
      # Failing on the first page means NIH was unreachable: report it as a failure
      # (so the search isn't cached as if there were no grants). Later pages: keep what we have.
      if (offset == 0) stop(sprintf("NIH RePORTER request failed (%s)", status_txt))
      warning(sprintf("NIH request failed at offset %d (%s); keeping earlier pages.", offset, status_txt))
      break
    }
    
    # Parse Content
    content_text <- httr::content(response, "text", encoding = "UTF-8")
    parsed_json <- jsonlite::fromJSON(content_text, flatten = TRUE)
    
    # Check if 'results' exists in the response
    if (is.null(parsed_json$results)) {
      message("No results found or structure changed.")
      break
    }
    
    results_df <- parsed_json$results
    
    # Zero results arrive as an empty list (nrow() is NULL), so check the shape
    if (!is.data.frame(results_df) || nrow(results_df) == 0) {
      break  # nothing (more) to fetch
    }
    results_accumulator[[length(results_accumulator) + 1]] <- results_df
    
    # --- Loop Control ---
    total_available <- parsed_json$meta$total
    current_count <- sum(sapply(results_accumulator, nrow))
    
    message(sprintf("Fetched %d / %d records...", current_count, min(total_available, desired_results)))
    
    offset <- offset + limit
    
    # Break if we have enough OR we've exhausted the API
    if (current_count >= desired_results || offset >= total_available) {
      break
    }
    
    # Respect API rate limits
    # "recommended that users post no more than one URL request per second"
    Sys.sleep(1.0) 
  }
  
  # --- Combine & Return ---
  if (length(results_accumulator) == 0) {
    return(data.frame()) # Return empty DF if nothing found
  }
  
  # logical binding handling mismatched columns automatically
  final_df <- head(dplyr::bind_rows(results_accumulator), desired_results) 
  
  return(final_df)
}

# # ==========================================================================
# # 3. EXECUTION
# # ==========================================================================
# # Run this block to test
# search_term <- "oncolytic"
# nih_data <- get_nih_reporter_data(search_term, desired_results = 50) # kept small for test
# 
# if (nrow(nih_data) > 0) {
#   print(glimpse(nih_data))
# } else {
#   print("No data retrieved.")
# }
