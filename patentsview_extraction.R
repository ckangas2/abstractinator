library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(stringr)

# ==============================================================================
# USPTO Open Data Portal (ODP) Extraction - App-Compatible httr2 Refactor
# Target: https://api.uspto.gov/api/v1/patent/applications/search
# ==============================================================================

get_uspto_odp_data <- function(search_term, api_key = NULL, limit = 10) {
  
  if (is.null(api_key)) api_key <- Sys.getenv("USPTO_API_KEY")
  
  # App Contract: Return NULL on invalid key
  if (is.null(api_key) || nchar(api_key) < 10) {
    message("[USPTO ODP] Error: No valid API Key found.")
    return(NULL) 
  }
  
  url <- "https://api.uspto.gov/api/v1/patent/applications/search"
  
  query_body <- list(
    q = search_term,
    pagination = list(offset = 0, limit = limit)
  )
  
  req <- request(url) %>%
    req_method("POST") %>%
    req_headers(
      `X-API-KEY` = api_key, 
      `Accept` = "application/json"
    ) %>%
    req_body_json(query_body) %>%
    req_timeout(20) %>%
    req_retry(max_tries = 3, max_seconds = 60)
  
  # App Contract: Catch network errors and return NULL instead of throwing stop()
  resp <- tryCatch({
    req_perform(req)
  }, error = function(e) {
    message(sprintf("[USPTO ODP] Request Error: %s", e$message))
    return(NULL) 
  })
  
  if (is.null(resp)) return(NULL)
  
  # Parse json safely
  json <- tryCatch({
    resp_body_json(resp, simplifyVector = TRUE, flatten = TRUE)
  }, error = function(e) {
    message("[USPTO ODP] Parsing Error")
    return(NULL)
  })
  
  # App Contract: Return NULL if missing data bag
  if (!"patentFileWrapperDataBag" %in% names(json) || length(json$patentFileWrapperDataBag) == 0) {
    return(NULL) 
  }
  
  raw_df <- as_tibble(json$patentFileWrapperDataBag)
  
  if (nrow(raw_df) == 0) return(NULL)
  
  # Helper to prevent missing column errors
  safe_extract <- function(df, col_name, default = NA_character_) {
    if (col_name %in% names(df)) as.character(df[[col_name]]) else default
  }
  
  # App Contract: Wrap in tryCatch and use transmute to enforce exact column subset
  df <- tryCatch({
    raw_df %>%
      transmute(
        DOI = safe_extract(., "applicationNumberText"),
        Title = safe_extract(., "applicationMetaData.inventionTitle", "Unknown Title"),
        Abstract = safe_extract(., "applicationMetaData.abstractText", "No Abstract Available via Search API"),
        
        # Replace the broken case_when logic with this robust extraction:
        PublicationDate = dplyr::coalesce(
          safe_extract(., "applicationMetaData.publicationDate"),
          safe_extract(., "applicationMetaData.grantDate")
        ),
        
        Authors = if ("applicationMetaData.inventorBag" %in% names(.)) {
          map_chr(`applicationMetaData.inventorBag`, function(x) {
            if (is.null(x) || !is.data.frame(x) || !"inventorNameText" %in% names(x)) return("Unknown")
            paste(x$inventorNameText, collapse = "; ")
          })
        } else { "Unknown" },
        
        Affiliations = if ("assignmentBag" %in% names(.)) {
          map_chr(assignmentBag, function(bag) {
            if (is.null(bag) || !is.data.frame(bag) || !"assigneeBag" %in% names(bag)) return("Unknown Assignee")
            assignees <- bag$assigneeBag[[1]] 
            if (is.data.frame(assignees) && "assigneeNameText" %in% names(assignees)) {
              return(paste(assignees$assigneeNameText, collapse = "; "))
            }
            return("Unknown Assignee")
          })
        } else { "Unknown Assignee" },
        
        AuthorAffiliations = Affiliations,
        Source = "Patent (USPTO ODP)",
        # 1. Bulletproof fallback stack: Grant -> Publication -> Application
        RawPubNum = dplyr::coalesce(
          safe_extract(., "applicationMetaData.patentNumber"),
          safe_extract(., "applicationMetaData.earliestPublicationNumber"),
          safe_extract(., "applicationNumberText") 
        ),
        
        # 2. Clean the string and generate URL
        URL = dplyr::case_when(
          !is.na(RawPubNum) ~ paste0("https://patents.google.com/patent/US", 
                                     stringr::str_remove(stringr::str_replace_all(RawPubNum, "[^a-zA-Z0-9]", ""), "^US")),
          TRUE ~ NA_character_
        ),
        EPMC_ID = NA_character_,
        CORE_ID = NA_character_,
        NCTId = NA_character_,
        Published_DOI_biorxiv = NA_character_
      )
  }, error = function(e) {
    message(sprintf("[USPTO ODP] Data mapping error: %s", e$message))
    return(NULL)
  })
  
  return(df)
}

# MANDATORY: Restore alias for downstream app backward compatibility
get_patentsview_data <- get_uspto_odp_data