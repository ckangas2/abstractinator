# R/display_utils.R
# Display and export helpers for the Shiny app: HTML sanitizing, plain-text
# conversion for exports, and stable result IDs. Kept separate from app.R so
# they can be unit-tested (tests/testthat/test-display-utils.R).

# ==========================================================================
# DISPLAY SAFETY
# ==========================================================================
# Results tables render text as HTML (so titles can keep their italics), and that
# text comes from external databases. Escape everything, then re-allow only a few
# harmless formatting tags, so a malicious record can never inject scripts or links.
SAFE_HTML_TAGS <- "i|b|em|strong|sub|sup|br"

sanitize_html <- function(x, decode_entities = TRUE) {
  if (!is.character(x)) return(x)
  na <- is.na(x)
  out <- x
  
  # Some APIs send markup pre-escaped (&lt;i&gt;); decode once so it's handled
  # like real markup. (Skipped for JSON columns, where &quot; could break parsing.)
  if (decode_entities) {
    out <- gsub("&lt;", "<", out, fixed = TRUE)
    out <- gsub("&gt;", ">", out, fixed = TRUE)
    out <- gsub("&quot;", "\"", out, fixed = TRUE)
    out <- gsub("&#39;", "'", out, fixed = TRUE)
    out <- gsub("&amp;", "&", out, fixed = TRUE)
  }
  
  # Remove scripts/styles entirely (including their contents) and comments
  out <- gsub("<(script|style)\\b[^>]*>.*?</\\1\\s*>", "", out, perl = TRUE, ignore.case = TRUE)
  out <- gsub("<!--.*?-->", "", out, perl = TRUE)
  
  # Publisher XML (JATS) formatting -> plain formatting tags
  out <- gsub("<(/?)(?:jats:)?italic\\b[^<>]*>", "<\\1i>", out, perl = TRUE, ignore.case = TRUE)
  out <- gsub("<(/?)(?:jats:)?bold\\b[^<>]*>", "<\\1b>", out, perl = TRUE, ignore.case = TRUE)
  out <- gsub("<(/?)jats:(sub|sup)\\b[^<>]*>", "<\\1\\2>", out, perl = TRUE, ignore.case = TRUE)
  
  # Block-level tags become spaces, so paragraphs don't run together
  out <- gsub("</?(p|div|li|ul|ol|section|h[1-6]|jats:p|jats:title|jats:sec|jats:list-item)\\b[^<>]*>",
              " ", out, perl = TRUE, ignore.case = TRUE)
  
  # Allowed tags: strip any attributes (<i onmouseover=...> -> <i>)
  out <- gsub(paste0("<(/?)(", SAFE_HTML_TAGS, ")(\\s[^<>]*)?/?>"), "<\\1\\2>", out,
              perl = TRUE, ignore.case = TRUE)
  # Every other tag is removed, keeping the text inside it
  out <- gsub(paste0("</?(?!(?:", SAFE_HTML_TAGS, ")>)[A-Za-z][A-Za-z0-9:_.-]*(\\s[^<>]*)?/?>"), "", out,
              perl = TRUE, ignore.case = TRUE)
  out <- trimws(gsub("[ \t]{2,}", " ", out))
  
  # Escape what's left (stray < > & become text), then re-allow the safe tags
  out <- htmltools::htmlEscape(out)
  out <- gsub(paste0("&lt;(/?)(", SAFE_HTML_TAGS, ")&gt;"), "<\\1\\2>", out, ignore.case = TRUE)
  # Keep character entities like &#8211; from being double-escaped
  out <- gsub("&amp;(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]{1,30});", "&\\1;", out)
  out[na] <- NA_character_
  out
}

# Only plain http(s) links survive (blocks javascript: and other schemes)
sanitize_url <- function(x) {
  x <- as.character(x)
  ok <- !is.na(x) & grepl("^https?://", x, ignore.case = TRUE) & !grepl("[[:space:]\"'<>`]", x)
  x[!ok] <- NA_character_
  x
}

sanitize_results <- function(df) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0) return(df)
  for (col in names(df)) {
    if (col == "URL") {
      df[[col]] <- sanitize_url(df[[col]])
    } else if (col == "DOI") {
      df[[col]] <- gsub("[[:space:]\"'<>`]", "", as.character(df[[col]]))
    } else if (is.character(df[[col]])) {
      # AuthorAffiliations is JSON text: clean it, but don't decode entities inside it
      df[[col]] <- sanitize_html(df[[col]], decode_entities = (col != "AuthorAffiliations"))
    }
  }
  df
}

