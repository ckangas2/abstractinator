library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(stringr)

# ==============================================================================
# CORE Extraction - httr2 Refactor
# Target: https://api.core.ac.uk/v3/search/works
# ==============================================================================

get_core_data <- function(search_term, limit = 100, api_key = NULL) {
  
  # 1. Credential Validation
  valid_key <- if (!is.null(api_key)) api_key else Sys.getenv("CORE_API_KEY")
  if (is.null(valid_key) || valid_key == "") {
    message("[CORE] Warning: No API Key found. Skipping extraction.")
    return(NULL)
  }
  
  # 2. Strict Input Validation
  stopifnot(
    "Search term must be a valid string" = is.character(search_term) && nchar(trimws(search_term)) > 0,
    "Limit must be numeric and positive" = is.numeric(limit) && limit > 0
  )
  
  # 3. Query Construction
  # Enclosing the search term in literal quotes ensures precision for multi-word biological terms
  final_query <- if (!str_detect(search_term, ":")) {
    paste0("(title:\"", search_term, "\" OR abstract:\"", search_term, "\")")
  } else {
    search_term
  }
  
  message(sprintf("[CORE] Initializing search for '%s'", search_term))
  message(sprintf("    > Effective Query: %s", final_query))
  
  batch_size <- 100
  num_batches <- ceiling(limit / batch_size)
  all_results_list <- list()
  api_url <- "https://api.core.ac.uk/v3/search/works"
  
  # 4. Pagination Engine
  for (i in 0:(num_batches - 1)) {
    current_offset <- i * batch_size
    current_limit <- min(batch_size, limit - current_offset)
    if (current_limit <= 0) break
    
    message(sprintf("    > Fetching Batch %d/%d (Offset: %d)...", i + 1, num_batches, current_offset))
    
    body <- list(
      q = final_query,
      limit = current_limit,
      offset = current_offset,
      stats = FALSE
    )
    
    # 5. HTTR2 Architecture
    req <- request(api_url) %>%
      req_method("POST") %>%
      req_auth_bearer_token(valid_key) %>%
      req_body_json(body, auto_unbox = TRUE) %>%
      req_timeout(25) %>%
      # Hardened retry logic strictly targeted at provider-side instability
      req_retry(max_tries = 3, max_seconds = 60, is_transient = function(resp) {
        resp_status(resp) %in% c(429, 500, 502, 503, 504)
      })
    
    # Contract: Trap failures locally so the batch loop can either proceed or terminate cleanly
    resp <- tryCatch({
      req_perform(req)
    }, error = function(e) {
      message(sprintf("[CORE] Fatal Network/Timeout Error: %s", e$message))
      return(NULL)
    })
    
    if (is.null(resp)) {
      message("[CORE] Batch failed. Terminating pagination.")
      break 
    }
    
    # 6. Parse JSON safely
    json <- tryCatch({
      resp_body_json(resp, simplifyVector = TRUE, flatten = TRUE)
    }, error = function(e) {
      message("[CORE] JSON Parsing Error")
      return(NULL)
    })
    
    if (is.null(json)) break
    
    if (i == 0) {
      total_found <- if (!is.null(json$totalHits)) json$totalHits else "Unknown"
      message(sprintf("    > API Hit Count: %s", total_found))
    }
    
    if (!is.null(json$results) && is.data.frame(json$results) && nrow(json$results) > 0) {
      all_results_list[[i + 1]] <- as_tibble(json$results)
      message(sprintf("    > Retrieved %d records.", nrow(json$results)))
    } else {
      message("    > Empty payload returned. Terminating pagination.")
      break
    }
    
    Sys.sleep(1) 
  }
  
  if (length(all_results_list) == 0) return(NULL)
  
  raw_df <- bind_rows(all_results_list)
  
  # Defensive extraction helper
  safe_extract <- function(df, col_name, default = NA_character_) {
    if (col_name %in% names(df)) as.character(df[[col_name]]) else default
  }
  
  # 7. Map to Abstractinator Schema
  clean_df <- tryCatch({
    raw_df %>%
      transmute(
        CORE_ID = safe_extract(., "id"),
        Title = safe_extract(., "title", "Unknown Title"),
        Abstract = safe_extract(., "abstract", NA_character_),
        PublicationDate = safe_extract(., "publishedDate", NA_character_),
        DOI = safe_extract(., "doi", NA_character_),
        
        # Type-stable array mapping
        Authors = if ("authors" %in% names(.)) {
          map_chr(authors, function(x) {
            if (is.data.frame(x) && "name" %in% names(x)) paste(x$name, collapse = "; ")
            else if (is.character(x)) paste(x, collapse = "; ")
            else "Unknown"
          })
        } else { "Unknown" },
        
        URL = case_when(
          !is.na(DOI) & DOI != "" ~ paste0("https://doi.org/", DOI),
          TRUE ~ NA_character_
        ),
        Source = "CORE",
        Affiliations = "Not Available",
        AuthorAffiliations = "Not Available",
        EPMC_ID = NA_character_,
        NCTId = NA_character_,
        Published_DOI_biorxiv = NA_character_
      )
  }, error = function(e) {
    message(sprintf("[CORE] Data mapping error: %s", e$message))
    return(NULL)
  })
  
  return(clean_df)
}