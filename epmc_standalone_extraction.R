library(tidyverse)
library(jsonlite)
library(httr)

# Helper for null coalescing
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

#' Fetch data from Europe PMC API (Pure Extraction - Memory Optimized)
#' 
#' @param search_term String: The query to send to EPMC
#' @param page_size Integer: Number of records per API page (max 1000 usually)
#' @param result_type String: "core" (full metadata) or "lite"
#' @param max_results Integer: Hard limit on total records to fetch
#' @return Dataframe of results or NULL
get_epmc_data <- function(search_term, page_size = 1000, result_type = "core", max_results = 10000) {
  
  print(paste("--- Starting EPMC Extraction for:", search_term, "---"))
  
  # --- OPTIMIZATION 1: Use a List for Batches ---
  # Creating an empty dataframe and growing it with bind_rows() 
  # is what caused the memory spike. Lists are cheap.
  all_batches_list <- list() 
  
  cursor_mark <- "*"
  total_fetched <- 0
  page <- 1
  
  while (total_fetched < max_results) {
    # 1. Construct API URL
    api_url <- paste0(
      "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=", URLencode(search_term, reserved = TRUE),
      "&format=json&pageSize=", page_size, 
      "&resultType=", result_type, 
      "&cursorMark=", URLencode(cursor_mark, reserved = TRUE)
    )
    
    print(paste("Fetching Page", page, "| Cursor:", cursor_mark))
    
    # 2. Make Request
    response <- tryCatch({ 
      GET(api_url) 
    }, error = function(e) { 
      print(paste("EPMC API Network Error:", e$message))
      return(NULL) 
    })
    
    if (is.null(response) || http_error(response)) { 
      print(paste("EPMC API Request Failed. Status:", http_status(response)$status_code))
      break 
    }
    
    # 3. Parse JSON
    json_content <- content(response, "text", encoding = "UTF-8")
    parsed_json <- tryCatch({ 
      fromJSON(json_content, flatten = TRUE) 
    }, error = function(e) { 
      print(paste("Error parsing JSON:", e$message))
      return(NULL) 
    })
    
    # 4. Check for Results
    if (is.null(parsed_json$resultList$result) || length(parsed_json$resultList$result) == 0) {
      print("EPMC API: No more results found.")
      break
    }
    
    # 5. Process This Page
    results_df <- as.data.frame(parsed_json$resultList$result, stringsAsFactors = FALSE)
    epmc_results_list <- list()
    
    for (i in 1:nrow(results_df)) {
      # --- Metadata Extraction ---
      epmc_id  <- results_df$id[i] %||% NA_character_
      doi      <- results_df$doi[i] %||% NA_character_
      title    <- results_df$title[i] %||% NA_character_
      abstract <- results_df$abstractText[i] %||% NA_character_
      pub_date <- results_df$firstPublicationDate[i] %||% NA_character_
      
      # URL Logic
      url <- if (!is.na(doi)) {
        paste0("https://doi.org/", doi)
      } else if (!is.null(results_df$source[i]) && !is.null(results_df$pmid[i])) {
        paste0("https://europepmc.org/article/", results_df$source[i], "/", results_df$pmid[i])
      } else {
        NA_character_
      }
      
      # --- Author & Affiliation Logic (Preserved) ---
      authors_text <- NA_character_
      author_affiliations_combined <- "[]" # Default empty JSON array
      author_list <- results_df$authorList.author[[i]]
      
      if (!is.null(author_list)) {
        if (is.data.frame(author_list)) {
          # Standardize author names
          authors_text <- paste(author_list$fullName, collapse = "; ")
          
          # Extract affiliations
          affiliations_list <- apply(author_list, 1, function(row) {
            aff_detail <- if (is.list(row) && "authorAffiliationDetailsList.authorAffiliation" %in% names(row)) {
              row$authorAffiliationDetailsList.authorAffiliation
            } else { NULL }
            
            affiliations <- list()
            if (!is.null(aff_detail)) {
              if (is.data.frame(aff_detail)) {
                affiliations <- as.list(aff_detail$affiliation)
              } else if (is.list(aff_detail)) {
                affiliations <- sapply(aff_detail, function(x) x$affiliation %||% NA_character_)
              } else if (is.character(aff_detail)) {
                affiliations <- as.list(aff_detail)
              }
            }
            return(paste(unlist(unique(Filter(function(x) !is.na(x) && x != "", affiliations))), collapse = "<br>"))
          })
          
          # Format for JSON
          aff_json_list <- lapply(affiliations_list, function(a) list(affiliations = a))
          author_affiliations_combined <- jsonlite::toJSON(aff_json_list, auto_unbox = TRUE)
          
        } else if (is.list(author_list)) {
          # Nested list case
          author_names <- sapply(author_list, function(author) author$fullName %||% NA_character_)
          authors_text <- paste(na.omit(author_names), collapse = "; ")
          
          aff_json_list <- lapply(author_list, function(author) {
            aff_detail <- author$authorAffiliationDetailsList$authorAffiliation
            author_affiliations <- character(0)
            if (!is.null(aff_detail)) {
              if (is.data.frame(aff_detail)) {
                author_affiliations <- unique(na.omit(aff_detail$affiliation))
              } else if (is.list(aff_detail)) {
                author_affiliations <- unique(na.omit(sapply(aff_detail, function(x) x$affiliation)))
              } else if (is.character(aff_detail)) {
                author_affiliations <- unique(na.omit(aff_detail))
              }
            }
            return(list(affiliations = paste(author_affiliations, collapse = "<br>")))
          })
          author_affiliations_combined <- jsonlite::toJSON(aff_json_list, auto_unbox = TRUE)
        }
      }
      
      # --- Build Row ---
      epmc_results_list[[length(epmc_results_list) + 1]] <- data.frame(
        EPMC_ID = epmc_id, 
        DOI = doi, 
        Title = title, 
        Abstract = abstract, 
        Authors = authors_text, 
        AuthorAffiliations = as.character(author_affiliations_combined), 
        PublicationDate = pub_date, 
        Source = "EPMC", 
        URL = url, 
        stringsAsFactors = FALSE
      )
    }
    
    # 6. Append to Master List (Optimization)
    if (length(epmc_results_list) > 0) {
      new_batch <- bind_rows(epmc_results_list)
      
      # --- OPTIMIZATION 2: Store batch, don't merge yet ---
      all_batches_list[[length(all_batches_list) + 1]] <- new_batch
      total_fetched <- total_fetched + nrow(new_batch)
    }
    
    # 7. Pagination Check
    cursor_mark <- parsed_json$nextCursorMark %||% ""
    if (cursor_mark == "") {
      print("EPMC API: Pagination complete.")
      break
    }
    page <- page + 1
    Sys.sleep(0.2) # Slight polite delay
  }
  
  # --- OPTIMIZATION 3: Final Merge ---
  # We do the expensive operation exactly once.
  if (length(all_batches_list) > 0) {
    print("Binding all EPMC batches...")
    all_results_df <- bind_rows(all_batches_list)
    print(paste("Total EPMC records fetched:", nrow(all_results_df)))
    return(head(all_results_df, max_results))
  } else {
    print("No records fetched.")
    return(data.frame())
  }
}