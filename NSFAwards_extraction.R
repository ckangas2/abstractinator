library(tidyverse)
library(jsonlite)
library(httr)

# ---- NSF keyword construction -------------------------------------------
# research.gov's `keyword` parameter defaults to OR across terms. Verified
# against the live endpoint 2026-10-19:
#
#   Listeria immunity         -> totalCount 1607, matching "immunity" alone
#   Listeria OR immunity      -> totalCount 1607  (identical: bare == OR)
#   Listeria AND immunity     -> totalCount 1
#   Listeria NOT immunity     -> totalCount 33    (1 + 33 = all 34 Listeria awards)
#
# The documented AND/OR/NOT operators work correctly, so we AND every term the
# user typed -- that is what killed the algebraic-geometry and squid-swimming
# awards that were matching on "cell" and "immunity" alone.
#
# AND is frequently and correctly strict: a four-term AND on a narrow topic
# legitimately returns zero. Rather than silently returning nothing, we walk a
# deterministic ladder from all-terms down to one and take the first tier with
# any hits, logging which tier won.
#
# NOTE: record count lives at response$metadata$totalCount. The previous code
# read response$totalRecords, which does not exist -- it always coerced to 0,
# so the "all available records captured" exit never fired and NSF paginated
# to max_results regardless of how few real matches there were.
# NOTE: printFields is documented as "no longer functional"; the API ignores it.

NSF_API_BASE <- "https://www.research.gov/awardapi-service/v1/awards.json"

# Words with no discriminative power inside an AND -- dropped so they cannot
# turn a good query into a zero-result one. This is not a guess at which of
# your words matter; every content word is kept and required.
NSF_STOPWORDS <- c("the", "and", "for", "with", "from", "into", "that", "this",
                   "their", "its", "via", "using", "about", "between", "during",
                   "toward", "towards", "are", "was", "were", "has", "have",
                   "been", "how", "why", "does", "not", "but",
                   "to", "of", "in", "on", "at", "by", "as", "an", "or", "if",
                   "is", "be", "it", "we", "us", "our", "than", "then")

nsf_tokenize <- function(search_term) {
  t <- trimws(search_term)
  if (!nzchar(t)) return(character(0))
  # Preserve caller-supplied "quoted phrases" as single AND operands.
  phrases <- regmatches(t, gregexpr('"[^"]+"', t))[[1]]
  rest <- gsub('"[^"]+"', " ", t)
  toks <- unlist(strsplit(rest, "[^[:alnum:]'-]+"))
  toks <- toks[nzchar(toks)]
  toks <- toks[nchar(toks) >= 2L & !tolower(toks) %in% NSF_STOPWORDS]
  c(phrases, toks)
}

# Most specific first: all terms ANDed, then drop the trailing term, etc.
nsf_keyword_ladder <- function(search_term) {
  toks <- nsf_tokenize(search_term)
  if (length(toks) == 0L) return(trimws(search_term))
  unique(vapply(rev(seq_along(toks)),
                function(n) paste(toks[seq_len(n)], collapse = " AND "),
                character(1)))
}

# One cheap rpp=1 request to read totalCount for a candidate keyword.
nsf_count_for <- function(keyword) {
  u <- paste0(NSF_API_BASE, "?keyword=", URLencode(keyword, reserved = TRUE),
              "&rpp=1&offset=0")
  r <- tryCatch(httr::GET(u, httr::timeout(15)), error = function(e) NULL)
  if (is.null(r) || httr::http_error(r)) return(NA_integer_)
  j <- tryCatch(jsonlite::fromJSON(httr::content(r, "text", encoding = "UTF-8"),
                                   flatten = FALSE),
                error = function(e) NULL)
  n <- j$response$metadata$totalCount
  if (is.null(n) || length(n) == 0L) return(NA_integer_)
  suppressWarnings(as.integer(n))
}

nsf_resolve_keyword <- function(search_term, verbose = TRUE) {
  cands <- nsf_keyword_ladder(search_term)
  for (cand in cands) {
    n <- nsf_count_for(cand)
    if (verbose) cat(sprintf("  [NSF KEY] %-55s -> %s\n", cand,
                             if (is.na(n)) "request failed" else n))
    if (!is.na(n) && n > 0L) return(cand)
    Sys.sleep(0.3)
  }
  utils::tail(cands, 1)
}

get_all_nsf_awards_baseR_v2 <- function(search_term, rows_per_page = 25, max_results = 100, print_fields = NULL) {
  
  # Accumulator list is O(n) vs rbind's O(n^2) performance
  results_accumulator <- list() 
  offset <- 0
  total_fetched <- 0
  
  cat(sprintf("\n[NSF START] Query: '%s' | Target: %d\n", search_term, max_results))

  search_key <- nsf_resolve_keyword(search_term)
  if (!identical(search_key, search_term)) {
    cat(sprintf("[NSF KEY] Using: %s
", search_key))
  }
  
  # Using repeat to avoid NA logical errors in while()
  repeat {
    # 1. Build URL
    api_url <- paste0(
      "https://www.research.gov/awardapi-service/v1/awards.json?",
      "keyword=", URLencode(search_key, reserved = TRUE),
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
    raw_total <- parsed_json$response$metadata$totalCount
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