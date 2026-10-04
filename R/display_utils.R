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
