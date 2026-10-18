#!/usr/bin/env python3
"""Chunk 2a: wire the full-text fetcher into the REST API.

  - source fulltext_extraction.R alongside the other extractors
  - give /fulltext its own rate bucket (the filter previously limited /search only)
  - return pmcid / is_open_access / primary_bacteria from /search, so an agent
    knows which articles it can fetch (primary_bacteria was promised in the tool
    description and llms.txt but never actually returned)
  - add GET /fulltext

Run from the repo root.  --check reports without writing.
"""
import re
import sys
from pathlib import Path

CHECK = "--check" in sys.argv
api = Path("agent/api.R")
if not api.exists():
    print("!! run from the repo root (agent/api.R not found)"); sys.exit(1)


def tolerant(anchor):
    """Match `anchor` ignoring trailing whitespace at line ends."""
    return re.compile(
        r"[ \t]*\n".join(re.escape(l.rstrip()) for l in anchor.split("\n")) + r"[ \t]*"
    )


EDITS = []

# --- 1. source the new file ------------------------------------------------ #
EDITS.append((
    "source list",
    '''            "scopus_abstract_extraction.R", "R/db_utils_local.R", "R/log_utils_local.R",''',
    '''            "scopus_abstract_extraction.R", "R/db_utils_local.R", "R/log_utils_local.R",
            "fulltext_extraction.R",''',
))

# --- 2. constants ---------------------------------------------------------- #
EDITS.append((
    "rate limit constants",
    '''SEARCHES_PER_MIN   <- 20L   # server-wide cap, protects the machine and upstream APIs
.recent_searches   <- numeric(0)''',
    '''SEARCHES_PER_MIN   <- 20L   # server-wide cap, protects the machine and upstream APIs
.recent_searches   <- numeric(0)

# Full text gets its own bucket so it cannot starve search, and vice versa.
# The cap is about Europe PMC's tolerance, not local CPU: a fetch is one GET
# plus XML parsing, far cheaper than the search that found the article. What we
# are avoiding is looking like a bulk harvester to EBI and getting the server's
# IP blocked, which would take search down too.
# Note this counts cache hits as well, since the filter runs before the handler
# knows whether the text is already on disk - hence a generous limit.
FULLTEXT_PER_MIN   <- 30L
.recent_fulltext   <- numeric(0)''',
))

# --- 3. the filter --------------------------------------------------------- #
EDITS.append((
    "rate limit filter",
    '''  if (!identical(req$PATH_INFO, "/search")) return(forward())
  now <- as.numeric(Sys.time())
  .recent_searches <<- .recent_searches[.recent_searches > now - 60]
  if (length(.recent_searches) >= SEARCHES_PER_MIN) {
    res$status <- 429
    return(list(error = "Rate limit reached. Please wait a minute and try again."))
  }
  .recent_searches <<- c(.recent_searches, now)
  forward()''',
    '''  path <- req$PATH_INFO
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
  forward()''',
))

# --- 4. output columns ----------------------------------------------------- #
EDITS.append((
    "output column mapping",
    '''            source = "Source", primary_cell = "primary_cell",
            primary_virus = "primary_virus", is_bioinformatics = "is_bioinformatics")''',
    '''            source = "Source", primary_cell = "primary_cell",
            primary_virus = "primary_virus", primary_bacteria = "primary_bacteria",
            is_bioinformatics = "is_bioinformatics",
            # pmcid tells an agent which articles /fulltext can actually serve;
            # is_open_access says so explicitly. primary_bacteria was already
            # promised by the tool description and llms.txt but never returned.
            pmcid = "PMCID", is_open_access = "IsOpenAccess")''',
))

# --- 5. the endpoint ------------------------------------------------------- #
EDITS.append((
    "fulltext endpoint",
    '''#* Search immunology/virology literature across multiple databases''',
    '''#* Open-access full text for one article
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
      max_results  = max_chars,
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

#* Search immunology/virology literature across multiple databases''',
))

src = api.read_text(encoding="utf-8")

problems = []
for label, old, _ in EDITS:
    n = len(tolerant(old).findall(src))
    if n != 1:
        problems.append(f"'{label}' found {n} times, expected 1")

if problems:
    print("\n".join("  !! " + p for p in problems))
    print("\nNothing written.")
    sys.exit(1)

for label, _, _ in EDITS:
    print(f"  ok {label}")

if CHECK:
    print("\nAll blocks matched (check only, nothing written).")
    sys.exit(0)

bak = Path("agent/api.R.ftbak")
if not bak.exists():
    bak.write_text(src, encoding="utf-8")
    print(f"  backup -> {bak}")

for label, old, new in EDITS:
    src = tolerant(old).sub(lambda _m, _n=new: _n, src, count=1)
api.write_text(src, encoding="utf-8")
print("\nagent/api.R patched")
