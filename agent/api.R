# agent/api.R
# REST API for AI agents and scripts. Wraps the same search engine as the website.
# Run from the repo root (see agent/run_api.R); listens on 127.0.0.1 only.

library(plumber)
library(future)
library(dplyr)

Sys.setenv(INTEGRATE_NIH_NSF = "1")
plan(multisession, workers = 8)

# plumber switches into agent/ while loading this file, so go back to the
# repo root (passed in by run_api.R) before loading the engine. Relative paths
# like biorxiv_local_db/ and .cache/ then resolve exactly as they do for app.R.
ROOT <- getOption("abstractinator.root", normalizePath(".."))
setwd(ROOT)

# Same engine + cache as app.R
for (f in c("epmc_standalone_extraction.R", "CORE_extraction.R",
            "clinicaltrials.gov_extraction.R", "scopus_extraction.R",
            "biorxiv_extraction.R", "patentsview_extraction.R", "deduplication.R",
            "scopus_abstract_extraction.R", "R/db_utils_local.R",
            "openalex_standalone_extraction.R", "aliases.R",
            "orchestrate_extraction.R", "NIHReporter_extraction.R",
            "NSFAwards_extraction.R")) {
  source(f)
}

# Use an absolute cache path so the cache works no matter what directory
# plumber is in (it switches into agent/ while serving requests).
assign("CACHE_DIR", file.path(ROOT, ".cache", "s3_mimic"), envir = globalenv())
dir.create(get("CACHE_DIR", envir = globalenv()), recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

MAX_RETURN         <- 100L  # most results one call can return
MAX_QUERY_CHARS    <- 200L
SEARCHES_PER_MIN   <- 20L   # server-wide cap, protects the machine and upstream APIs
.recent_searches   <- numeric(0)

#* Run every request from the repo root, and rate-limit /search
#* @filter root_and_rate_limit
function(req, res) {
  # plumber serves requests from agent/; switch back so relative paths
  # (biorxiv_local_db/, background workers started on first search) resolve
  # exactly as they do for the website.
  if (!identical(getwd(), ROOT)) setwd(ROOT)
  if (!identical(req$PATH_INFO, "/search")) return(forward())
  now <- as.numeric(Sys.time())
  .recent_searches <<- .recent_searches[.recent_searches > now - 60]
  if (length(.recent_searches) >= SEARCHES_PER_MIN) {
    res$status <- 429
    return(list(error = "Rate limit reached. Please wait a minute and try again."))
  }
  .recent_searches <<- c(.recent_searches, now)
  forward()
}

#* Health check
#* @get /health
#* @serializer unboxedJSON
function() list(status = "ok", time = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"))

#* Search immunology/virology literature across multiple databases
#* @param q Search term (1-200 characters)
#* @param limit Maximum results to return, 1-100 (default 25)
#* @param abstract_chars Truncate each abstract to this many characters; 0 omits abstracts (default 1500)
#* @get /search
#* @serializer unboxedJSON
function(req, res, q = "", limit = 25, abstract_chars = 1500) {
  q <- trimws(as.character(q))
  if (!nzchar(q) || nchar(q) > MAX_QUERY_CHARS) {
    res$status <- 400
    return(list(error = sprintf("q must be 1-%d characters.", MAX_QUERY_CHARS)))
  }
  limit <- suppressWarnings(as.integer(limit))
  if (is.na(limit)) limit <- 25L
  limit <- max(1L, min(limit, MAX_RETURN))
  abstract_chars <- suppressWarnings(as.integer(abstract_chars))
  if (is.na(abstract_chars)) abstract_chars <- 1500L
  abstract_chars <- max(0L, min(abstract_chars, 10000L))

  # Optional bring-your-own keys via headers (never logged or stored)
  core_key  <- trimws(req$HTTP_X_CORE_KEY %||% "")
  uspto_key <- trimws(req$HTTP_X_USPTO_KEY %||% "")

  t0 <- Sys.time()
  out <- tryCatch(
    orchestrate_data_extraction_cached(search_term = q, core_key = core_key, uspto_key = uspto_key),
    error = function(e) e
  )
  if (inherits(out, "error")) {
    res$status <- 500
    return(list(error = "Search failed.", detail = conditionMessage(out)))
  }

  df <- out$deduplicated_data
  base <- list(
    query = q,
    from_cache = identical(out$metadata$source, "CACHE"),
    seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
  )
  if (is.null(df) || nrow(df) == 0) return(c(base, list(total_found = 0, returned = 0, results = list())))

  cols <- c(title = "Title", abstract = "Abstract", authors = "Authors",
            publication_date = "PublicationDate", doi = "DOI", url = "URL",
            source = "Source", primary_cell = "primary_cell",
            primary_virus = "primary_virus", is_bioinformatics = "is_bioinformatics")
  cols <- cols[cols %in% names(df)]
  slim <- df[, unname(cols), drop = FALSE]
  names(slim) <- names(cols)
  slim <- as.data.frame(lapply(slim, function(x) if (is.list(x)) vapply(x, function(v) paste(unlist(v), collapse = "; "), "") else x),
                        stringsAsFactors = FALSE)

  # Source-balanced selection: round-robin across databases instead of
  # returning the first N rows (which would all come from one source).
  picked <- slim %>%
    group_by(source) %>%
    mutate(.rank = row_number()) %>%
    ungroup() %>%
    arrange(.rank) %>%
    select(-.rank) %>%
    head(limit)

  if ("abstract" %in% names(picked)) {
    if (abstract_chars == 0) {
      picked$abstract <- NULL
    } else {
      long <- !is.na(picked$abstract) & nchar(picked$abstract) > abstract_chars
      picked$abstract[long] <- paste0(substr(picked$abstract[long], 1, abstract_chars), "...")
    }
  }

  c(base, list(
    total_found = nrow(df),
    returned = nrow(picked),
    source_counts = as.list(table(df$Source)),
    results = picked
  ))
}
