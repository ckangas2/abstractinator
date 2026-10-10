# log_utils_local.R
# Protocol: Local Event Logging (Mimicking S3 structure)
#
# One JSON file per event, under <LOG_DIR>/<YYYY-MM-DD>/.
# Adding fields is safe: the reader binds rows and fills missing columns with NA,
# so records written before a field existed still load.
#
# LOG_DIR is ABSOLUTE on purpose. It used to be ".cache/s3_mimic/logs/", relative
# to getwd(), which meant the Shiny app, the REST API and an interactive Rscript
# each wrote to (and read from) a different directory depending on where they
# were launched. Set ABSTRACTINATOR_LOG_DIR to override - e.g. when testing from
# a working copy, so dev searches do not land in the live log.

library(jsonlite)
library(uuid)
library(dplyr)
library(purrr)

DEFAULT_LOG_DIR <- "/srv/shiny-server/abstractinator/.cache/s3_mimic/logs"

log_dir <- function() {
  d <- Sys.getenv("ABSTRACTINATOR_LOG_DIR", "")
  if (!nzchar(d)) d <- DEFAULT_LOG_DIR
  d
}

# Kept for backward compatibility: older code referred to LOG_DIR directly.
LOG_DIR <- log_dir()

#' Pack a named source_counts list into one scalar string
#' list(EPMC = 50, OpenAlex = 49)  ->  "EPMC:50;OpenAlex:49"
#' Stored as a string rather than a nested object so that bind_rows() stays flat.
pack_source_counts <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  nm <- names(x)
  if (is.null(nm)) return(NA_character_)
  paste(sprintf("%s:%s", nm, unlist(x, use.names = FALSE)), collapse = ";")
}

#' Log one event locally.
#'
#' @param event  "search" (a completed search) or a transport event from the MCP
#'   server: "initialize", "tools_list", "tools_call", "other".
#' @param channel "website", "agent", "api", "probe" (uptime probe / our own
#'   test clients) or "self" (the maintainer testing the site).
#' @param session Opaque client session or client-fingerprint string. NEVER an IP
#'   address - SECURITY.md promises none are stored.
#' @param client  Client name/version as reported by the MCP client, if known.
#' @param status  "ok", "empty" (ran fine, zero results) or "error".
log_search_to_s3 <- function(search_term = NA_character_,
                             duration_sec = NA_real_,
                             result_count = NA_integer_,
                             source_type = NA_character_,
                             elsevier_key = NULL,
                             uspto_key = NULL,
                             core_key = NULL,
                             channel = "website",
                             event = "search",
                             session = NA_character_,
                             client = NA_character_,
                             deep = NA,
                             max_results = NA_integer_,
                             abstract_chars = NA_integer_,
                             total_found = NA_integer_,
                             returned = NA_integer_,
                             from_cache = NA,
                             source_counts = NULL,
                             status = NA_character_) {

  # Which optional API keys the caller supplied. Only ever a boolean - the key
  # itself is never recorded.
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key)    && nchar(trimws(uspto_key))    > 0
  has_core     <- !is.null(core_key)     && nchar(trimws(core_key))     > 0

  # Infer status when the caller did not say.
  if (is.na(status)) {
    status <- if (identical(event, "search")) {
      n <- suppressWarnings(as.integer(result_count))
      if (!is.na(n) && n == 0L) "empty" else "ok"
    } else "ok"
  }

  # ISO-8601 UTC. The old format used "%Z", which cannot be parsed back on input
  # and silently broke the reader for weeks.
  ts <- format(as.POSIXct(Sys.time()), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  log_data <- list(
    timestamp      = ts,
    event          = event,
    channel        = channel,
    session        = session,
    client         = client,
    term           = search_term,
    deep           = deep,
    max_results    = max_results,
    abstract_chars = abstract_chars,
    total_found    = total_found,
    returned       = returned,
    n_results      = result_count,   # retained: older records use this name
    from_cache     = from_cache,
    duration       = if (is.na(duration_sec)) NA_real_ else round(duration_sec, 2),
    sources        = pack_source_counts(source_counts),
    source         = source_type,
    status         = status,
    has_elsevier   = has_elsevier,
    has_uspto      = has_uspto,
    has_core       = has_core
  )

  json_payload <- jsonlite::toJSON(log_data, auto_unbox = TRUE, pretty = TRUE,
                                   na = "null")

  dir_now    <- log_dir()
  date_path  <- format(as.POSIXct(Sys.time()), "%Y-%m-%d", tz = "UTC")
  day_folder <- file.path(dir_now, date_path)

  tryCatch({
    if (!dir.exists(day_folder)) dir.create(day_folder, recursive = TRUE)
    file_name <- file.path(
      day_folder,
      sprintf("%s_%s_%s.json", event, as.numeric(Sys.time()), uuid::UUIDgenerate())
    )
    write(json_payload, file = file_name)
    TRUE
  }, error = function(e) {
    warning(paste("[Logger] Local Save Failed:", e$message))
    FALSE
  })
}

