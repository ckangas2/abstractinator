# NIH and NSF extractors for the Abstractinator pipeline
# No plotting logic included

library(dplyr)
library(httr)
library(jsonlite)
library(stringr)

# === NIH Reporter ===
get_nih_reporter_data <- function(search_term, desired_results = 300) {
  api_url <- "https://api.reporter.nih.gov/v2/projects/search"
  limit <- 100
  offset <- 0
  results_accumulator <- list()
  
  search_term <- enc2utf8(tolower(search_term))
  
  message(sprintf("--- NIH RePORTER: Searching for '%s' ---", search_term))
  
  repeat {
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
    
    response <- tryCatch({
      httr::POST(
        url = api_url,
        body = jsonlite::toJSON(request_body, auto_unbox = TRUE),
        encode = "json",
        timeout(10),
        add_headers("Content-Type" = "application/json", "Accept" = "application/json")
      )
    }, error = function(e) {
      warning(paste("NIH API Error:", e$message))
      return(NULL)
    })
    
    if (is.null(response) || httr::http_error(response)) {
      warning(sprintf("NIH request failed at offset %d", offset))
      break
    }
    
    content_text <- httr::content(response, "text", encoding = "UTF-8")
    parsed_json <- jsonlite::fromJSON(content_text, flatten = TRUE)
    
    if (is.null(parsed_json$results)) {
      message("NIH: No results found")
      break
    }
    
    results_df <- parsed_json$results
    
    if (nrow(results_df) > 0) {
      results_accumulator[[length(results_accumulator) + 1]] <- results_df
    }
    
    total_available <- parsed_json$meta$total
    current_count <- sum(sapply(results_accumulator, nrow))
    
    message(sprintf("NIH: Fetched %d / %d records", current_count, min(total_available, desired_results)))
    
    offset <- offset + limit
    
    if (current_count >= desired_results || offset >= total_available) {
      break
    }
    
    Sys.sleep(1.0)
  }
  
  if (length(results_accumulator) == 0) {
    return(data.frame())
  }
  
  final_df <- dplyr::bind_rows(results_accumulator)
  
  # Normalize to Abstractinator schema
  final_df <- final_df %>%
    mutate(
      Title = projectTitle %||% title,
      Abstract = abstractText %||% description,
      Authors = piName %||% piNames %||% pdPIName,
      Source = "NIH",
      URL = paste0("https://reporter.nih.gov/project-details/", projectId),
      PublicationDate = format(as.Date(projectStartDate, "%Y%m%d"), "%Y-%m-%d"),
      has_nih = TRUE
    ) %>%
    select(Title, Abstract, Authors, Source, URL, PublicationDate, has_nih, projectId, piName, pdPIName, orgName, directCostsAmt, totalCostsAmt)
  
  return(final_df)
}

# === NSF Awards ===
get_nsf_awards_data <- function(search_term, max_results = 100) {
  api_url <- paste0(
    "https://www.research.gov/awardapi-service/v1/awards.json?",
    "keyword=", URLencode(search_term),
    "&rpp=25",
    "&offset=0"
  )
  
  all_awards_df <- NULL
  offset <- 0
  total_fetched <- 0
  
  message(sprintf("--- NSF: Searching for '%s' ---", search_term))
  
  while (total_fetched < max_results) {
    url <- paste0(
      api_url,
      "&rpp=25",
      "&offset=", offset
    )
    
    response <- tryCatch({ GET(url) }, error = function(e) {
      message(paste("NSF API Error:", e$message))
      return(NULL)
    })
    
    if (is.null(response) || http_error(response)) {
      message("NSF: Request failed")
      break
    }
    
    json_content <- content(response, "text", encoding = "UTF-8")
    parsed_json <- tryCatch({ fromJSON(json_content, flatten = FALSE) }, error = function(e) {
      message(paste("NSF: JSON parse error:", e$message))
      return(NULL)
    })
    
    if (is.null(parsed_json) || is.null(parsed_json$response$award)) {
      message("NSF: No awards found")
      break
    }
    
    awards_df_page <- parsed_json$response$award
    
    if (is.data.frame(awards_df_page)) {
      if (is.null(all_awards_df)) {
        all_awards_df <- awards_df_page
      } else {
        all_awards_df <- bind_rows(all_awards_df, awards_df_page)
      }
      total_fetched <- nrow(all_awards_df)
      message(sprintf("NSF: Fetched %d records", total_fetched))
      
      if (total_fetched >= max_results) break
      
      offset <- offset + 25
      Sys.sleep(1)
      
      if (nrow(awards_df_page) < 25) break
    } else {
      message("NSF: Response not a dataframe")
      break
    }
  }
  
  if (is.null(all_awards_df) || nrow(all_awards_df) == 0) {
    return(data.frame())
  }
  
  # Normalize to Abstractinator schema
  # Check column names to handle potential variations
  col_names <- names(all_awards_df)
  message(sprintf("NSF columns: %s", paste(col_names, collapse = ", ")))
  
  final_df <- all_awards_df %>%
    mutate(
      Title = title %||% "No title",
      Abstract = abstractText %||% "" %||% "",
      Authors = paste(pdPIName %||% "", collapse = "; "),
      Source = "NSF",
      URL = paste0("https://www.nsf.gov/awardsearch/showAward?AWD_ID=", `id` %||% awdID %||% awardID %||% "Unknown"),
      PublicationDate = format(as.Date(date, "%Y%m%d"), "%Y-%m-%d"),
      has_nsf = TRUE
    ) %>%
    select(Title, Abstract, Authors, Source, URL, PublicationDate, has_nsf, `id` %||% awdID %||% awardID %||% NA_character_, awardAmt, awardeeName, programElement)
  
  return(final_df)
}
