library(httr)
library(jsonlite)
library(dplyr)
library(stringr)

retrieve_scopus_abstracts <- function(deduplicated_df, search_term = "DOI_lookup", api_key = NULL) {
  
  # 1. SETUP CREDENTIALS
  # Fallback to env if not passed
  valid_key <- if (!is.null(api_key)) api_key else Sys.getenv("ELSEVIER_API_KEY")
  
  if (valid_key == "") {
    warning("No Scopus API Key found. Skipping abstract retrieval.")
    return(NULL)
  }
  
  print("    > Starting Scopus Abstract Retrieval (View: META_ABS)")
  
  # Filter for records that need abstracts (Have DOI but Abstract is empty/NA)
  records_to_process <- deduplicated_df %>%
    filter(!is.na(DOI) & DOI != "" & (is.na(Abstract) | Abstract == ""))
  
  print(paste("    > Found", nrow(records_to_process), "records needing abstract lookup."))
  
  if (nrow(records_to_process) == 0) return(deduplicated_df)
  
  # 2. PARALLEL RETRIEVAL
  # Requests go out in batches of BATCH_SIZE at once, with each batch taking at
  # least 1 second, which keeps us under Elsevier's per-second throttle.
  # (Previously: one request at a time plus a 0.3s pause each, ~0.5s per record.)
  BATCH_SIZE <- 8
  dois <- unique(trimws(records_to_process$DOI))
  
  build_req <- function(doi) {
    httr2::request(paste0("https://api.elsevier.com/content/abstract/doi/", doi)) |>
      httr2::req_url_query(view = "META_ABS") |>
      httr2::req_headers(`X-ELS-APIKey` = valid_key, Accept = "application/json") |>
      httr2::req_timeout(30) |>
      httr2::req_error(is_error = function(resp) FALSE)  # we inspect status codes ourselves
  }
  
  abstracts <- list()  # doi -> abstract text
  
  # Fetch a set of DOIs in throttled parallel batches.
  # Returns the DOIs that should be retried (429 rate limit, 5xx, network errors).
  run_batches <- function(doi_vec) {
    retry <- character(0)
    batches <- split(doi_vec, ceiling(seq_along(doi_vec) / BATCH_SIZE))
    for (batch in batches) {
      t0 <- Sys.time()
      resps <- httr2::req_perform_parallel(lapply(batch, build_req),
                                           on_error = "continue", progress = FALSE)
      for (j in seq_along(batch)) {
        r <- resps[[j]]
        if (inherits(r, "error")) { retry <- c(retry, batch[j]); next }
        status <- httr2::resp_status(r)
        if (status == 200) {
          new_abstract <- tryCatch(
            httr2::resp_body_json(r)$`abstracts-retrieval-response`$coredata$`dc:description`,
            error = function(e) NULL  # silent fail on JSON structure changes
          )
          if (!is.null(new_abstract)) abstracts[[batch[j]]] <<- new_abstract
        } else if (status == 429 || status >= 500) {
          retry <- c(retry, batch[j])
        }
        # 404 / other client errors: no abstract available, skip
      }
      cat(".")
      elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
      if (elapsed < 1) Sys.sleep(1 - elapsed)
    }
    retry
  }
  
  pending <- run_batches(dois)
  attempt <- 1
  while (length(pending) > 0 && attempt <= 2) {
    wait_time <- 2^attempt
    print(paste0("    > ", length(pending), " requests rate-limited/failed. Pausing ", wait_time, "s, then retrying..."))
    Sys.sleep(wait_time)
    pending <- run_batches(pending)
    attempt <- attempt + 1
  }
  
  # 3. MATCH ABSTRACTS BACK TO ROWS
  if (length(abstracts) > 0) {
    row_dois <- trimws(deduplicated_df$DOI)
    hit <- !is.na(row_dois) & row_dois %in% names(abstracts)
    deduplicated_df$Abstract[hit] <- unlist(abstracts[row_dois[hit]], use.names = FALSE)
  }
  print(paste("    > Retrieved", length(abstracts), "of", length(dois), "abstracts."))
  
  cat("\n")
  print("    > Abstract retrieval complete.")
  return(deduplicated_df)
}