#!/usr/bin/env python3
"""
Wire app.R and agent/api.R up to the widened logging schema.

Run from the repo root. Makes .bak copies, matches on exact existing text, and
refuses to write anything if a block it expects is missing - so a partial apply
is not possible.

    python3 patch_logging.py            # apply
    python3 patch_logging.py --check    # report only, change nothing
"""
import sys
from pathlib import Path

CHECK = "--check" in sys.argv

# --------------------------------------------------------------------------- #
# app.R : widen the website log call
# --------------------------------------------------------------------------- #
APP_OLD = '''      log_search_to_s3(
        search_term = search_term,
        duration_sec = search_duration,
        result_count = log_count,
        source_type = log_source,
        elsevier_key = active_elsevier,
        uspto_key = active_uspto,
        core_key = active_core # <--- Add this!
      )'''

APP_NEW = '''      # Maintainer testing is logged as "self" rather than "website", so it can
      # be excluded from real usage counts: https://abstractinator.me/?self=1
      log_channel <- tryCatch({
        qs <- shiny::parseQueryString(session$clientData$url_search)
        if (identical(qs$self, "1")) "self" else "website"
      }, error = function(e) "website")

      # Records found before deduplication, vs log_count which is after it.
      log_total_found <- tryCatch(
        if (!is.null(extraction_results$original_combined_data)) {
          nrow(extraction_results$original_combined_data)
        } else NA_integer_,
        error = function(e) NA_integer_
      )

      log_sources <- tryCatch({
        d <- extraction_results$deduplicated_data
        if (!is.null(d) && "Source" %in% names(d)) as.list(table(d$Source)) else NULL
      }, error = function(e) NULL)

      log_search_to_s3(
        search_term    = search_term,
        duration_sec   = search_duration,
        result_count   = log_count,
        source_type    = log_source,
        elsevier_key   = active_elsevier,
        uspto_key      = active_uspto,
        core_key       = active_core,
        channel        = log_channel,
        event          = "search",
        deep           = isTRUE(search_ctx$deep),
        total_found    = log_total_found,
        returned       = log_count,
        from_cache     = identical(log_source, "CACHE"),
        source_counts  = log_sources
      )'''

# --------------------------------------------------------------------------- #
# agent/api.R : the log call currently fires before `picked` exists, so it can
# never record what was actually returned. Remove it there and log on both exit
# paths instead - the zero-result early return, and the normal return.
# --------------------------------------------------------------------------- #
API_OLD_LOG = '''  # Log every agent search (same log as the website, tagged channel = "agent")
  tryCatch(
    log_search_to_s3(
      search_term = q,
      duration_sec = as.numeric(difftime(Sys.time(), t0, units = "secs")),
      result_count = if (is.null(df)) 0L else nrow(df),
      source_type = if (identical(out$metadata$source, "CACHE")) "CACHE" else "API",
      core_key = core_key, uspto_key = uspto_key,
      channel = "agent"
    ),
    error = function(e) message("[Logger] Agent log failed: ", e$message)
  )
'''

API_NEW_HELPER = '''  # Who is asking. The MCP server forwards a hashed session id and the client
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
'''

API_OLD_EMPTY = '''  if (is.null(df) || nrow(df) == 0) return(c(base, list(total_found = 0, returned = 0, results = list())))'''

API_NEW_EMPTY = '''  if (is.null(df) || nrow(df) == 0) {
    log_this_search(0L, 0L, NULL, "empty")
    return(c(base, list(total_found = 0, returned = 0, results = list())))
  }'''

API_OLD_RETURN = '''  c(base, list(
    total_found = nrow(df),
    returned = nrow(picked),
    source_counts = as.list(table(df$Source)),
    results = picked
  ))'''

API_NEW_RETURN = '''  src <- as.list(table(df$Source))
  log_this_search(nrow(df), nrow(picked), src, "ok")

  c(base, list(
    total_found = nrow(df),
    returned = nrow(picked),
    source_counts = src,
    results = picked
  ))'''


def apply(path: Path, edits):
    src = path.read_text(encoding="utf-8")
    missing = [label for label, old, _ in edits if old not in src]
    if missing:
        print(f"  !! {path}: could not find {', '.join(missing)}")
        print("     file left untouched")
        return False
    for label, old, new in edits:
        if src.count(old) != 1:
            print(f"  !! {path}: {label} appears {src.count(old)} times, expected 1")
            print("     file left untouched")
            return False
    for _, old, new in edits:
        src = src.replace(old, new)
    if CHECK:
        print(f"  ok {path}: all {len(edits)} block(s) matched (check only, not written)")
        return True
    bak = path.with_suffix(path.suffix + ".bak")
    if not bak.exists():
        bak.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"  backup -> {bak}")
    path.write_text(src, encoding="utf-8")
    print(f"  ok {path}: {len(edits)} block(s) replaced")
    return True


def main():
    root = Path(".")
    app, api = root / "app.R", root / "agent" / "api.R"
    for f in (app, api):
        if not f.exists():
            print(f"!! {f} not found - run this from the repo root")
            return 1

    print("app.R")
    ok1 = apply(app, [("website log call", APP_OLD, APP_NEW)])

    print("agent/api.R")
    ok2 = apply(api, [
        ("premature log call", API_OLD_LOG, API_NEW_HELPER),
        ("zero-result return", API_OLD_EMPTY, API_NEW_EMPTY),
        ("final return",       API_OLD_RETURN, API_NEW_RETURN),
    ])

    if ok1 and ok2:
        print("\nBoth files patched." if not CHECK else "\nAll blocks matched.")
        return 0
    print("\nNothing was written. Paste the output above and the mismatch can be fixed.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