# Exports (CSV, Zotero, EndNote) want plain text, not display HTML
html_to_text <- function(x) {
  if (!is.character(x)) return(x)
  x <- gsub("<br\\s*/?>", "; ", x, ignore.case = TRUE)
  x <- gsub("<[^>]+>", "", x)
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&#39;", "'", x, fixed = TRUE)
  gsub("&amp;", "&", x, fixed = TRUE)
}
plain_text_item <- function(item) lapply(item, html_to_text)

# One stable ID per result (DOI, URL and title combined), used by the reading list.
# Grants and trials often have no DOI or URL, so neither works as an ID on its own.
make_item_key <- function(doi, url, title) {
  vapply(paste(doi, url, title, sep = "|"), digest::digest, character(1),
         algo = "md5", serialize = FALSE, USE.NAMES = FALSE)
}

# The website's date label for a clinical trial, e.g.
# "Start: 2024-01-12 | End: Ongoing | Status: RECRUITING". Trial records carry
# the parts as separate fields; this puts them back together for display.
trial_date_label <- function(start, end, status) {
  active <- !is.na(status) & grepl("Active|Recruiting|Enrolling", status, ignore.case = TRUE)
  end <- ifelse(active, "Ongoing", end)
  parts <- cbind(ifelse(is.na(start) | start == "", NA, paste0("Start: ", start)),
                 ifelse(is.na(end) | end == "", NA, paste0("End: ", end)),
                 ifelse(is.na(status) | status == "", NA, paste0("Status: ", status)))
  apply(parts, 1, function(p) paste(p[!is.na(p)], collapse = " | "))
}

# --- Markdown export of the reading list ------------------------------------
# For notes apps, GitHub and AI chats. Items are reading-list entries already
# passed through plain_text_item(). Third-party text is escaped so it reads as
# text in any Markdown renderer, never as links, emphasis or raw HTML.
md_escape <- function(x) gsub("([\\\\`*_\\[\\]<>])", "\\\\\\1", x, perl = TRUE)

# Percent-encode the characters that would end or break a Markdown link target.
# DOIs can legitimately contain parentheses, e.g. 10.1016/S0140-6736(20)30183-5.
md_link_target <- function(x) {
  x <- gsub("%", "%25", x, fixed = TRUE)
  x <- gsub(" ", "%20", x, fixed = TRUE)
  x <- gsub("(", "%28", x, fixed = TRUE)
  x <- gsub(")", "%29", x, fixed = TRUE)
  x <- gsub("<", "%3C", x, fixed = TRUE)
  gsub(">", "%3E", x, fixed = TRUE)
}

md_field <- function(item, name) {
  v <- item[[name]]
  if (is.null(v) || length(v) == 0 || is.na(v[1])) return(NA_character_)
  v <- trimws(as.character(v[1]))
  if (!nzchar(v)) NA_character_ else v
}

