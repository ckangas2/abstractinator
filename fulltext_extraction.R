# fulltext_extraction.R
# Open-access full text from Europe PMC, for one article at a time.
#
# Only the OA subset is available this way. A paywalled article returns a
# "not_open_access" status with its DOI rather than an error, so a caller can
# tell "we will not fetch this" from "something broke".
#
# Why this exists: an agent can find a paper's URL easily, but getting clean
# text out of a publisher page is the hard part. EPMC's JATS XML is already
# clean, so this is the one thing the search tool cannot do for itself.
#
# Cost note: a fetch is one HTTP GET plus XML parsing - cheaper than the search
# that found the article. The reason it is capped and cached is not local CPU,
# it is EBI's rate limits. A looping agent pulling hundreds of full texts an
# hour looks like bulk harvesting from their side, and being blocked would take
# the search tool down with it.

FULLTEXT_MAX_CHARS_DEFAULT <- 20000L
FULLTEXT_MAX_CHARS_CEILING <- 100000L
FULLTEXT_CACHE_DAYS        <- 30L     # full text does not change once published

# Identify ourselves so EBI emails rather than blocks.
FULLTEXT_UA <- "Abstractinator/2.0 (+https://abstractinator.me)"

fulltext_cache_dir <- function() {
  base <- if (exists("CACHE_DIR", envir = globalenv())) {
    get("CACHE_DIR", envir = globalenv())
  } else {
    file.path(".cache", "s3_mimic")
  }
  file.path(base, "fulltext")
}

.ft_cache_path <- function(pmcid) {
  file.path(fulltext_cache_dir(), paste0(pmcid, ".json"))
}

.ft_cache_read <- function(pmcid, max_age_days = FULLTEXT_CACHE_DAYS) {
  p <- .ft_cache_path(pmcid)
  if (!file.exists(p)) return(NULL)
  age <- as.numeric(difftime(Sys.time(), file.mtime(p), units = "days"))
  if (age > max_age_days) return(NULL)
  tryCatch(jsonlite::fromJSON(p), error = function(e) NULL)
}

.ft_cache_write <- function(rec) {
  tryCatch({
    d <- fulltext_cache_dir()
    if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
    writeLines(jsonlite::toJSON(rec, auto_unbox = TRUE), .ft_cache_path(rec$pmcid))
    TRUE
  }, error = function(e) FALSE)
}

#' Look up a PMCID from a DOI via the EPMC search endpoint.
#' Returns NA_character_ when the article is not in Europe PMC.
resolve_pmcid_from_doi <- function(doi) {
  doi <- trimws(as.character(doi))
  if (!nzchar(doi)) return(NA_character_)
  doi <- sub("^https?://(dx\\.)?doi\\.org/", "", tolower(doi))

  url <- paste0(
    "https://www.ebi.ac.uk/europepmc/webservices/rest/search",
    "?query=", utils::URLencode(sprintf('DOI:"%s"', doi), reserved = TRUE),
    "&format=json&pageSize=1&resultType=lite"
  )
  out <- tryCatch({
    resp <- httr2::req_perform(
      httr2::req_user_agent(
        httr2::req_timeout(httr2::request(url), 20),
        FULLTEXT_UA
      )
    )
    jsonlite::fromJSON(httr2::resp_body_string(resp), flatten = TRUE)
  }, error = function(e) NULL)

  if (is.null(out)) return(NA_character_)
  res <- out$resultList$result
  if (is.null(res) || length(res) == 0) return(NA_character_)
  if (is.data.frame(res)) {
    if (!"pmcid" %in% names(res)) return(NA_character_)
    v <- res$pmcid[1]
  } else {
    v <- res[[1]]$pmcid
  }
  if (is.null(v) || length(v) == 0 || is.na(v) || !nzchar(v)) return(NA_character_)
  as.character(v)
}

#' Parse JATS XML into readable sectioned text.
#' Only DIRECT child <p> of each <sec> is taken: .//p would re-collect the
#' paragraphs of nested subsections and duplicate large blocks of the paper.
.ft_parse_jats <- function(xml_doc) {
  sections <- xml2::xml_find_all(xml_doc, ".//body//sec")

  if (length(sections) == 0) {
    body <- xml2::xml_find_first(xml_doc, ".//body")
    if (inherits(body, "xml_missing")) return(NA_character_)
    txt <- xml2::xml_text(body, trim = TRUE)
    return(if (nzchar(txt)) txt else NA_character_)
  }

  parts <- vapply(sections, function(sec) {
    title <- xml2::xml_text(xml2::xml_find_first(sec, "./title"), trim = TRUE)
    if (is.na(title) || !nzchar(title)) title <- "Section"
    paras <- xml2::xml_find_all(sec, "./p")
    content <- paste(xml2::xml_text(paras, trim = TRUE), collapse = " ")
    if (nzchar(content)) sprintf("--- %s ---\n%s", title, content) else NA_character_
  }, character(1))

  parts <- parts[!is.na(parts)]
  if (!length(parts)) return(NA_character_)
  paste(parts, collapse = "\n\n")
}

