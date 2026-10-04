library(tidyverse)
library(jsonlite)
library(httr)

get_all_nsf_awards_baseR_v2 <- function(search_term, rows_per_page = 25, max_results = 100, print_fields = NULL) {
  
  # Accumulator list is O(n) vs rbind's O(n^2) performance
  results_accumulator <- list() 
  offset <- 0
  total_fetched <- 0
  
  cat(sprintf("\n[NSF START] Query: '%s' | Target: %d\n", search_term, max_results))
  
  # Using repeat to avoid NA logical errors in while()
  repeat {
    # 1. Build URL
    api_url <- paste0(
      "https://www.research.gov/awardapi-service/v1/awards.json?",
      "keyword=", URLencode(search_term, reserved = TRUE),
      "&rpp=", as.character(rows_per_page),
      "&offset=", as.character(offset)
    )
    
    if (!is.null(print_fields)) {
      # Ensure 'url' isn't in print_fields as it triggers API rejection
      clean_fields <- gsub(",url", "", print_fields)
      api_url <- paste0(api_url, "&printFields=", URLencode(clean_fields))
    }
    
    # 2. Execute Request
    response <- tryCatch({ 
      httr::GET(api_url, httr::timeout(15)) 
    }, error = function(e) { 
      cat(sprintf("  > Offset %d: Network Error (%s)\n", offset, e$message))
      return(NULL) 
    })
    
    if (is.null(response) || httr::http_error(response)) break
    
    # 3. Parse JSON
    raw_content <- httr::content(response, "text", encoding = "UTF-8")
    parsed_json <- jsonlite::fromJSON(raw_content, flatten = FALSE)
    
    # 4. Extract Data & Metadata
    # Use null-coalescing to prevent NA comparison crashes
    raw_total <- parsed_json$response$totalRecords
    total_avail <- as.numeric(ifelse(is.null(raw_total) || is.na(raw_total), 0, raw_total))
    
    awards_df_page <- parsed_json$response$award
    
    if (is.data.frame(awards_df_page) && nrow(awards_df_page) > 0) {
      page_n <- nrow(awards_df_page)
      results_accumulator[[length(results_accumulator) + 1]] <- awards_df_page
      total_fetched <- total_fetched + page_n
      
      cat(sprintf("  > Offset %d: Fetched %d | Total Available: %d\n", 
                  offset, total_fetched, total_avail))
      
      # 5. Exit Triggers
      if (total_fetched >= max_results) {
        cat("  > Reached max_results limit.\n")
        break
      }
      if (total_fetched >= total_avail && total_avail > 0) {
        cat("  > All available records captured.\n")
        break
      }
      
      offset <- offset + rows_per_page
      Sys.sleep(0.5) # Rate limit respect
    } else {
      cat("  > No more data returned.\n")
      break 
    }
  }
  
  # 6. Final Tidy Binding
  if (length(results_accumulator) > 0) {
    # bind_rows handles the 62 vs 64 column mismatch gracefully
    final_df <- dplyr::bind_rows(results_accumulator)
    cat(sprintf("[NSF DONE] Successfully extracted %d records.\n\n", nrow(final_df)))
    return(final_df)
  } else {
    cat("[NSF DONE] Zero records found.\n\n")
    return(data.frame()) 
  }
}



# # Example usage:
# search_term_nsf <- '"oncolytic virus"'
# selected_fields <- "title,abstractText,awardeeName,pdPIName,date,fundsObligatedAmt"
# all_nsf_df_baseR_v2 <- get_all_nsf_awards_baseR_v2(search_term_nsf, rows_per_page = 25, max_results = 100, print_fields = selected_fields)
# 
# if (!is.null(all_nsf_df_baseR_v2)) {
#   print("Head of All NSF Award Data (using base R rbind v2):")
#   print(head(all_nsf_df_baseR_v2))
#   print(paste("Number of rows:", nrow(all_nsf_df_baseR_v2)))
# }