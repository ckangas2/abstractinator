# ---- Text safety for agent output ---------------------------------------
# Records handed to an agent are third-party text we do not control. Meaning
# cannot be sanitised -- an abstract that says "ignore previous instructions"
# is indistinguishable from a paper *about* prompt injection, and stripping
# phrases would corrupt real literature. But invisible characters have no
# legitimate place in bibliographic text, and they are how instructions get
# hidden from a human reading the same record. Those we remove.
strip_invisible <- function(x) {
  if (!is.character(x)) return(x)
  na <- is.na(x)
  # C0/C1 control characters, keeping tab and newline
  x <- gsub("[\001-\010\013\014\016-\037\177]", "", x, useBytes = TRUE)
  # zero-width spaces/joiners, bidi overrides and isolates, word joiner, BOM
  x <- gsub("[\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]",
            "", x, perl = TRUE)
  x[na] <- NA_character_
  x
}

# agent/api.R
# REST API for AI agents and scripts. Wraps the same search engine as the website.
# Run from the repo root (see agent/run_api.R); listens on 127.0.0.1 only.

library(plumber)
library(future)
library(dplyr)

Sys.setenv(INTEGRATE_NIH_NSF = "1")

# plumber switches into agent/ while loading this file, so go back to the
# repo root (passed in by run_api.R) before loading the engine. Relative paths
# like biorxiv_local_db/ and .cache/ then resolve exactly as they do for app.R.
ROOT <- getOption("abstractinator.root", normalizePath(".."))
setwd(ROOT)

# Start background workers AFTER moving to the repo root: each worker keeps the
# directory it was launched in, and bioRxiv searches look for biorxiv_local_db/
# relative to it.
plan(multisession, workers = 8)

