library(httr)
library(jsonlite)
library(dplyr)
library(purrr)

get_clinical_trials_data <- function(search_term, limit = 10000) {
  
  api_url <- "https://clinicaltrials.gov/api/v2/studies"
  print(paste0("clinicaltrials.gov: Searching for '", search_term, "' (Target Limit: ", limit, ")..."))
  
  all_studies_list <- list() # Store batches here
  next_token <- NULL         # The cursor
  total_fetched <- 0
  page_size_max <- 1000      # API Limit is usually 1000
  
  # --- THE PAGINATION LOOP ---
  while (total_fetched < limit) {
    
    # 1. Calculate safe page size (don't over-fetch on the last batch)
    remaining_needed <- limit - total_fetched
    current_page_size <- min(page_size_max, remaining_needed)
    
    # 2. Construct Query
    query_params <- list(
      format = "json",
      markupFormat = "markdown",
      `query.term` = search_term,
      countTotal = "true",
      pageSize = current_page_size
    )
    
    # Add token if this isn't the first loop
    if (!is.null(next_token)) {
      query_params$pageToken <- next_token
    }
    
    # 3. Fetch Data
    # We use tryCatch to prevent one bad page from crashing the whole pipeline
    response <- tryCatch({
      GET(url = api_url, query = query_params, add_headers(`accept` = "application/json"))
    }, error = function(e) NULL)
    
    if (is.null(response) || http_status(response)$category != "Success") {
      warning(paste("clinicaltrials.gov API Error on batch:", http_status(response)$message))
      break
    }
    
    # 4. Parse JSON
    api_data_raw <- content(response, "text", encoding = "UTF-8")
    api_data_parsed <- fromJSON(api_data_raw)
    
    # 5. Check if studies exist in this batch
    if (is.null(api_data_parsed$studies) || nrow(api_data_parsed$studies) == 0) {
      break # No more data
    }
    
    studies_chunk <- api_data_parsed$studies
    
    # --- DATA EXTRACTION LOGIC (Vectorized for the Batch) ---
    # We extract columns safely using standard dplyr/base vectors
    
    # Helper to safely extract vector or return NAs of correct length
    safe_extract <- function(data, path_vec) {
      # This is a simplification; for deep JSON, vectors are safest
      # But since we have the dataframe 'studies_chunk', we access columns directly
      return(NULL) 
    }
    
    # Direct column access is safer than the deep list indexing
    # Note: jsonlite flattens these into a dataframe structure
    
    nct_ids <- studies_chunk$protocolSection$identificationModule$nctId
    official_titles <- studies_chunk$protocolSection$identificationModule$officialTitle
    brief_summaries <- studies_chunk$protocolSection$descriptionModule$briefSummary
    detailed_descriptions <- studies_chunk$protocolSection$descriptionModule$detailedDescription
    start_dates <- studies_chunk$protocolSection$statusModule$studyFirstPostDateStruct$date
    completion_dates <- studies_chunk$protocolSection$statusModule$completionDateStruct$date
    overall_statuses <- studies_chunk$protocolSection$statusModule$overallStatus
    
    # Process Row-by-Row for this batch
    batch_df <- map_dfr(1:nrow(studies_chunk), function(i) {
      
      # Extract IDs
      id_val <- if (!is.null(nct_ids[i])) as.character(nct_ids[i]) else NA_character_
      url_val <- paste0("https://clinicaltrials.gov/study/", id_val)
      
      # Title
      title_raw <- if (!is.null(official_titles[i])) as.character(official_titles[i]) else "Untitled Study"
      title_linked <- paste0("[", title_raw, "](", url_val, ")")
      
      # Abstract
      bs <- if (!is.null(brief_summaries[i])) brief_summaries[i] else ""
      dd <- if (!is.null(detailed_descriptions[i])) detailed_descriptions[i] else ""
      abs_text <- trimws(paste(bs, dd, sep = " "))
      if (nchar(abs_text) == 0) abs_text <- NA_character_
      
      # Authors / Sponsor
      # Navigating the nested lists for this specific row
      protocol <- studies_chunk$protocolSection[i, ]
      
      lead_sponsor_name <- NA_character_
      # Deep dive for sponsor
      try({
        lead_sponsor_name <- protocol$sponsorCollaboratorsModule$leadSponsor$name
      }, silent = TRUE)
      
      # Officials
      officials_name <- NA_character_
      try({
        # Check if overallOfficials exists and is a dataframe/list
        offs <- protocol$contactsLocationsModule$overallOfficials[[1]]
        if (!is.null(offs) && "name" %in% names(offs)) {
          officials_name <- paste(offs$name, collapse = "; ")
        }
      }, silent = TRUE)
      
      final_authors <- if (!is.na(officials_name) && nchar(officials_name) > 0) officials_name else lead_sponsor_name
      if (is.null(final_authors)) final_authors <- NA_character_
      
      # Dates & Status
      s_date <- if (!is.null(start_dates[i])) start_dates[i] else NA_character_
      c_date <- if (!is.null(completion_dates[i])) completion_dates[i] else NA_character_
      stat   <- if (!is.null(overall_statuses[i])) overall_statuses[i] else NA_character_
      
      # Format Status String
      is_active <- grepl("Active|Recruiting|Enrolling", stat, ignore.case = TRUE)
      end_text <- if (isTRUE(is_active)) "End: Ongoing" else paste0("End: ", c_date)
      
      pub_date_str <- paste(
        ifelse(is.na(s_date), "", paste0("Start: ", s_date)),
        ifelse(is.na(end_text), "", end_text),
        ifelse(is.na(stat), "", paste0("Status: ", stat)),
        sep = " | "
      )
      
      # Build Tibble
      tibble(
        Title = title_linked,
        Abstract = abs_text,
        Authors = as.character(final_authors),
        Affiliations = NA_character_, # Difficult to extract consistently from CT.gov
        PublicationDate = pub_date_str,
        URL = url_val,
        NCTId = id_val,
        AdverseEvents = NA_character_, # Keeping simple for speed
        SeriousAdverseEvents = NA_character_,
        Source = "clinicaltrials.gov"
      )
    })
    
    # 6. Append Batch
    all_studies_list[[length(all_studies_list) + 1]] <- batch_df
    total_fetched <- total_fetched + nrow(batch_df)
    
    print(paste("    > CT.gov Batch: Fetched", total_fetched, "records..."))
    
    # 7. Advance Cursor
    next_token <- api_data_parsed$nextPageToken
    
    # If no next token, we are done
    if (is.null(next_token)) {
      break
    }
    
    # Polite sleep
    Sys.sleep(0.2)
  }
  
  # --- FINALIZE ---
  if (length(all_studies_list) > 0) {
    final_df <- bind_rows(all_studies_list)
    print(paste("clinicaltrials.gov: Total retrieved:", nrow(final_df)))
    return(final_df)
  } else {
    print("clinicaltrials.gov: No studies found.")
    return(NULL)
  }
}