# versions: optional c(app = "2.1.0", aliases = "<fingerprint>"), printed so
# a reader can tell which release and vocabulary produced the tags.
reading_list_markdown <- function(items, exported = Sys.Date(), versions = NULL) {
  n <- length(items)
  out <- c("# Abstractinator reading list", "",
           sprintf("Exported %s from https://abstractinator.me · %d %s",
                   format(exported), n, if (n == 1) "item" else "items"),
           "",
           if (length(versions)) c(sprintf("Abstractinator %s · tag vocabulary %s",
                                           versions[["app"]] %||% "?", versions[["aliases"]] %||% "?"), ""),
           "Abstracts are included for personal reference; copyright remains with the authors and publishers.",
           "")
  if (n == 0) return(c(out, "_The reading list is empty._"))

  for (i in seq_len(n)) {
    it <- items[[i]]
    title <- md_field(it, "Title")
    out <- c(out, "---", "", sprintf("## %d. %s", i, md_escape(if (is.na(title)) "Untitled" else title)), "")

    doi <- md_field(it, "DOI")
    url <- md_field(it, "URL")
    meta <- c(md_escape(md_field(it, "Authors")), md_field(it, "PublicationDate"),
              md_escape(md_field(it, "Source")),
              if (!is.na(doi)) sprintf("[doi:%s](https://doi.org/%s)", md_escape(doi), md_link_target(doi)))
    meta <- meta[!is.na(meta) & nzchar(meta)]
    if (length(meta)) out <- c(out, paste(meta, collapse = " · "), "")

    tags <- c(Cell = md_field(it, "primary_cell"), Virus = md_field(it, "primary_virus"),
              Bacterium = md_field(it, "primary_bacteria"), Therapy = md_field(it, "primary_modality"))
    tags <- tags[!is.na(tags) & tags != "Non-descript"]
    if (length(tags)) {
      out <- c(out, paste(sprintf("**%s:** %s", names(tags), md_escape(tags)), collapse = " · "), "")
    }

    # Provenance: which search found it, when the databases were queried, and
    # which copies from other databases were merged into this record.
    found_by <- md_field(it, "FoundBy")
    retrieved <- md_field(it, "RetrievedAt")
    if (!is.na(found_by)) {
      out <- c(out, paste0("*Found by the search \u201c", md_escape(found_by), "\u201d",
                           if (!is.na(retrieved)) paste0(", databases queried ", retrieved), ".*"), "")
    }
    interventions <- md_field(it, "Interventions")
    if (!is.na(interventions)) out <- c(out, paste0("*Tests:* ", md_escape(interventions)), "")
    merged <- md_field(it, "MergedFrom")
    if (!is.na(merged)) out <- c(out, paste0("*Also found as:* ", md_escape(merged)), "")

    abstract <- md_field(it, "Abstract")
    if (!is.na(abstract)) {
      lines <- strsplit(abstract, "\r?\n")[[1]]
      out <- c(out, paste0(">", ifelse(nzchar(trimws(lines)), paste0(" ", md_escape(lines)), "")), "")
    }
    # The record's own page, when it adds something to the DOI link (trials,
    # grants, preprints). Only http(s) links, so a bad URL can't become a script.
    if (!is.na(url) && grepl("^https?://", url, ignore.case = TRUE) &&
        (is.na(doi) || !grepl(doi, url, fixed = TRUE))) {
      out <- c(out, sprintf("[Source page](%s)", md_link_target(url)), "")
    }
  }
  out
}

# --- SOURCE COVERAGE -----------------------------------------------------------
# Turns the per-source counts from summarise_sources() into short labels such as
# "Europe PMC 50 of 12,431". Each database returns its top matches, not every
# match, so this says how big a sample each one contributed. Failed sources say
# so instead of silently showing nothing.
SOURCE_LABELS <- c(EPMC = "Europe PMC", OpenAlex = "OpenAlex",
                   `clinicaltrials.gov` = "ClinicalTrials.gov", bioRxiv = "bioRxiv/medRxiv",
                   NIH = "NIH RePORTER", NSF = "NSF", CORE = "CORE",
                   Patent = "PatentsView", Scopus = "Scopus")

source_coverage_items <- function(counts) {
  if (!is.data.frame(counts) || nrow(counts) == 0) return(character(0))
  fmt <- function(n) format(n, big.mark = ",", scientific = FALSE, trim = TRUE)
  vapply(seq_len(nrow(counts)), function(i) {
    src <- counts$source[i]
    label <- if (src %in% names(SOURCE_LABELS)) SOURCE_LABELS[[src]] else src
    n <- counts$retrieved[i]
    total <- counts$total[i]
    status <- counts$status[i]
    if (identical(status, "failed")) return(paste0(label, ": no response"))
    txt <- if (!is.na(total) && total >= n) {
      paste0(label, " ", fmt(n), " of ", fmt(total))
    } else {
      paste0(label, " ", fmt(n))
    }
    if (identical(status, "partial")) txt <- paste0(txt, " (stopped early)")
    txt
  }, character(1))
}

# Sources that failed or stopped part-way, as readable names.
incomplete_source_labels <- function(counts) {
  if (!is.data.frame(counts) || nrow(counts) == 0) return(character(0))
  bad <- counts$source[counts$status %in% c("failed", "partial")]
  unname(ifelse(bad %in% names(SOURCE_LABELS), SOURCE_LABELS[bad], bad))
}

# --- THERAPEUTIC LANDSCAPE ("what's been tried") ------------------------------
# Every record is placed on the path from idea to clinic: a funded grant, a
# preprint, a paper, or a trial by phase. Combined with its therapy modality
# this answers "what has been tried for X, and how far has it got?" within the
# retrieved records.
LANDSCAPE_STAGES <- c("Grant", "Preprint", "Paper", "Trial: phase 1", "Trial: phase 2",
                      "Trial: phase 3+", "Trial: no phase")
RECRUITING_STATUSES <- c("RECRUITING", "NOT_YET_RECRUITING", "ENROLLING_BY_INVITATION")

