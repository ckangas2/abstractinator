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

reading_list_markdown <- function(items, exported = Sys.Date()) {
  n <- length(items)
  out <- c("# Abstractinator reading list", "",
           sprintf("Exported %s from https://abstractinator.me · %d %s",
                   format(exported), n, if (n == 1) "item" else "items"),
           "",
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
              Bacterium = md_field(it, "primary_bacteria"))
    tags <- tags[!is.na(tags) & tags != "Non-descript"]
    if (length(tags)) {
      out <- c(out, paste(sprintf("**%s:** %s", names(tags), md_escape(tags)), collapse = " · "), "")
    }

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
