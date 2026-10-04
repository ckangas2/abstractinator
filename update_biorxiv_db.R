library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(arrow)
library(stringr)
library(lubridate)

# --- 1. CONFIGURATION ---------------------------------------------------------
LOCAL_DB_DIR <- "biorxiv_local_db"
WEBHOOK_URL  <- Sys.getenv("DATA_WEBHOOK_URL") 

# --- 2. NOTIFICATION SYSTEM ---------------------------------------------------
send_discord_alert <- function(status, message) {
  timestamp <- Sys.time()
  log_msg <- paste0("[", timestamp, "] ", status, ": ", message)
  cat(log_msg, "\n") 
  
  if (nchar(WEBHOOK_URL) > 0) {
    color_code <- if(grepl("SUCCESS", status)) 5763719 else if(grepl("FAILURE", status)) 15548997 else 3447003
    
    tryCatch({
      payload <- list(
        content = paste0("**Abstractinator Update:** ", status),
        embeds = list(list(
          description = message,
          color = color_code,
          footer = list(text = paste("Time:", timestamp))
        ))
      )
      
      request(WEBHOOK_URL) %>%
        req_method("POST") %>%
        req_body_json(payload) %>%
        req_perform()
    }, error = function(e) cat("Webhook failed to fire.\n"))
  }
}

# --- 3. WORKER: FETCH NEW DATA ------------------------------------------------
get_content_data <- function(start_d, end_d) {
  date_fmt <- paste0(start_d, "/", end_d)
  servers <- c("biorxiv", "medrxiv")
  all_hits <- list()
  
  for (server in servers) {
    cursor <- 0
    keep_going <- TRUE
    
    while(keep_going) {
      url <- paste0("https://api.biorxiv.org/details/", server, "/", date_fmt, "/", cursor, "/json")
      
      req <- request(url) %>%
        req_timeout(30) %>%
        req_retry(max_tries = 3, max_seconds = 60)
      
      resp <- tryCatch({
        req_perform(req)
      }, error = function(e) NULL)
      
      if (is.null(resp)) { break }
      
      json <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
      chunk <- json$collection
      
      if (length(chunk) == 0) {
        keep_going <- FALSE
      } else {
        batch_df <- map_dfr(chunk, function(record) {
          tibble(
            DOI             = as.character(ifelse(is.null(record$doi), NA, record$doi)),
            Title           = as.character(ifelse(is.null(record$title), NA, record$title)),
            Abstract        = as.character(ifelse(is.null(record$abstract), NA, record$abstract)),
            Authors         = as.character(ifelse(is.null(record$authors), NA, record$authors)),
            Affiliations    = as.character(ifelse(is.null(record$author_corresponding_institution), NA, record$author_corresponding_institution)),
            PublicationDate = as.character(ifelse(is.null(record$date), NA, record$date)),
            Published_DOI   = {
              val <- record$published
              if (is.null(val) || val == "NA" || val == "") NA_character_ else as.character(val)
            },
            Source          = paste0("Preprint (", server, ")"),
            URL             = paste0("https://www.biorxiv.org/content/", record$doi, "v1")
          )
        })
        all_hits[[length(all_hits) + 1]] <- batch_df
        
        # FIXED PAGINATION LOGIC: 30 records maximum per page
        if (length(chunk) < 30) {
          keep_going <- FALSE 
        } else { 
          cursor <- cursor + 30 
        }
      }
    }
  }
  if (length(all_hits) == 0) return(NULL)
  bind_rows(all_hits)
}

# --- SAFE WRITE ---------------------------------------------------------------
# Write to a hidden temp file, then rename over the real one. The rename is
# atomic, so a search running at that moment sees either the old file or the
# new one, never a half-written file. (Arrow ignores files starting with ".")
write_parquet_atomic <- function(df, file_path) {
  tmp_path <- file.path(dirname(file_path), paste0(".", basename(file_path), ".tmp"))
  arrow::write_parquet(df, tmp_path)
  if (!file.rename(tmp_path, file_path)) stop("Could not replace ", file_path)
}

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

tryCatch({
  
  if (!dir.exists(LOCAL_DB_DIR)) {
    stop(sprintf("Local database directory '%s' not found. Run builder script first.", LOCAL_DB_DIR))
  }
  
  # 1. READ LATEST DATE FROM LOCAL DIRECTORY
  master_ds <- arrow::open_dataset(LOCAL_DB_DIR)
  
  latest_date_str <- master_ds %>% 
    select(PublicationDate) %>% 
    collect() %>%
    pull(PublicationDate) %>%
    max(na.rm = TRUE)
  
  start_date <- as.Date(latest_date_str) + 1
  end_date   <- Sys.Date()
  
  if (start_date > end_date) {
    send_discord_alert("SKIPPED", "Local Database is already up to date.")
    quit(save = "no")
  }
  
  # 2. FETCH NEW DATA
  send_discord_alert("STARTED", paste("Fetching updates from", start_date, "to", end_date))
  new_data <- get_content_data(as.character(start_date), as.character(end_date))
  
  # 3. YEAR-BY-YEAR PARTITION UPDATING
  if (!is.null(new_data) && nrow(new_data) > 0) {
    
    # Extract year to determine which partition files to update
    new_data <- new_data %>% mutate(Year = substring(PublicationDate, 1, 4))
    years_to_update <- unique(new_data$Year)
    
    for (yr in years_to_update) {
      yr_data <- new_data %>% filter(Year == yr) %>% select(-Year)
      file_path <- file.path(LOCAL_DB_DIR, paste0("biorxiv_", yr, ".parquet"))
      
      if (file.exists(file_path)) {
        # Load only the specific year into RAM, bind, and overwrite
        existing_df <- arrow::read_parquet(file_path)
        combined_df <- bind_rows(existing_df, yr_data) %>%
          distinct(DOI, .keep_all = TRUE) %>%
          arrange(desc(PublicationDate))
        
        write_parquet_atomic(combined_df, file_path)
      } else {
        # Create a new partition file if the year just rolled over
        write_parquet_atomic(yr_data %>% arrange(desc(PublicationDate)), file_path)
      }
    }
    
    send_discord_alert("SUCCESS", paste("Local database updated. Added", nrow(new_data), "new records."))
    
  } else {
    send_discord_alert("COMPLETE", "No new records found in API.")
  }
  
}, error = function(e) {
  send_discord_alert("CRITICAL FAILURE", e$message)
})