evidence_stage <- function(source, phase) {
  src <- as.character(source)
  src[is.na(src)] <- ""
  out <- rep("Paper", length(src))
  out[src %in% c("NIH", "NSF")] <- "Grant"
  out[grepl("^(preprint|biorxiv|medrxiv)", src, ignore.case = TRUE)] <- "Preprint"
  out[src == "Patent"] <- "Patent"
  trial <- src == "clinicaltrials.gov"
  # The highest phase named: "Phase 1/Phase 2" is phase 2, "Early Phase 1" is 1.
  top <- vapply(regmatches(as.character(phase), gregexpr("[0-9]", as.character(phase))),
                function(d) if (length(d)) max(as.integer(d)) else NA_integer_, integer(1))
  out[trial] <- ifelse(is.na(top[trial]), "Trial: no phase",
                ifelse(top[trial] <= 1, "Trial: phase 1",
                ifelse(top[trial] == 2, "Trial: phase 2", "Trial: phase 3+")))
  out
}

# One row per therapy modality: how many records sit at each stage, how many
# trials are recruiting, and the total. Records count under their main
# modality (primary_modality), so each record is counted once.
therapy_landscape <- function(df) {
  empty <- data.frame(Therapy = character(0), Total = integer(0))
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0 || !"primary_modality" %in% names(df)) return(empty)
  col <- function(nm) if (nm %in% names(df)) df[[nm]] else rep(NA_character_, nrow(df))
  d <- data.frame(modality = as.character(df$primary_modality),
                  stage = evidence_stage(col("Source"), col("Phase")),
                  recruiting = toupper(as.character(col("TrialStatus"))) %in% RECRUITING_STATUSES &
                    col("Source") %in% "clinicaltrials.gov",
                  stringsAsFactors = FALSE)
  d <- d[!is.na(d$modality) & d$modality != "Non-descript", , drop = FALSE]
  if (nrow(d) == 0) return(empty)
  stages <- c(LANDSCAPE_STAGES, setdiff(unique(d$stage), LANDSCAPE_STAGES))
  stages <- stages[stages %in% d$stage]
  tab <- table(factor(d$modality), factor(d$stage, levels = stages))
  out <- data.frame(Therapy = rownames(tab), stringsAsFactors = FALSE, check.names = FALSE)
  for (st in stages) out[[st]] <- as.integer(tab[, st])
  out$Recruiting <- as.integer(tapply(d$recruiting, factor(d$modality), sum)[out$Therapy])
  out$Total <- as.integer(rowSums(tab))
  out <- out[order(-out$Total, tolower(out$Therapy), method = "radix"), , drop = FALSE]
  rownames(out) <- NULL
  out
}

# The trials in a result set, most advanced first: what each one tests, its
# phase and status, and the conditions studied. 'modality' narrows the list
# to trials whose interventions or text match that therapy (main or not).
trials_tried <- function(df, modality = NULL) {
  cols <- c("Trial", "Interventions", "Phase", "Status", "Conditions", "Therapy", "Start")
  empty <- setNames(data.frame(matrix(character(0), ncol = length(cols))), cols)
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0 || !"Source" %in% names(df)) return(empty)
  t <- df[df$Source %in% "clinicaltrials.gov", , drop = FALSE]
  if (nrow(t) == 0) return(empty)
  col <- function(nm) if (nm %in% names(t)) as.character(t[[nm]]) else rep(NA_character_, nrow(t))
  if (!is.null(modality) && nzchar(modality) && modality != "All") {
    hits <- if ("modality_hits_combined" %in% names(t)) t$modality_hits_combined else vector("list", nrow(t))
    keep <- col("primary_modality") %in% modality |
      vapply(hits, function(h) modality %in% unlist(h), logical(1))
    t <- t[keep, , drop = FALSE]
    if (nrow(t) == 0) return(empty)
  }
  col <- function(nm) if (nm %in% names(t)) as.character(t[[nm]]) else rep(NA_character_, nrow(t))
  phase_rank <- vapply(regmatches(col("Phase"), gregexpr("[0-9]", col("Phase"))),
                       function(d) if (length(d)) max(as.integer(d)) else 0L, integer(1))
  status <- col("TrialStatus")
  status <- ifelse(is.na(status), NA_character_,
                   sub("^(.)", "\\U\\1", tolower(gsub("_", " ", status)), perl = TRUE))
  out <- data.frame(
    Trial = gsub("[^A-Za-z0-9]", "", col("NCTId")),
    Interventions = col("Interventions"),
    Phase = col("Phase"),
    Status = status,
    Conditions = col("Conditions"),
    Therapy = col("primary_modality"),
    Start = col("TrialStart"),
    stringsAsFactors = FALSE
  )
  out <- out[order(-phase_rank, -xtfrm(ifelse(is.na(out$Start), "", out$Start))), , drop = FALSE]
  rownames(out) <- NULL
  out
}

