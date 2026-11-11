# R/registry.R -- the program registry, read side.
#
# alias_key() is the identity key of a name (registry/SPEC.md section 5). It
# must agree with alias_key() in tracker/registry.py: both are tested against
# tracker/tests/alias_keys.tsv.
#
# The rest reads data/registry/registry.sqlite for the REST API's /program and
# /changes (agent/api.R; the tables are described in tracker/REGISTRY_DB.md).
# tracker/build_registry.py rebuilds that file weekly and swaps it in by
# renaming, so a connection is opened read-only per request and closed after,
# never cached: a cached one would keep reading the replaced file.
#
# R/ is loaded automatically by the Shiny app, so this file only defines
# things. RSQLite is needed only when the database is actually read.

REGISTRY_SCHEMA_VERSION <- "2"   # 2: virus and approval tables
REGISTRY_SIGNIFICANCE   <- c("major", "minor", "info")
REGISTRY_RECENT_CHANGES <- 50L

# "MRTX-1133", "mrtx 1133" and "MRTX1133" all give "MRTX1133". Vectorised;
# NA and names with no letters or digits give "".
alias_key <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  # Before NFKC, which would turn the trademark sign into the letters "TM".
  # Escapes rather than the characters themselves, so the result does not
  # depend on the encoding R reads this file in.
  x <- stringi::stri_replace_all_regex(x, "[\u00ae\u2122\u00a9]", "")
  x <- stringi::stri_replace_all_fixed(x, "\u2206", "\u0394")
  x <- stringi::stri_trans_nfkc(x)
  # A fixed locale, because Python's str.upper() ignores it (no Turkish dotted I).
  x <- stringi::stri_trans_toupper(x, locale = "en_US")
  stringi::stri_replace_all_regex(x, "[^\\p{L}\\p{N}]", "")
}

# The database file: ABSTRACTINATOR_REGISTRY_DB, else under the app root.
registry_db_path <- function(root = getwd()) {
  p <- Sys.getenv("ABSTRACTINATOR_REGISTRY_DB", "")
  if (nzchar(p)) p else file.path(root, "data", "registry", "registry.sqlite")
}

# What the API sends back: an HTTP status and a body to serialise.
registry_result <- function(status, body) list(status = as.integer(status), body = body)

# Run fun(con, meta) against the database, opened read-only and closed after.
registry_with_db <- function(path, fun) {
  if (!file.exists(path)) {
    return(registry_result(503, list(
      error = "The program registry has not been built yet. Try again later.")))
  }
  if (!requireNamespace("RSQLite", quietly = TRUE)) {
    message("[API] RSQLite is not installed; /program and /changes need it.")
    return(registry_result(503, list(
      error = "The program registry is not available on this server yet. Try again later.")))
  }
  con <- DBI::dbConnect(RSQLite::SQLite(), path, flags = RSQLite::SQLITE_RO)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  m <- DBI::dbGetQuery(con, "SELECT key, value FROM meta")
  meta <- as.list(stats::setNames(m$value, m$key))
  if (!identical(registry_meta_value(meta, "schema_version"), REGISTRY_SCHEMA_VERSION)) {
    return(registry_result(503, list(
      error = "The program registry has a schema this server does not read yet.")))
  }
  fun(con, meta)
}

# A meta value, NA (null in JSON) when absent or empty.
registry_meta_value <- function(meta, key) {
  v <- meta[[key]]
  if (is.null(v) || is.na(v) || !nzchar(v)) NA_character_ else as.character(v)
}

# Every program's ID, status, survivor and name. The registry is small, so
# merges and event program names are resolved from this rather than per row.
registry_programs <- function(con) {
  DBI::dbGetQuery(con, "SELECT axp_id, status, replaced_by, preferred_name FROM program")
}

# A "; "-separated cell as a JSON array (always an array, possibly empty).
registry_split <- function(x) {
  if (length(x) != 1L || is.na(x)) return(I(character(0)))
  parts <- trimws(strsplit(x, ";", fixed = TRUE)[[1]])
  I(parts[nzchar(parts)])
}

# Follow replaced_by from a merged ID to the program that survives it.
registry_survivor <- function(progs, id) {
  seen <- id
  repeat {
    i <- match(id, progs$axp_id)
    nxt <- if (!is.na(i) && identical(progs$status[i], "merged")) progs$replaced_by[i] else NA_character_
    if (is.na(nxt) || !nxt %in% progs$axp_id || nxt %in% seen) return(id)
    seen <- c(seen, nxt)
    id <- nxt
  }
}

