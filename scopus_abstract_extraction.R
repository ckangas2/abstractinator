library(httr)
library(jsonlite)
library(dplyr)
library(stringr)

retrieve_scopus_abstracts <- function(deduplicated_df, search_term = "DOI_lookup", api_key = NULL) {
  
  # 1. SETUP CREDENTIALS
  # Fallback to env if not passed
  valid_key <- if (!is.null(api_key)) api_key else Sys.getenv("ELSEVIER_API_KEY")
  
  if (valid_key == "") {
    warning("No Scopus API Key found. Skipping abstract retrieval.")
    return(NULL)
  }
  
  print("    > Starting Scopus Abstract Retrieval (View: META_ABS)")
  
  # Filter for records that need abstracts (Have DOI but Abstract is empty/NA)
  records_to_process <- deduplicated_df %>%
    filter(!is.na(DOI) & DOI != "" & (is.na(Abstract) | Abstract == ""))
  
  print(paste("    > Found", nrow(records_to_process), "records needing abstract lookup."))
  
  if (nrow(records_to_process) == 0) return(deduplicated_df)
  
  # 2. RETRIEVAL LOOP
  for (i in 1:nrow(records_to_process)) {
    doi <- records_to_process$DOI[i]
    clean_doi <- trimws(doi)
    
    # URL points to the specific DOI resource
    base_url <- paste0("https://api.elsevier.com/content/abstract/doi/", clean_doi)
    
    # Headers are safer than URL parameters
    req_headers <- add_headers(
      "X-ELS-APIKey" = valid_key,
      "Accept" = "application/json"
    )
    
    # --- RETRY LOGIC (The 429 Fix) ---
    response <- NULL
    attempt <- 1
    max_attempts <- 3 # Try 3 times before giving up
    
    while (attempt <= max_attempts) {
      tryCatch({
        # We use META_ABS to get the abstract without full-text restrictions
        response <- GET(base_url, query = list(view = "META_ABS"), req_headers)
        
        # A. Success
        if (status_code(response) == 200) {
          break 
        } 
        # B. Rate Limit (429) or Server Error (500)
        else if (status_code(response) == 429 || status_code(response) >= 500) {
          # Exponential Backoff: Wait 2s, then 4s...
          wait_time <- 2^attempt 
          print(paste0("    > [", status_code(response), "] Rate limit hit. Pausing ", wait_time, "s..."))
          Sys.sleep(wait_time)
          attempt <- attempt + 1
        } 
        # C. Not Found (404) or other client errors
        else {
          break 
        }
      }, error = function(e) {
        print(paste("    > Network Error:", e$message))
        attempt <- attempt + 1
        Sys.sleep(1)
      })
    }
    
    # --- PARSE RESULT ---
    if (!is.null(response) && status_code(response) == 200) {
      print("scopus = 200")
      # Use parsed content for safety
      content_list <- content(response, as = "parsed", encoding = "UTF-8")
      
      tryCatch({
        # Navigate Elsevier's JSON structure
        core_data <- content_list$`abstracts-retrieval-response`$coredata
        new_abstract <- core_data$`dc:description`
        
        # Match back to the dataframe row
        match_idx <- which(deduplicated_df$DOI == doi)
        
        # Only update if we actually found something
        if (!is.null(new_abstract)) {
          deduplicated_df$Abstract[match_idx] <- new_abstract
        }
      }, error = function(e) {
        # Silent fail on parsing structure changes
      })
    }
    
    # Progress Ticker (one dot every 10 requests)
    if (i %% 10 == 0) cat(".")
    
    # --- PACING (The .3s Rule) ---
    Sys.sleep(0.3) 
  }
  
  cat("\n")
  print("    > Abstract retrieval complete.")
  return(deduplicated_df)
}