# Same engine + cache as app.R
for (f in c("epmc_standalone_extraction.R", "CORE_extraction.R",
            "clinicaltrials.gov_extraction.R", "scopus_extraction.R",
            "biorxiv_extraction.R", "patentsview_extraction.R", "deduplication.R",
            "scopus_abstract_extraction.R", "R/db_utils_local.R", "R/log_utils_local.R",
            "fulltext_extraction.R",
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

# Full text gets its own bucket so it cannot starve search, and vice versa.
# The cap is about Europe PMC's tolerance, not local CPU: a fetch is one GET
# plus XML parsing, far cheaper than the search that found the article. What we
# are avoiding is looking like a bulk harvester to EBI and getting the server's
# IP blocked, which would take search down too.
# Note this counts cache hits as well, since the filter runs before the handler
# knows whether the text is already on disk - hence a generous limit.
FULLTEXT_PER_MIN   <- 30L
.recent_fulltext   <- numeric(0)

#* Run every request from the repo root, and rate-limit /search
#* @filter root_and_rate_limit
function(req, res) {
  # plumber serves requests from agent/; switch back so relative paths
  # (biorxiv_local_db/, background workers started on first search) resolve
  # exactly as they do for the website.
  if (!identical(getwd(), ROOT)) setwd(ROOT)
  path <- req$PATH_INFO
  if (!path %in% c("/search", "/fulltext")) return(forward())
  now <- as.numeric(Sys.time())

  if (identical(path, "/search")) {
    .recent_searches <<- .recent_searches[.recent_searches > now - 60]
    if (length(.recent_searches) >= SEARCHES_PER_MIN) {
      res$status <- 429
      return(list(error = "Rate limit reached. Please wait a minute and try again."))
    }
    .recent_searches <<- c(.recent_searches, now)
  } else {
    .recent_fulltext <<- .recent_fulltext[.recent_fulltext > now - 60]
    if (length(.recent_fulltext) >= FULLTEXT_PER_MIN) {
      res$status <- 429
      return(list(error = "Full-text rate limit reached. Please wait a minute and try again."))
    }
    .recent_fulltext <<- c(.recent_fulltext, now)
  }
  forward()
}

#* Health check
#* @get /health
#* @serializer unboxedJSON
function() list(status = "ok", time = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"))

#* Open-access full text for one article
#* @param pmcid PMC identifier from a search result, e.g. PMC1234567
#* @param doi DOI, used to look up the PMCID when pmcid is not supplied
#* @param max_chars Truncate the returned text (default 20000, maximum 100000)
#* @get /fulltext
#* @serializer unboxedJSON
function(req, res, pmcid = "", doi = "", max_chars = 20000) {
  t0 <- Sys.time()
  pmcid <- toupper(trimws(as.character(pmcid)))
  doi   <- trimws(as.character(doi))

  if (!nzchar(pmcid) && !nzchar(doi)) {
    res$status <- 400
    return(list(error = "Supply either pmcid (e.g. PMC1234567) or doi."))
  }

  resolved_from_doi <- FALSE
  if (!nzchar(pmcid)) {
    pmcid <- resolve_pmcid_from_doi(doi)
    resolved_from_doi <- TRUE
    if (is.na(pmcid)) {
      return(list(
        doi = doi, status = "not_open_access",
        error = "No Europe PMC record with a PMCID for that DOI, so no open-access full text."
      ))
    }
  }

  out <- tryCatch(
    fetch_epmc_fulltext(pmcid, max_chars = max_chars),
    error = function(e) list(pmcid = pmcid, status = "failed", error = conditionMessage(e))
  )

  # Logged on the same store as searches, as its own event, so the funnel can
  # show how often full text is actually wanted versus just search.
  agent_session <- trimws(req$HTTP_X_SESSION_ID %||% "")
  agent_client  <- trimws(req$HTTP_X_CLIENT_NAME %||% "")
  tryCatch(
    log_search_to_s3(
      search_term  = pmcid,
      duration_sec = as.numeric(difftime(Sys.time(), t0, units = "secs")),
      result_count = if (identical(out$status, "success")) 1L else 0L,
      source_type  = "EPMC_FULLTEXT",
      channel      = if (grepl("uptime-probe|abstractinator-probe",
                               tolower(agent_client))) "probe" else "agent",
      event        = "fulltext",
      session      = if (nzchar(agent_session)) agent_session else NA_character_,
      client       = if (nzchar(agent_client))  agent_client  else NA_character_,
      max_results  = suppressWarnings(as.integer(max_chars)),
      returned     = if (is.null(out$chars)) NA_integer_ else out$chars,
      total_found  = if (is.null(out$total_chars)) NA_integer_ else out$total_chars,
      from_cache   = isTRUE(out$from_cache),
      status       = if (identical(out$status, "success")) "ok"
                     else if (identical(out$status, "not_open_access")) "empty" else "error"
    ),
    error = function(e) message("[Logger] Fulltext log failed: ", e$message)
  )

  if (identical(out$status, "failed")) res$status <- 502
  if (resolved_from_doi) out$doi <- doi
  out
}

#* Search immunology/virology literature across multiple databases
#* @param q Search term (1-200 characters)
#* @param limit Maximum results to return, 1-100 (default 25)
#* @param abstract_chars Truncate each abstract to this many characters; 0 omits abstracts (default 1500)
#* @param deep "true" for a deep search: up to 250 results per source instead of 50 (slower)
#* @get /search
#* @serializer unboxedJSON
function(req, res, q = "", limit = 25, abstract_chars = 1500, deep = "false") {
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

  deep <- tolower(as.character(deep)) %in% c("true", "1", "yes")
  per_source <- if (deep) DEEP_SEARCH_LIMIT else 50L

  # Optional bring-your-own keys via headers (never logged or stored)
  core_key  <- trimws(req$HTTP_X_CORE_KEY %||% "")
  uspto_key <- trimws(req$HTTP_X_USPTO_KEY %||% "")

  t0 <- Sys.time()
  out <- tryCatch(
    orchestrate_data_extraction_cached(search_term = q, limit = per_source, core_key = core_key, uspto_key = uspto_key),
    error = function(e) e
  )
  if (inherits(out, "error")) {
    res$status <- 500
    return(list(error = "Search failed.", detail = conditionMessage(out)))
  }

  df <- out$deduplicated_data
  
  # Who is asking. The MCP server forwards a hashed session id and the client
  # name it received at initialize; both are absent for a direct REST caller.
  # No IP address is ever recorded (SECURITY.md).
  agent_session <- trimws(req$HTTP_X_SESSION_ID %||% "")
  agent_client  <- trimws(req$HTTP_X_CLIENT_NAME %||% "")
  log_channel   <- if (grepl("uptime-probe|abstractinator-probe",
                             tolower(agent_client))) "probe" else "agent"

  # Logged on every exit path below, after the result set is known.
  log_this_search <- function(total_found, returned, source_counts, status) {
    tryCatch(
      log_search_to_s3(
        search_term    = q,
        duration_sec   = as.numeric(difftime(Sys.time(), t0, units = "secs")),
        result_count   = returned,
        source_type    = if (identical(out$metadata$source, "CACHE")) "CACHE" else "API",
        core_key = core_key, uspto_key = uspto_key,
        channel        = log_channel,
        event          = "search",
        session        = if (nzchar(agent_session)) agent_session else NA_character_,
        client         = if (nzchar(agent_client))  agent_client  else NA_character_,
        deep           = deep,
        max_results    = limit,
        abstract_chars = abstract_chars,
        total_found    = total_found,
        returned       = returned,
        from_cache     = identical(out$metadata$source, "CACHE"),
        source_counts  = source_counts,
        status         = status
      ),
      error = function(e) message("[Logger] Agent log failed: ", e$message)
    )
  }
  
  base <- list(
    query = q,
    deep = deep,
    from_cache = identical(out$metadata$source, "CACHE"),
    seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
  )
  if (is.null(df) || nrow(df) == 0) {
    log_this_search(0L, 0L, NULL, "empty")
    return(c(base, list(total_found = 0, returned = 0, results = list())))
  }

  cols <- c(title = "Title", abstract = "Abstract", authors = "Authors",
            publication_date = "PublicationDate", doi = "DOI", url = "URL",
            source = "Source", primary_cell = "primary_cell",
            primary_virus = "primary_virus", primary_bacteria = "primary_bacteria",
            is_bioinformatics = "is_bioinformatics",
            # pmcid tells an agent which articles /fulltext can actually serve;
            # is_open_access says so explicitly. primary_bacteria was already
            # promised by the tool description and llms.txt but never returned.
            pmcid = "PMCID", is_open_access = "IsOpenAccess")
  cols <- cols[cols %in% names(df)]
  slim <- df[, unname(cols), drop = FALSE]
  names(slim) <- names(cols)
  slim <- as.data.frame(lapply(slim, function(x) strip_invisible(if (is.list(x)) vapply(x, function(v) paste(unlist(v), collapse = "; "), "") else x)),
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

  src <- as.list(table(df$Source))
  log_this_search(nrow(df), nrow(picked), src, "ok")

  c(base, list(
    total_found = nrow(df),
    returned = nrow(picked),
    source_counts = src,
    results = picked
  ))
}
