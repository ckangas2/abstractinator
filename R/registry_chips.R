# R/registry_chips.R -- recognise registry programs in search results.
#
# A result whose title or abstract names a registered program gets a chip in
# the results table, linking to that program's registry page. The rules are
# the weekly linker's (tracker/build_registry.py, evidence_status; the
# matching itself is tracker/evidence.py's best_hits), so a chip appears
# exactly where the registry would count a link as confirmed:
#
#   - names are compared by alias key over every run of 1..8 words, so
#     "MRTX 1133" and "MRTX-1133" both find MRTX1133;
#   - in a title, any name of 4+ characters counts; outside a title, an INN,
#     brand or preferred name of 5+ characters, or any name of 6+ characters;
#   - a name of 5 characters or fewer must be written as itself ("ON-01",
#     "T-Vec"), not squashed from ordinary words ("on 01 January");
#   - ambiguous names never make a chip.
#
# Needs alias_key() and registry_db_path() from R/registry.R. Everything here
# fails quietly: no database, an old one or an error means no chips, never a
# broken results table.

REGISTRY_MIN_TEXT_KEY <- 4L                  # MIN_TEXT_KEY
REGISTRY_MIN_AUTO_KEY <- 5L                  # MIN_AUTO_TEXT_KEY
REGISTRY_MIN_CODE_KEY <- 6L                  # MIN_AUTO_CODE_KEY
REGISTRY_SHORT_KEY    <- 5L                  # SHORT_KEY (tracker/evidence.py)
REGISTRY_MAX_WINDOW   <- 8L                  # MAX_WINDOW
REGISTRY_AUTO_TYPES   <- c("preferred", "inn", "usan", "brand")
REGISTRY_MAX_CHIPS    <- 3L                  # per result, so a review naming 20 drugs stays readable

# Text as the alias key sees it: markup removed, marks dropped, NFKC, upper case.
registry_norm_text <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- stringi::stri_replace_all_regex(x, "<[^>]*>", " ")
  x <- stringi::stri_replace_all_regex(x, "[®™©]", "")
  x <- stringi::stri_replace_all_fixed(x, "∆", "Δ")
  stringi::stri_trans_nfkc(x)
}

# Every run of 1..max_window consecutive words of one text, joined, upper case:
# the keys a name written in this text could have.
registry_window_keys <- function(text, max_window = REGISTRY_MAX_WINDOW) {
  s <- stringi::stri_trans_toupper(registry_norm_text(text)[1], locale = "en_US")
  tokens <- stringi::stri_extract_all_regex(s, "[\\p{L}\\p{N}]+")[[1]]
  tokens <- tokens[!is.na(tokens)]
  n <- length(tokens)
  if (n == 0L) return(character(0))
  keys <- tokens
  if (n > 1L) {
    for (w in 2L:min(max_window, n)) {
      starts <- seq_len(n - w + 1L)
      parts <- lapply(0L:(w - 1L), function(j) tokens[starts + j])
      keys <- c(keys, do.call(paste0, parts))
    }
  }
  unique(keys)
}

# Is a short name written in the text as itself? Joined or hyphenated in any
# letter case ("ON-01", "on01", "T-Vec"), or split by spaces in the same case
# ("ON 01"); not ordinary words that happen to squash to the same key.
registry_as_written <- function(alias, text) {
  chars <- stringi::stri_extract_all_regex(registry_norm_text(alias)[1], "[\\p{L}\\p{N}]")[[1]]
  chars <- chars[!is.na(chars)]
  if (length(chars) == 0L) return(FALSE)
  body <- registry_norm_text(text)[1]
  around <- function(sep) paste0("(?<![\\p{L}\\p{N}])", paste(chars, collapse = sep), "(?![\\p{L}\\p{N}])")
  joined <- around("[\\-‐-―_./]*")
  spaced <- around("[\\s\\-‐-―_./]*")
  isTRUE(stringi::stri_detect_regex(body, joined, case_insensitive = TRUE)) ||
    isTRUE(stringi::stri_detect_regex(body, spaced))
}

# Would a name found in this field count? (evidence_status() == "auto")
registry_counts <- function(alias_type, key, field) {
  n <- nchar(key)
  named <- alias_type %in% REGISTRY_AUTO_TYPES & n >= REGISTRY_MIN_AUTO_KEY
  if (field == "title") named | n >= REGISTRY_MIN_TEXT_KEY else named | n >= REGISTRY_MIN_CODE_KEY
}

# The highest stage a program has reached: "approved", else the highest trial
# phase among its confirmed trials ("phase 3"), else "".
registry_stage_label <- function(phases, approved) {
  if (isTRUE(approved)) return("approved")
  p <- toupper(paste(phases, collapse = " "))
  for (k in 4:1) if (grepl(paste0("(^|[^A-Z_])PHASE", k), p)) return(paste("phase", k))
  if (grepl("EARLY_PHASE1", p, fixed = TRUE)) return("early phase 1")
  ""
}