# The programs an AXP ID or a name refers to: list(ids, merged_from). An ID is
# looked up directly; anything else by alias_key. Merged programs resolve to
# their survivor, and merged_from then names the ID that was asked for.
registry_resolve <- function(con, progs, query) {
  hits <- character(0)
  if (grepl("^AXP[0-9]+$", toupper(query))) {
    hits <- intersect(toupper(query), progs$axp_id)
  }
  if (!length(hits)) {
    key <- alias_key(query)
    if (nzchar(key)) {
      hits <- DBI::dbGetQuery(con,
        "SELECT DISTINCT axp_id FROM alias WHERE alias_key = ? ORDER BY axp_id",
        params = list(key))$axp_id
    }
  }
  ids <- unique(vapply(hits, function(h) registry_survivor(progs, h), "", USE.NAMES = FALSE))
  merged_from <- if (length(hits) == 1L && length(ids) == 1L && !identical(hits, ids)) hits else NA_character_
  list(ids = ids, merged_from = merged_from)
}

registry_candidates <- function(progs, ids) {
  out <- progs[match(ids, progs$axp_id), c("axp_id", "preferred_name"), drop = FALSE]
  rownames(out) <- NULL
  out
}

# Change events, newest first, each with its trial's title and its programs.
# where holds fixed SQL conditions with ? placeholders; params their values.
registry_events <- function(con, progs, where, params, limit) {
  sql <- paste(
    "SELECT e.event_id, e.snapshot_date, e.previous_date, e.nct_id, t.brief_title,",
    "e.type, e.significance, e.field, e.before, e.after, e.axp_ids",
    "FROM change_event e LEFT JOIN trial t ON t.nct_id = e.nct_id",
    if (length(where)) paste("WHERE", paste(where, collapse = " AND ")) else "",
    "ORDER BY e.snapshot_date DESC,",
    "CASE e.significance WHEN 'major' THEN 0 WHEN 'minor' THEN 1 ELSE 2 END, e.event_id",
    "LIMIT ?")
  ev <- DBI::dbGetQuery(con, sql, params = c(params, list(as.integer(limit))))
  lapply(seq_len(nrow(ev)), function(i) {
    ids <- tryCatch(as.character(unlist(jsonlite::fromJSON(ev$axp_ids[i]))),
                    error = function(e) character(0))
    list(event_id = ev$event_id[i], snapshot_date = ev$snapshot_date[i],
         previous_date = ev$previous_date[i], nct_id = ev$nct_id[i],
         brief_title = ev$brief_title[i], type = ev$type[i],
         significance = ev$significance[i], field = ev$field[i],
         before = ev$before[i], after = ev$after[i],
         programs = lapply(ids, function(id) list(
           axp_id = id, preferred_name = progs$preferred_name[match(id, progs$axp_id)])))
  })
}

