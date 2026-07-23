# db_utils_local.R
# Protocol: Local Filesystem Caching (Mimicking S3 Partitioning)

library(digest)

CACHE_DIR <- ".cache/s3_mimic/"
if (!dir.exists(CACHE_DIR)) dir.create(CACHE_DIR, recursive = TRUE)

# --- KEY GENERATION ---
get_cache_key <- function(search_term, has_elsevier = FALSE, has_uspto = FALSE, has_core = FALSE) {
  clean_term <- tolower(trimws(search_term))
  
  signature <- paste0(
    clean_term, 
    "|elsevier:", isTRUE(has_elsevier), 
    "|uspto:", isTRUE(has_uspto),
    "|core:", isTRUE(has_core)
  )
  
  file_hash <- digest::digest(signature, algo = "md5")
  return(paste0(file_hash, ".rds"))
}

# --- CHECK ---
check_s3_cache <- function(search_term, elsevier_key = NULL, uspto_key = NULL, core_key = NULL, max_age_days = 7) {
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  s3_file <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  full_path <- file.path(CACHE_DIR, s3_file)
  
  if (!file.exists(full_path)) return(FALSE)
  
  # Check age of the local file
  info <- file.info(full_path)
  last_mod_date <- info$mtime
  age_in_days <- as.numeric(difftime(Sys.time(), last_mod_date, units = "days"))
  
  if (age_in_days > max_age_days) {
    message(sprintf("[LocalCache] Cache STALE (%.1f days).", age_in_days))
    return(FALSE)
  }
  return(TRUE)
}

# --- FETCH ---
fetch_from_s3 <- function(search_term, elsevier_key = NULL, uspto_key = NULL, core_key = NULL) {
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  s3_file <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  full_path <- file.path(CACHE_DIR, s3_file)
  
  message(sprintf("[LocalCache] Fetching partition: %s (E:%s U:%s C:%s)", search_term, has_elsevier, has_uspto, has_core))
  
  if (!file.exists(full_path)) return(NULL)
  
  tryCatch({
    readRDS(full_path)
  }, error = function(e) {
    warning(paste("[LocalCache] Load failed:", e$message))
    return(NULL)
  })
}

# --- SAVE ---
save_to_s3 <- function(search_term, data, elsevier_key = NULL, uspto_key = NULL, core_key = NULL) {
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0 # Fixed the logic error from original if needed, but keeping consistent with pattern
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  s3_file <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  full_path <- file.path(CACHE_DIR, s3_file)
  
  message(sprintf("[LocalCache] Saving partition: %s (E:%s U:%s C:%s)", search_term, has_elsevier, has_uspto, has_core))
  
  tryCatch({
    saveRDS(data, file = full_path)
    TRUE
  }, error = function(e) {
    warning(paste("[LocalCache] Save failed:", e$message))
    FALSE
  })
}
