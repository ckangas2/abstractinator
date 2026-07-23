# db_utils_local_cache.R
# Protocol: Relational Knowledge Base & Blob Caching
# Architecture: Dual-Write (Relational for Agents, Blobs for UI Speed)

library(RSQLite)
library(digest)
library(dplyr)

# Configuration
CACHE_DB_PATH <- "data/abstractinator.sqlite"

# --- DATABASE INITIALIZATION ---
init_cache_db <- function() {
  if (!dir.exists("data")) dir.create("data", recursive = TRUE)
  
  conn <- dbConnect(SQLite(), CACHE_DB_PATH)
  on.exit(dbDisconnect(conn))
  
  # TABLE 1: The Knowledge Base (Relational)
  # Optimized for AI agents to perform direct SQL queries.
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS articles (
      article_id TEXT PRIMARY KEY,
      title TEXT,
      abstract TEXT,
      authors TEXT,
      publication_date TEXT,
      url TEXT,
      doi TEXT,
      source TEXT,
      is_bioinformatics INTEGER,
      primary_cell TEXT,
      primary_virus TEXT,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  ")
  
  # Indexing for Agent performance
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_title ON articles(title)")
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_abstract ON articles(abstract)")
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_source ON articles(source)")

  # TABLE 2: The Search Cache (Blobs)
  # Optimized for Human UI speed.
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS search_cache (
      cache_key TEXT PRIMARY KEY,
      data_blob BLOB,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  ")
}

# Initialize on load
init_cache_db()

# --- KEY GENERATION ---
get_cache_key <- function(search_term, has_elsevier = FALSE, has_uspto = FALSE, has_core = FALSE) {
  clean_term <- tolower(trimws(search_term))
  signature <- paste0(
    clean_term, 
    "|elsevier:", isTRUE(has_elsevier), 
    "|uspto:", isTRUE(has_uspto),
    "|core:", isTRUE(has_core)
  )
  return(digest::digest(signature, algo = "md5"))
}

# --- CHECK ---
check_local_cache <- function(search_term, elsevier_key = NULL, uspto_key = NULL, core_key = NULL, max_age_days = 7) {
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  key <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  conn <- dbConnect(SQLite(), CACHE_DB_PATH)
  on.exit(dbDisconnect(conn))
  
  res <- dbGetQuery(conn, "SELECT timestamp FROM search_cache WHERE cache_key = ?", params = list(key))
  if (nrow(res) == 0) return(FALSE)
  
  last_mod_date <- as.POSIXct(res$timestamp, tz = "UTC")
  age_in_days <- as.numeric(difftime(Sys.time(), last_mod_date, units = "days"))
  return(age_in_days <= max_age_days)
}

# --- FETCH ---
fetch_from_cache <- function(search_term, elsevier_key = NULL, uspto_key = NULL, core_key = NULL) {
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  key <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  message(sprintf("[Cache] Fetching UI Blob: %s", search_term))
  
  conn <- dbConnect(SQLite(), CACHE_DB_PATH)
  on.exit(dbDisconnect(conn))
  res <- dbGetQuery(conn, "SELECT data_blob FROM search_cache WHERE cache_key = ?", params = list(key))
  if (nrow(res) == 0) return(NULL)
  
  tryCatch({
    unserialize(res$data_blob[[1]])
  }, error = function(e) {
    warning(paste("[Cache] Deserialization failed:", e$message))
    return(NULL)
  })
}

# --- SAVE (The Dual-Write Logic) ---
save_to_cache <- function(search_term, data, elsevier_key = NULL, uspto_key = NULL, core_key = NULL) {
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  key <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  conn <- dbConnect(SQLite(), CACHE_DB_PATH)
  on.exit(dbDisconnect(conn))

  # --- WRITE 1: The Relational Knowledge Base (for Agents) ---
  # We use a Unique ID based on DOI or Title for the knowledge base
  message("[Cache] Updating Agent Knowledge Base...")
  
  # Prepare data for SQL insertion
  # Ensure we have a stable unique ID per article
  # Prepare data for SQL insertion with deterministic IDs
  kb_data <- data %>%
    mutate(
      # Generate a deterministic hash if DOI and URL are missing
      fallback_hash = purrr::map2_chr(Title, Authors, function(t, a) {
        digest::digest(paste(t, a), algo = "md5")
      }),
      article_id = coalesce(DOI, URL, fallback_hash),
      is_bioinformatics = as.integer(is_bioinformatics)
    ) %>%
    select(
      article_id, title = Title, abstract = Abstract, authors = Authors, 
      publication_date = PublicationDate, url = URL, doi = DOI, source = Source,
      is_bioinformatics, primary_cell = primary_cell, primary_virus = primary_virus
    )

  # Use UPSERT (Insert or Replace) to update existing records with new data/tags
  dbWriteTable(conn, "tmp_articles", kb_data, overwrite = TRUE)
  dbExecute(conn, "
    INSERT OR REPLACE INTO articles (article_id, title, abstract, authors, publication_date, url, doi, source, is_bioinformatics, primary_cell, primary_virus)
    SELECT * FROM tmp_articles
  ")
  dbExecute(conn, "DROP TABLE tmp_articles")

  # --- WRITE 2: The UI Blob (for Humans) ---
  message("[Cache] Saving UI Snapshot...")
  blob <- serialize(data, connection = NULL)
  tryCatch({
    dbExecute(conn, "INSERT OR REPLACE INTO search_cache (cache_key, data_blob, timestamp) VALUES (?, ?, CURRENT_TIMESTAMP)", 
              params = list(key, list(blob)))
    TRUE
  }, error = function(e) {
    warning(paste("[Cache] Blob Save failed:", e$message))
    FALSE
  })
}

# Compatibility wrappers for existing calls in app.R / orchestrate_extraction.R
check_s3_cache <- check_local_cache
fetch_from_s3   <- fetch_from_cache
save_to_s3     <- save_to_cache