#' Fetch open-access full text for one PMCID.
#'
#' @return list(pmcid, status, chars, truncated, full_text, error)
#'   status is "success", "not_open_access", or "failed".
fetch_epmc_fulltext <- function(pmcid,
                                max_chars = FULLTEXT_MAX_CHARS_DEFAULT,
                                use_cache = TRUE) {

  pmcid <- toupper(trimws(as.character(pmcid)))
  if (!grepl("^PMC[0-9]+$", pmcid)) {
    return(list(pmcid = pmcid, status = "failed",
                error = "pmcid must look like PMC1234567"))
  }

  max_chars <- suppressWarnings(as.integer(max_chars))
  if (is.na(max_chars)) max_chars <- FULLTEXT_MAX_CHARS_DEFAULT
  max_chars <- max(500L, min(max_chars, FULLTEXT_MAX_CHARS_CEILING))

  # The cache stores the WHOLE text; max_chars is applied on the way out, so
  # one caller asking for 5k does not cap what the next caller can read.
  cached <- if (use_cache) .ft_cache_read(pmcid) else NULL
  if (!is.null(cached) && identical(cached$status, "success")) {
    return(.ft_finish(cached, max_chars, from_cache = TRUE))
  }
  if (!is.null(cached) && identical(cached$status, "not_open_access")) {
    return(c(as.list(cached), list(from_cache = TRUE)))
  }

  url <- sprintf("https://www.ebi.ac.uk/europepmc/webservices/rest/%s/fullTextXML", pmcid)

  req <- httr2::request(url)
  req <- httr2::req_timeout(req, 60)
  req <- httr2::req_user_agent(req, FULLTEXT_UA)
  # req_retry's default only treats 429/503 as transient, so a 404 (article not
  # in the OA subset) fails immediately instead of being retried three times.
  req <- httr2::req_retry(req, max_tries = 3, backoff = function(i) 2^i)
  req <- httr2::req_error(req, is_error = function(resp) FALSE)  # inspect status ourselves

  resp <- tryCatch(httr2::req_perform(req),
                   error = function(e) structure(list(msg = conditionMessage(e)),
                                                 class = "ft_error"))
  if (inherits(resp, "ft_error")) {
    return(list(pmcid = pmcid, status = "failed", error = resp$msg))
  }

  code <- httr2::resp_status(resp)
  if (code == 404) {
    rec <- list(pmcid = pmcid, status = "not_open_access",
                error = "No open-access full text in Europe PMC for this article.",
                fetched = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
    .ft_cache_write(rec)
    return(c(rec, list(from_cache = FALSE)))
  }
  if (code >= 400) {
    return(list(pmcid = pmcid, status = "failed",
                error = sprintf("Europe PMC returned HTTP %s", code)))
  }

  xml_doc <- tryCatch(httr2::resp_body_xml(resp), error = function(e) NULL)
  if (!inherits(xml_doc, "xml_document")) {
    return(list(pmcid = pmcid, status = "failed", error = "Malformed XML response"))
  }

  body_text <- .ft_parse_jats(xml_doc)
  if (is.na(body_text)) {
    return(list(pmcid = pmcid, status = "failed", error = "No body text found in the XML"))
  }

  rec <- list(
    pmcid     = pmcid,
    status    = "success",
    full_text = body_text,
    chars     = nchar(body_text),
    fetched   = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )
  .ft_cache_write(rec)
  .ft_finish(rec, max_chars, from_cache = FALSE)
}

.ft_finish <- function(rec, max_chars, from_cache) {
  ft <- rec$full_text
  txt <- if (is.null(ft) || length(ft) == 0 || is.na(ft[1])) "" else as.character(ft[1])
  total <- nchar(txt)
  truncated <- total > max_chars
  txt <- strip_invisible(txt)
  if (truncated) txt <- paste0(substr(txt, 1, max_chars), "\n\n[truncated]")
  list(
    pmcid      = rec$pmcid,
    status     = "success",
    from_cache = from_cache,
    chars      = nchar(txt),
    total_chars = total,
    truncated  = truncated,
    fetched    = if (is.null(rec$fetched)) NA_character_ else as.character(rec$fetched),
    full_text  = txt
  )
}