#' Admin tool: fetch local event logs.
#' @param dir Override the log directory (defaults to ABSTRACTINATOR_LOG_DIR or
#'   the live install).
fetch_search_logs <- function(dir = log_dir()) {
  if (!dir.exists(dir)) {
    message("No log directory at ", dir)
    return(NULL)
  }

  files <- list.files(dir, recursive = TRUE, full.names = TRUE, pattern = "\\.json$")
  if (length(files) == 0) {
    message("No logs found in ", dir)
    return(NULL)
  }

  logs_df <- purrr::map_df(files, function(f) {
    tryCatch({
      rec <- jsonlite::fromJSON(f)
      # Guard against any nested value sneaking in: keep scalars only, so
      # bind_rows() cannot fail on a list column.
      rec <- rec[vapply(rec, function(x) length(x) <= 1, logical(1))]
      as_tibble(lapply(rec, function(x) if (length(x) == 0) NA else x))
    }, error = function(e) NULL)
  })

  if (is.null(logs_df) || nrow(logs_df) == 0) return(logs_df)

  # Two timestamp shapes exist: new ISO-8601 UTC, and the old
  # "%Y-%m-%d %H:%M:%S %Z" whose zone token has to be stripped before parsing.
  parse_ts <- function(x) {
    x   <- as.character(x)
    out <- as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    # Records written before the ISO switch: strip the trailing zone token,
    # which "%Z" can write but cannot parse back.
    need <- is.na(out)
    if (any(need)) {
      out[need] <- as.POSIXct(
        sub("[[:space:]]+[A-Za-z/_+-]+$", "", x[need]),
        format = "%Y-%m-%d %H:%M:%S", tz = "UTC"
      )
    }
    out
  }

  ensure <- function(df, col, value) {
    if (!col %in% names(df)) df[[col]] <- value
    df
  }

  logs_df <- logs_df %>%
    mutate(timestamp = parse_ts(timestamp)) %>%
    ensure("event",   "search") %>%   # pre-dates event logging
    ensure("channel", "website") %>%  # pre-dates the channel field
    ensure("status",  "ok")

  logs_df$event[is.na(logs_df$event)]     <- "search"
  logs_df$channel[is.na(logs_df$channel)] <- "website"

  for (num in c("duration", "total_found", "returned", "n_results",
                "max_results", "abstract_chars")) {
    if (num %in% names(logs_df)) logs_df[[num]] <- suppressWarnings(as.numeric(logs_df[[num]]))
  }

  arrange(logs_df, desc(timestamp))
}

