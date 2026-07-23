library(httr)
library(jsonlite)
library(dplyr)
library(stringr)

get_patentsview_data <- function(search_term, api_key = NULL, limit = 10) {
  
  # 1. API KEY LOGIC (Robust Fallback)
  if (is.null(api_key)) api_key <- Sys.getenv("USPTO_API_KEY")
  
  # Fail fast if key is missing/short
  if (nchar(api_key) < 10) {
    if (exists("key") && nchar(get("key")) > 10) {
      api_key <- get("key") # Fallback to global var for your session
    } else {
      print("[PatentsView] Error: No valid API Key found.")
      return(NULL)
    }
  }
  
  url <- "https://search.patentsview.org/api/v1/patent/"
  
  # 2. QUERY (With Assignees)
  query_body <- list(
    q = list(
      "_or" = list(
        list("_text_phrase" = list("patent_title" = search_term)),
        list("_text_phrase" = list("patent_abstract" = search_term))
      )
    ),
    f = c("patent_id", "patent_title", "patent_abstract", "patent_date", "inventors", "assignees"),
    o = list(size = limit)
  )
  
  # 3. FETCH
  print(paste0("    > [PatentsView] Searching for: ", search_term))
  resp <- tryCatch({
    POST(url, 
         body = query_body, 
         encode = "json",
         add_headers("X-Api-Key" = api_key, "Accept" = "application/json"),
         timeout(20))
  }, error = function(e) return(NULL))
  
  if (is.null(resp) || status_code(resp) != 200) return(NULL)
  
  json <- fromJSON(content(resp, "text", encoding = "UTF-8"))
  if (json$count == 0) return(NULL)
  
  patents_df <- as_tibble(json$patents)
  
  # 4. DEFENSIVE PARSING
  df <- tryCatch({
    patents_df %>%
      transmute(
        DOI = as.character(patent_id),
        Title = as.character(patent_title),
        Abstract = as.character(patent_abstract),
        PublicationDate = as.character(patent_date),
        
        Authors = sapply(inventors, function(x) {
          if (is.null(x) || length(x) == 0) return("Unknown")
          if (is.data.frame(x)) {
            paste(paste(x$inventor_name_first, x$inventor_name_last), collapse = "; ")
          } else { "Multiple Inventors" }
        }),
        
        Affiliations = if ("assignees" %in% names(.)) {
          sapply(assignees, function(x) {
            if (is.null(x) || length(x) == 0) return("Unknown Assignee")
            org <- if("assignee_organization" %in% names(x)) x$assignee_organization else NA
            last <- if("assignee_name_last" %in% names(x)) x$assignee_name_last else NA
            org <- org[!is.na(org)]
            if (length(org) > 0) return(paste(org, collapse = "; "))
            last <- last[!is.na(last)]
            if (length(last) > 0) return(paste(last, collapse = "; "))
            return("Unknown Assignee")
          })
        } else { NA_character_ },
        
        AuthorAffiliations = Affiliations,
        Source = "Patent (USPTO)",
        URL = paste0("https://patents.google.com/patent/US", patent_id),
        EPMC_ID = NA_character_,
        CORE_ID = NA_character_,
        NCTId = NA_character_,
        Published_DOI_biorxiv = NA_character_
      )
  }, error = function(e) {
    print(paste("[PatentsView] Parsing Error:", e$message))
    return(NULL)
  })
  
  return(df)
}