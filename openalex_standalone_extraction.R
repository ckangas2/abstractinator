library(tidyverse)
library(jsonlite)
library(httr)

# --- 1. THE DECOMPRESSOR (OPTIMIZED) ---
# Reconstructs the abstract from the inverted index using Base R vectors.
# preventing the "2 million tibbles" memory explosion.
reconstruct_abstract <- function(inverted_index) {
  if (is.null(inverted_index) || length(inverted_index) == 0) return(NA_character_)
  
  tryCatch({
    # 1. Create parallel vectors for Words and Positions
    # 'rep' repeats the word for however many positions it has
    words <- rep(names(inverted_index), lengths(inverted_index))
    
    # 'unlist' flattens the list of positions into a single vector
    positions <- unlist(inverted_index, use.names = FALSE)
    
    # 2. Sort by position
    # 'order' gives us the indices to sort the words correctly
    sorted_words <- words[order(positions)]
    
    # 3. Collapse into a string
    paste(sorted_words, collapse = " ")
    
  }, error = function(e) NA_character_)
}

# --- 2. THE NAVIGATOR (Affiliations) ---
extract_affiliations <- function(authorships_list) {
  if (is.null(authorships_list) || length(authorships_list) == 0) return("[]")
  
  # Use map to extract and then JSON encode
  aff_data <- map(authorships_list, function(entry) {
    insts <- entry$institutions
    if (!is.null(insts) && length(insts) > 0) {
      # Extract display_name safely
      vals <- vapply(insts, function(i) i$display_name %||% NA_character_, FUN.VALUE = character(1))
      return(vals[!is.na(vals)])
    } else {
      NA_character_
    }
  })
  
  toJSON(aff_data, auto_unbox = TRUE)
}

# --- 3. THE EXTRACTOR ---
get_openalex_data <- function(search_term, mailto = NULL, per_page = 200, max_results = 200) {
  
  print(paste("--- Starting Extraction for:", search_term, "---"))
  
  # CONTAINER: Use a list for batches
  all_batches <- list() 
  next_cursor <- "*"
  total_fetched <- 0
  base_url <- "https://api.openalex.org/works"
  
  # Polite Pool Logic
  is_polite <- !is.null(mailto) && nchar(mailto) > 0
  if (!is_polite) print("Note: No email provided. Running at limited speed.")
  
  while (total_fetched < max_results) {
    
    # Smart throttle: Don't fetch 200 if we only need 5 more
    remaining <- max_results - total_fetched
    this_page_size <- min(per_page, remaining)
    
    query_params <- list(
      search = search_term,
      filter = "has_abstract:true", 
      select = "id,doi,title,publication_date,authorships,ids,abstract_inverted_index",
      per_page = this_page_size, 
      cursor = next_cursor
    )
    if (is_polite) query_params$mailto <- mailto
    
    # Fetch
    resp <- tryCatch({ GET(base_url, query = query_params) }, error = function(e) NULL)
    
    if (is.null(resp) || status_code(resp) != 200) {
      if (!is.null(resp)) print(paste("API Error:", status_code(resp)))
      break
    }
    
    # Parse
    json_raw <- fromJSON(content(resp, "text", encoding = "UTF-8"), simplifyVector = FALSE)
    results <- json_raw$results
    if (length(results) == 0) break
    
    # Process Batch
    batch_tbl <- map_dfr(results, function(item) {
      
      # Optimized Author String
      auth_str <- NA_character_
      if (!is.null(item$authorships)) {
        # vapply is faster than map_chr
        auth_names <- vapply(item$authorships, function(a) a$author$display_name %||% NA_character_, character(1))
        auth_str <- paste(na.omit(auth_names), collapse = "; ")
      }
      
      tibble(
        EPMC_ID = NA_character_,
        DOI = item$doi %||% NA_character_,
        Title = item$title %||% NA_character_,
        Abstract = reconstruct_abstract(item$abstract_inverted_index), # <--- NEW FAST FUNCTION
        Authors = auth_str,
        AuthorAffiliations = as.character(extract_affiliations(item$authorships)), 
        PublicationDate = item$publication_date %||% NA_character_,
        Source = "OpenAlex",
        URL = (item$ids$openalex %||% item$doi) %||% NA_character_
      )
    })
    
    # Store Batch in List
    all_batches[[length(all_batches) + 1]] <- batch_tbl
    total_fetched <- total_fetched + nrow(batch_tbl)
    
    cat(sprintf("\rOpenAlex: %d / %d records fetched...", total_fetched, max_results))
    
    next_cursor <- json_raw$meta$next_cursor
    if (is.null(next_cursor)) break
    
    if (!is_polite) Sys.sleep(0.5) 
  }
  
  print(paste("\nOpenAlex Done. Total:", total_fetched))
  
  # Final Bind
  if (length(all_batches) > 0) {
    return(bind_rows(all_batches))
  } else {
    return(tibble())
  }
}