#' Admin tool: searches per day, split by channel. Counts completed searches
#' only - transport events are excluded so the numbers stay comparable to the
#' pre-funnel history.
summarize_search_logs <- function(dir = log_dir()) {
  logs <- fetch_search_logs(dir)
  if (is.null(logs) || nrow(logs) == 0) return(NULL)
  logs %>%
    filter(event == "search") %>%
    mutate(day = as.Date(timestamp)) %>%
    count(day, channel, name = "searches") %>%
    tidyr::pivot_wider(names_from = channel, values_from = searches,
                       values_fill = 0) %>%
    arrange(desc(day))
}

#' Admin tool: the MCP funnel. Shows how many clients connected, how many asked
#' what tools exist, and how many actually called one. A wide gap between
#' tools_list and tools_call points at the tool description, not at discovery.
summarize_funnel <- function(dir = log_dir(), days = 30) {
  logs <- fetch_search_logs(dir)
  if (is.null(logs) || nrow(logs) == 0) return(NULL)
  logs %>%
    filter(timestamp >= Sys.time() - days * 86400) %>%
    mutate(day = as.Date(timestamp)) %>%
    count(day, event, name = "n") %>%
    tidyr::pivot_wider(names_from = event, values_from = n, values_fill = 0) %>%
    arrange(desc(day))
}

#' Admin tool: which clients are using the MCP server, and how much.
summarize_clients <- function(dir = log_dir()) {
  logs <- fetch_search_logs(dir)
  if (is.null(logs) || nrow(logs) == 0) return(NULL)
  if (!"client" %in% names(logs)) return(NULL)
  logs %>%
    filter(!is.na(client)) %>%
    group_by(client, channel) %>%
    summarise(
      events   = n(),
      searches = sum(event == "search", na.rm = TRUE),
      sessions = n_distinct(session[!is.na(session)]),
      first    = min(timestamp),
      last     = max(timestamp),
      .groups  = "drop"
    ) %>%
    arrange(desc(searches), desc(events))
}

#' Admin tool: search quality. Zero-result rate, cache hit rate, latency, and
#' whether anybody ever uses deep search.
summarize_quality <- function(dir = log_dir()) {
  logs <- fetch_search_logs(dir)
  if (is.null(logs) || nrow(logs) == 0) return(NULL)
  s <- filter(logs, event == "search")
  if (nrow(s) == 0) return(NULL)
  tibble(
    searches       = nrow(s),
    empty          = sum(s$status == "empty", na.rm = TRUE),
    empty_pct      = round(100 * mean(s$status == "empty", na.rm = TRUE), 1),
    cached         = if ("from_cache" %in% names(s)) sum(s$from_cache %in% TRUE) else NA_integer_,
    deep_used      = if ("deep" %in% names(s)) sum(s$deep %in% TRUE) else NA_integer_,
    median_seconds = round(median(s$duration, na.rm = TRUE), 1),
    p90_seconds    = round(quantile(s$duration, 0.9, na.rm = TRUE, names = FALSE), 1),
    median_found   = median(s$total_found, na.rm = TRUE)
  )
}

#' Admin tool: how often each source actually contributes anything.
#' Unpacks the "EPMC:50;OpenAlex:49" strings back into per-source rows.
summarize_sources <- function(dir = log_dir()) {
  logs <- fetch_search_logs(dir)
  if (is.null(logs) || nrow(logs) == 0) return(NULL)
  if (!"sources" %in% names(logs)) return(NULL)
  s <- filter(logs, event == "search", !is.na(sources))
  if (nrow(s) == 0) return(NULL)
  purrr::map_df(s$sources, function(str) {
    parts <- strsplit(strsplit(str, ";", fixed = TRUE)[[1]], ":", fixed = TRUE)
    tibble(
      source = vapply(parts, `[`, character(1), 1),
      n      = suppressWarnings(as.numeric(vapply(parts, `[`, character(1), 2)))
    )
  }) %>%
    group_by(source) %>%
    summarise(
      searches_present = n(),
      zero_results     = sum(n == 0, na.rm = TRUE),
      median_records   = median(n, na.rm = TRUE),
      total_records    = sum(n, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(desc(total_records))
}
