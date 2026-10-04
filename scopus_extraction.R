library(httr)
library(jsonlite)
library(dplyr)



call_scopus_api <- function(query_params = list(), api_key = NULL) {
  
  # 1. Fallback Logic: If no key passed, try the system environment
  valid_key <- if (!is.null(api_key)) api_key else Sys.getenv("ELSEVIER_API_KEY")
  
  # 2. Safety Gate
  if (valid_key == "") {
    warning("No Scopus API Key found. Skipping extraction.")
    return(NULL)
  }
  
  print(paste("    > Querying Scopus for:", search_term))
  
  base_url <- "https://api.elsevier.com/content/search/scopus"
  
  
  headers <- c("X-ELS-APIKey" = valid_key, "Accept" = "application/json")
  response <- GET(base_url, query = query_params, add_headers(headers))
  
  if (http_error(response)) {
    stop(
      sprintf(
        "Scopus API request failed [%s]\n%s\n<%s>",
        status_code(response),
        content(response, "text"),
        response$url
      ),
      call. = FALSE
    )
  }
  
  data <- content(response, "text")
  parsed_data <- fromJSON(data, flatten = FALSE)
  return(parsed_data)
}

get_scopus_data <- function(search_term, max_records = limit, batch_size = 25, api_key = NULL) {
  
  # Fallback Logic
  valid_key <- if (!is.null(api_key)) api_key else Sys.getenv("ELSEVIER_API_KEY")
  
  if (valid_key == "") {
    warning("No Scopus API Key found. Skipping extraction.")
    return(NULL)
  }
  
  
  base_url <- "https://api.elsevier.com/content/search/scopus"
  
  all_extracted_data <- data.frame()
  start_index <- 0
  total_records_extracted <- 0
  doi_base_url <- "https://doi.org/"
  
  while (total_records_extracted < max_records) {
    print(paste("Fetching batch starting from index:", start_index))
    
    query_params <- list(
      query = search_term,
      view = "STANDARD",
      count = batch_size,
      start = start_index
    )
    
    scopus_data <- tryCatch(
      call_scopus_api(query_params, api_key = valid_key),
      error = function(e) {
        warning(paste("API call failed:", e$message))
        return(NULL)
      }
    )
    
    if (is.null(scopus_data) || !("search-results" %in% names(scopus_data)) || is.null(scopus_data$`search-results`$entry)) {
      print("No results or error in this batch. Stopping pagination.")
      break
    }
    
    entries_df <- scopus_data$`search-results`$entry
    
    extracted_batch_list <- list()
    for (i in 1:nrow(entries_df)) {
      entry <- entries_df[i, ]
      doi <- ifelse(!is.null(entry$`prism:doi`), as.character(entry$`prism:doi`), NA_character_)
      title <- ifelse(!is.null(entry$`dc:title`), as.character(entry$`dc:title`), NA_character_)
      published_date <- ifelse(!is.null(entry$`prism:coverDate`), as.character(entry$`prism:coverDate`), NA_character_)
      url <- ifelse(!is.na(doi), paste0(doi_base_url, doi), NA_character_)
      
      extracted_batch_list[[i]] <- data.frame(
        DOI = doi,
        Title = title,
        Abstract = NA_character_,
        Authors = NA_character_,
        Affiliations = "Not Available",
        PublicationDate = published_date,
        Source = "Scopus",
        URL = url,
        stringsAsFactors = FALSE
      )
    }
    extracted_batch <- bind_rows(extracted_batch_list)
    
    if (nrow(extracted_batch) > 0) {
      all_extracted_data <- bind_rows(all_extracted_data, extracted_batch)
      total_records_extracted <- nrow(all_extracted_data)
      print(paste("Extracted", nrow(extracted_batch), "records in this batch. Total:", total_records_extracted))
    }
    
    start_index <- start_index + batch_size
    
    if (!is.null(scopus_data$`search-results`$`opensearch:totalResults`)) {
      total_available_results <- as.numeric(scopus_data$`search-results`$`opensearch:totalResults`)
      if (total_records_extracted >= total_available_results) {
        print("Reached the total number of available results.")
        break
      }
    } else if (nrow(extracted_batch) < batch_size) {
      print("Fewer records returned than requested, assuming end of results.")
      break
    }
    
    if (total_records_extracted >= max_records) {
      print(paste("Reached the maximum number of records specified:", max_records))
      break
    }
    
    Sys.sleep(0.15) # Be mindful of rate limits
  }
  
  print(paste("Total records extracted:", nrow(all_extracted_data)))
  # In scopus_extraction.R, at the end of get_scopus_data:
  print(paste("--- get_scopus_data finished. Total rows returned:", nrow(all_extracted_data)))
  return(all_extracted_data)
}

# Example usage (you can uncomment this to test):
# search_term <- "talimogene laherparepvec"
# scopus_data_for_orchestrate <- get_scopus_data(search_term, max_records = 10, batch_size = 25)
# print(head(scopus_data_for_orchestrate))