# GET /program: one program with its aliases, trials and recent changes.
# query is already validated (agent/api.R).
registry_program <- function(path, query) {
  registry_with_db(path, function(con, meta) {
    progs <- registry_programs(con)
    hit <- registry_resolve(con, progs, query)
    release <- registry_meta_value(meta, "registry_release")
    if (!length(hit$ids)) {
      return(registry_result(404, list(error = "No program matches that ID or name.", query = query)))
    }
    if (length(hit$ids) > 1L) {
      # An ambiguous name: say which programs it could be rather than guess.
      return(registry_result(200, list(
        registry_release = release, query = query, program = NA,
        candidates = registry_candidates(progs, hit$ids))))
    }
    id <- hit$ids

    p <- DBI::dbGetQuery(con, "SELECT * FROM program WHERE axp_id = ?", params = list(id))
    targets <- if (is.na(p$targets[1])) character(0) else trimws(strsplit(p$targets[1], ";", fixed = TRUE)[[1]])
    program <- list(
      axp_id = p$axp_id[1], preferred_name = p$preferred_name[1], status = p$status[1],
      modality = p$modality[1], platform = p$platform[1],
      targets = I(targets[nzchar(targets)]),
      originator = p$originator[1], sponsor = p$sponsor[1], ncit = p$ncit[1],
      wikidata = p$wikidata[1], unii = p$unii[1],
      entry_version = as.integer(p$entry_version[1]), notes = p$notes[1])

    # The virus or vector, for virus-based programs; NA (null) otherwise.
    v <- DBI::dbGetQuery(con, "SELECT * FROM virus WHERE axp_id = ?", params = list(id))
    virus <- if (nrow(v) == 0L) NA else list(
      role = v$role[1], virus_family = v$virus_family[1], virus = v$virus[1],
      ncbi_taxon = v$ncbi_taxon[1], strain = v$strain[1], replication = v$replication[1],
      modifications = v$modifications[1], transgenes = registry_split(v$transgenes[1]),
      route = registry_split(v$route[1]), carrier = v$carrier[1], evidence_url = v$evidence_url[1])
    approvals <- DBI::dbGetQuery(con, paste(
      "SELECT agency, region, date, status, brand, indication, evidence_url FROM approval",
      "WHERE axp_id = ? ORDER BY date, agency"), params = list(id))

    aliases <- DBI::dbGetQuery(con, paste(
      "SELECT alias, alias_type, ambiguous, source, evidence_url FROM alias",
      "WHERE axp_id = ? ORDER BY alias_type = 'preferred' DESC, alias"), params = list(id))
    aliases$ambiguous <- aliases$ambiguous == 1

    trials <- DBI::dbGetQuery(con, paste(
      "SELECT l.nct_id, t.brief_title, t.overall_status, t.phases, t.start_date,",
      "t.primary_completion_date, t.enrollment_count, t.has_results, t.lead_sponsor,",
      "l.method AS link_method, l.confidence AS link_confidence, l.status AS link_status",
      "FROM trial_link l LEFT JOIN trial t ON t.nct_id = l.nct_id",
      "WHERE l.axp_id = ?",
      "ORDER BY l.status = 'auto' DESC, l.confidence DESC, t.start_date DESC, l.nct_id"),
      params = list(id))
    trials$has_results <- trials$has_results == 1

    # Events list the trial's auto-linked programs in axp_ids (a JSON list).
    recent <- registry_events(con, progs, "instr(e.axp_ids, ?) > 0",
                              list(paste0('"', id, '"')), REGISTRY_RECENT_CHANGES)

    registry_result(200, list(
      registry_release = release, query = query, program = program,
      virus = virus, approvals = approvals, aliases = aliases, trials = trials, recent_changes = recent,
      merged_from = hit$merged_from))
  })
}

# GET /changes: change events since a date, optionally for one program or one
# modality, at or above a significance. Arguments are already validated
# (agent/api.R): since is YYYY-MM-DD, modality a category name or "".
registry_changes <- function(path, since, program = "", modality = "",
                             significance = "info", limit = 100L) {
  registry_with_db(path, function(con, meta) {
    progs <- registry_programs(con)
    where <- "e.snapshot_date >= ?"
    params <- list(since)
    if (nzchar(program)) {
      hit <- registry_resolve(con, progs, program)
      if (!length(hit$ids)) {
        return(registry_result(404, list(error = "No program matches that ID or name.", query = program)))
      }
      if (length(hit$ids) > 1L) {
        return(registry_result(400, list(
          error = "That name matches several programs; give one of their AXP IDs.",
          query = program, candidates = registry_candidates(progs, hit$ids))))
      }
      where <- c(where, "instr(e.axp_ids, ?) > 0")
      params <- c(params, list(paste0('"', hit$ids, '"')))
    }
    if (nzchar(modality)) {
      where <- c(where, paste(
        "EXISTS (SELECT 1 FROM program p WHERE p.modality = ?",
        "AND instr(e.axp_ids, '\"' || p.axp_id || '\"') > 0)"))
      params <- c(params, list(modality))
    }
    if (identical(significance, "major")) {
      where <- c(where, "e.significance = 'major'")
    } else if (identical(significance, "minor")) {
      where <- c(where, "e.significance IN ('major', 'minor')")
    }
    events <- registry_events(con, progs, where, params, limit)
    registry_result(200, list(
      registry_release = registry_meta_value(meta, "registry_release"),
      latest_snapshot = registry_meta_value(meta, "latest_snapshot"),
      since = since, count = length(events), events = events))
  })
}