# What the chips need from registry.sqlite, read once and reused until the
# database file changes (it is swapped in whole, weekly).
registry_chip_index <- local({
  cache <- new.env(parent = emptyenv())
  function(path = registry_db_path()) {
    if (!nzchar(path) || !file.exists(path)) return(NULL)
    mtime <- file.mtime(path)
    if (identical(cache$path, path) && identical(cache$mtime, mtime)) return(cache$index)
    index <- tryCatch({
      con <- DBI::dbConnect(RSQLite::SQLite(), path, flags = RSQLite::SQLITE_RO)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      tables <- DBI::dbListTables(con)
      names_df <- DBI::dbGetQuery(con, paste(
        "SELECT a.axp_id, a.alias, a.alias_key, a.alias_type, a.ambiguous,",
        "p.preferred_name, p.modality",
        "FROM alias a JOIN program p ON p.axp_id = a.axp_id",
        "WHERE p.status = 'active' AND a.ambiguous = 0 AND length(a.alias_key) >= ?"),
        params = list(REGISTRY_MIN_TEXT_KEY))
      family <- if ("virus" %in% tables)
        DBI::dbGetQuery(con, "SELECT axp_id, virus_family FROM virus") else
          data.frame(axp_id = character(0), virus_family = character(0))
      approved <- if ("approval" %in% tables)
        DBI::dbGetQuery(con, "SELECT DISTINCT axp_id FROM approval WHERE status IN ('approved', 'conditional')")$axp_id else
          character(0)
      phases <- if (all(c("trial", "trial_link") %in% tables))
        DBI::dbGetQuery(con, paste(
          "SELECT l.axp_id, t.phases FROM trial_link l JOIN trial t ON t.nct_id = l.nct_id",
          "WHERE l.status = 'auto'")) else
          data.frame(axp_id = character(0), phases = character(0))
      ids <- unique(names_df$axp_id)
      programs <- data.frame(
        axp_id = ids,
        preferred_name = names_df$preferred_name[match(ids, names_df$axp_id)],
        family = family$virus_family[match(ids, family$axp_id)],
        stage = vapply(ids, function(id)
          registry_stage_label(phases$phases[phases$axp_id == id], id %in% approved), ""),
        stringsAsFactors = FALSE)
      programs$family[is.na(programs$family)] <- ""
      list(names = names_df, programs = programs)
    }, error = function(e) NULL)
    cache$path <- path
    cache$mtime <- mtime
    cache$index <- index
    index
  }
})

# The programs one result names: a data frame of axp_id and the name matched,
# best name first per program (title before abstract, then the longer name).
registry_match <- function(title, abstract, index) {
  none <- data.frame(axp_id = character(0), alias = character(0), stringsAsFactors = FALSE)
  if (is.null(index) || nrow(index$names) == 0L) return(none)
  found <- list()
  for (field in c("title", "abstract")) {
    text <- if (field == "title") title else abstract
    keys <- registry_window_keys(text)
    hit <- index$names[index$names$alias_key %in% keys, , drop = FALSE]
    if (nrow(hit) == 0L) next
    ok <- registry_counts(hit$alias_type, hit$alias_key, field)
    hit <- hit[ok, , drop = FALSE]
    if (nrow(hit) == 0L) next
    short <- nchar(hit$alias_key) <= REGISTRY_SHORT_KEY
    if (any(short)) {
      written <- vapply(seq_len(nrow(hit)), function(i)
        !short[i] || registry_as_written(hit$alias[i], text), TRUE)
      hit <- hit[written, , drop = FALSE]
    }
    if (nrow(hit) > 0L) found[[field]] <- data.frame(
      axp_id = hit$axp_id, alias = hit$alias, rank = (field == "title") * 1000 + nchar(hit$alias_key),
      stringsAsFactors = FALSE)
  }
  if (length(found) == 0L) return(none)
  res <- do.call(rbind, found)
  res <- res[order(-res$rank), , drop = FALSE]
  res <- res[!duplicated(res$axp_id), , drop = FALSE]
  data.frame(axp_id = res$axp_id, alias = res$alias, stringsAsFactors = FALSE)
}

# One chip: the name as the registry writes it, and the stage; the tooltip
# gives the preferred name, the virus family and the ID.
registry_chip_html <- function(axp_id, alias, programs) {
  p <- programs[programs$axp_id == axp_id, , drop = FALSE]
  if (nrow(p) == 0L) return("")
  label <- if (nzchar(p$stage[1])) paste0(alias, " · ", p$stage[1]) else alias
  tip <- paste(c(p$preferred_name[1], if (nzchar(p$family[1])) p$family[1], axp_id), collapse = " · ")
  paste0('<a class="program-chip" href="registry/', axp_id, '.html" target="_blank" rel="noopener" ',
         'title="', htmltools::htmlEscape(tip, attribute = TRUE), '">',
         htmltools::htmlEscape(label), '</a>')
}

# Chips for every result (vectorised over rows): HTML, "" where none.
registry_programs_html <- function(titles, abstracts, index = registry_chip_index(),
                                   max_chips = REGISTRY_MAX_CHIPS) {
  n <- length(titles)
  if (is.null(index) || n == 0L) return(rep("", n))
  out <- character(n)
  for (i in seq_len(n)) {
    m <- tryCatch(registry_match(titles[i], abstracts[i], index), error = function(e) NULL)
    if (is.null(m) || nrow(m) == 0L) next
    m <- utils::head(m, max_chips)
    out[i] <- paste(vapply(seq_len(nrow(m)), function(j)
      registry_chip_html(m$axp_id[j], m$alias[j], index$programs), ""), collapse = " ")
  }
  out
}
