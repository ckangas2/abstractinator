library(arrow)
library(dplyr)
library(stringr)
# aws.s3 removed: Fully self-custodied local execution

# ==============================================================================
# bioRxiv / medRxiv Extraction - Local Partitioned Parquet
# Target: 'biorxiv_local_db' directory
# ==============================================================================

# Split a search into the pieces that must all match:
#   'IL-2 (CD25)'                -> "IL-2", "CD25"
#   '"oncolytic virus" melanoma' -> "oncolytic virus", "melanoma"
biorxiv_query_terms <- function(search_term) {
  phrases <- regmatches(search_term, gregexpr('"[^"]+"', search_term))[[1]]
  rest <- search_term
  for (ph in phrases) rest <- sub(ph, " ", rest, fixed = TRUE)
  phrases <- gsub('"', "", phrases)
  words <- strsplit(trimws(rest), "[[:space:]]+")[[1]]
  # strip surrounding brackets/quotes/punctuation from each word
  words <- gsub("^[][(){}\"',;:]+|[][(){}\"',;:]+$", "", words)
  words <- words[nzchar(words) & !toupper(words) %in% c("AND", "OR", "NOT")]
  terms <- unique(trimws(c(phrases, words)))
  head(terms[nzchar(terms)], 8)
}

get_biorxiv_data <- function(search_term, limit = 500) {
  
  # Defensive Input Validation
  stopifnot(
    "Search term must be a valid string" = is.character(search_term) && nchar(trimws(search_term)) > 0,
    "Limit must be numeric and positive" = is.numeric(limit) && limit > 0
  )
  
  print(paste0("    > [bioRxiv] Lazy Searching Local Parquet Directory for: ", search_term))
  
  # Map to the new local partitioned directory structure
  local_db_path <- "biorxiv_local_db"
  
  if (!dir.exists(local_db_path)) {
    print(paste("    > [bioRxiv] Error: Local database directory '", local_db_path, "' does not exist."))
    return(NULL)
  }
  
  # 1. MOUNT DATASET (Out-of-core memory mapping)
  ds <- tryCatch({
    arrow::open_dataset(local_db_path, format = "parquet")
  }, error = function(e) {
    print(paste("    > [bioRxiv] Mounting Failed:", e$message))
    return(NULL)
  })
  
  if (is.null(ds)) return(NULL)
  
  # 2. EXECUTE LAZY QUERY
  # Behave like the other databases: every word must appear (in the title or the
  # abstract), "quoted phrases" stay together, and AND/OR/NOT and brackets are
  # ignored. Matching is literal (fixed = TRUE), so ( ) + ? never act as syntax.
  # Arrow runs these filters natively in C++, so the data stays out of RAM.
  terms <- biorxiv_query_terms(search_term)
  if (length(terms) == 0) return(NULL)
  
  tryCatch({
    q <- ds %>%
      select(DOI, Title, Abstract, Authors, Affiliations, PublicationDate, Source, URL, Published_DOI)
    for (term in terms) {
      q <- q %>% filter(
        grepl(term, Title, ignore.case = TRUE, fixed = TRUE) |
          grepl(term, Abstract, ignore.case = TRUE, fixed = TRUE)
      )
    }
    hits_df <- q %>%
      head(limit) %>% 
      collect() # <--- Data enters active RAM only here
    
    if (nrow(hits_df) == 0) return(NULL)
    
    print(paste0("    > [bioRxiv] Found ", nrow(hits_df), " raw hits."))
    
    # 3. SCHEMA MAPPING
    final_df <- hits_df %>%
      mutate(
        Published_DOI_biorxiv = as.character(Published_DOI), 
        PublicationDate = as.character(PublicationDate),
        Authors = as.character(Authors),
        AuthorAffiliations = if("Affiliations" %in% names(.)) as.character(Affiliations) else NA_character_,
        
        EPMC_ID = NA_character_,
        CORE_ID = NA_character_,
        NCTId = NA_character_
      ) %>%
      select(-Published_DOI) # Clean up temporary column
    
    return(final_df)
    
  }, error = function(e) {
    print(paste("    > [bioRxiv] Stream Error:", e$message))
    return(NULL)
  })
}