# --- SEARCH REPORT (Deduplicatinator) ------------------------------------------
# Per database: how many records it matched in total, how many were retrieved
# (its top N), how many survived deduplication as that database's copy, how
# many were merged into another copy, and whether it answered. 'counts' is
# summarise_sources() output (stored with cached results, so this stays right
# on a cache hit); 'dedup' is the deduplicated result.
source_key <- function(source) {
  s <- as.character(source)
  ifelse(grepl("^(preprint|biorxiv|medrxiv)", s, ignore.case = TRUE), "bioRxiv", s)
}

dedup_source_stats <- function(counts, dedup) {
  cols <- c("Source", "Matched", "Retrieved", "Unique", "Merged", "Status")
  if (!is.data.frame(counts) || nrow(counts) == 0) {
    return(setNames(data.frame(matrix(nrow = 0, ncol = length(cols))), cols))
  }
  kept <- if (is.data.frame(dedup) && nrow(dedup) && "Source" %in% names(dedup)) table(source_key(dedup$Source)) else table(character(0))
  uniq <- as.integer(ifelse(counts$source %in% names(kept), kept[counts$source], 0L))
  status <- c(ok = "OK", partial = "Stopped early", failed = "No response")[counts$status]
  out <- data.frame(
    Source = unname(ifelse(counts$source %in% names(SOURCE_LABELS), SOURCE_LABELS[counts$source], counts$source)),
    Matched = counts$total,
    Retrieved = as.integer(counts$retrieved),
    Unique = uniq,
    Merged = pmax(0L, as.integer(counts$retrieved) - uniq),
    Status = unname(ifelse(is.na(status), counts$status, status)),
    stringsAsFactors = FALSE
  )
  # Case-insensitive and locale-independent, so the order is the same everywhere.
  out <- out[order(-out$Retrieved, tolower(out$Source), method = "radix"), , drop = FALSE]
  rownames(out) <- NULL
  out
}

# The four headline numbers: matched in the databases, retrieved, merged as
# duplicates, unique works. 'matched_complete' is FALSE when a database didn't
# report its total, so the matched figure is a lower bound.
dedup_flow <- function(stats, n_unique) {
  if (!is.data.frame(stats) || nrow(stats) == 0) {
    return(list(matched = NA_real_, matched_complete = FALSE, retrieved = 0L, merged = 0L, unique = n_unique))
  }
  answered <- stats$Status != "No response"
  m <- stats$Matched[answered]
  retrieved <- sum(stats$Retrieved)
  list(matched = if (any(!is.na(m))) sum(m, na.rm = TRUE) else NA_real_,
       matched_complete = all(!is.na(m)) && all(answered),
       retrieved = retrieved,
       merged = max(0L, retrieved - n_unique),
       unique = n_unique)
}

# Trial phases in a result set, as one compact summary for the search report:
# c("Early Phase 1" = 1, "Phase 1" = 24, "Phase 1/2" = 12, ..., "Not applicable" = 5),
# earliest first. Observational studies have no phase by design; they are
# counted as "Not applicable" so the parts add up to the trial total.
trial_phase_summary <- function(df) {
  if (is.null(df) || !is.data.frame(df) || !"Source" %in% names(df)) return(integer(0))
  tr <- df[df$Source %in% "clinicaltrials.gov", , drop = FALSE]
  if (!nrow(tr)) return(integer(0))
  ph <- if ("Phase" %in% names(tr)) as.character(tr$Phase) else rep(NA_character_, nrow(tr))
  ph[is.na(ph) | !nzchar(trimws(ph))] <- "Not applicable"
  ph <- gsub("Phase (\\d)/Phase (\\d)", "Phase \\1/\\2", ph, perl = TRUE)
  counts <- table(ph)
  nm <- names(counts)
  first_digit <- suppressWarnings(as.numeric(sub("^\\D*(\\d).*$", "\\1", nm, perl = TRUE)))
  first_digit[!grepl("\\d", nm, perl = TRUE)] <- Inf
  early <- grepl("^Early", nm, perl = TRUE)
  ord <- order(nm == "Not applicable", first_digit - 0.5 * early, nm, method = "radix")
  setNames(as.integer(counts[ord]), nm[ord])
}
