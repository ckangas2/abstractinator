# db_utils_aws_S3.R
# Protocol: S3 Remote Caching (Partitioned by Access Level)

library(aws.s3)
library(digest)

CACHE_BUCKET <- Sys.getenv("S3_CACHE_BUCKET")
if (CACHE_BUCKET == "") warning("CRITICAL: S3_CACHE_BUCKET not found.")

# --- KEY GENERATION ---
get_cache_key <- function(search_term, has_elsevier = FALSE, has_uspto = FALSE, has_core = FALSE) {
  clean_term <- tolower(trimws(search_term))
  
  # Update Signature to include CORE
  signature <- paste0(
    clean_term, 
    "|elsevier:", isTRUE(has_elsevier), 
    "|uspto:", isTRUE(has_uspto),
    "|core:", isTRUE(has_core) # <--- Added
  )
  
  file_hash <- digest::digest(signature, algo = "md5")
  return(paste0(file_hash, ".rds"))
}

# --- CHECK ---
check_s3_cache <- function(search_term, elsevier_key = NULL, uspto_key = NULL, core_key = NULL, max_age_days = 7) {
  if (CACHE_BUCKET == "") return(FALSE)
  
  # Resolve Booleans
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0 # <--- Added
  
  s3_file <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  
  meta <- tryCatch({
    aws.s3::head_object(object = s3_file, bucket = CACHE_BUCKET)
  }, error = function(e) return(NULL))
  
  if (is.null(meta)) return(FALSE)
  
  last_mod_str <- attr(meta, "last-modified")
  if (!is.null(last_mod_str)) {
    last_mod_date <- as.POSIXct(last_mod_str, format = "%a, %d %b %Y %H:%M:%S", tz = "GMT")
    age_in_days <- as.numeric(difftime(Sys.time(), last_mod_date, units = "days"))
    if (age_in_days > max_age_days) {
      message(sprintf("[S3] Cache STALE (%.1f days).", age_in_days))
      return(FALSE)
    }
  }
  return(TRUE)
}

# --- FETCH ---
fetch_from_s3 <- function(search_term, elsevier_key = NULL, uspto_key = NULL, core_key = NULL) {
  if (CACHE_BUCKET == "") return(NULL)
  
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  s3_file <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  
  message(sprintf("[S3] Fetching partition: %s (E:%s U:%s C:%s)", search_term, has_elsevier, has_uspto, has_core))
  
  tryCatch({
    aws.s3::s3read_using(FUN = readRDS, object = s3_file, bucket = CACHE_BUCKET)
  }, error = function(e) {
    warning(paste("[S3] Download failed:", e$message))
    return(NULL)
  })
}

# --- SAVE ---
save_to_s3 <- function(search_term, data, elsevier_key = NULL, uspto_key = NULL, core_key = NULL) {
  if (CACHE_BUCKET == "") return(FALSE)
  
  has_elsevier <- !is.null(elsevier_key) && nchar(trimws(elsevier_key)) > 0
  has_uspto    <- !is.null(uspto_key) && nchar(trimws(uspto_key)) > 0
  has_core     <- !is.null(core_key) && nchar(trimws(core_key)) > 0
  
  s3_file <- get_cache_key(search_term, has_elsevier, has_uspto, has_core)
  
  message(sprintf("[S3] Uploading partition: %s (E:%s U:%s C:%s)", search_term, has_elsevier, has_uspto, has_core))
  
  tryCatch({
    aws.s3::s3write_using(x = data, FUN = saveRDS, object = s3_file, bucket = CACHE_BUCKET)
    TRUE
  }, error = function(e) {
    warning(paste("[S3] Upload failed:", e$message))
    FALSE
  })
}