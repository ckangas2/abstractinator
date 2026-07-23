library(httr2) # Upgraded to httr2 for native retries
library(jsonlite)
library(dplyr)
library(purrr)
library(arrow)

# --- CONFIGURATION ------------------------------------------------------------
LOCAL_DB_DIR <- "biorxiv_local_db"
START_YEAR  <- 2013
END_YEAR    <- as.integer(format(Sys.Date(), "%Y"))

# Create the local directory if it doesn't exist
if (!dir.exists(LOCAL_DB_DIR)) dir.create(LOCAL_DB_DIR)

# --- WORKER: Fetch a specific date range (Optimized to httr2) ---
get_content_data <- function(start_d, end_d) {
  date_fmt <- paste0(start_d, "/", end_d)
  servers <- c("biorxiv", "medrxiv")
  all_hits <- list()
  
  for (server in servers) {
    if (server == "medrxiv" && as.integer(substring(start_d, 1, 4)) < 2019) next
    
    cursor <- 0
    keep_going <- TRUE
    cat(paste0("  > Scanning ", server, " "))
    
    while(keep_going) {
      url <- paste0("https://api.biorxiv.org/details/", server, "/", date_fmt, "/", cursor, "/json")
      
      req <- request(url) %>%
        req_timeout(30) %>%
        req_retry(max_tries = 3, max_seconds = 60)
      
      resp <- tryCatch({
        req_perform(req)
      }, error = function(e) NULL)
      
      if (is.null(resp)) { cat("X"); break }
      
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
        
        # The bioRxiv /details/ endpoint has a strict maximum of 30 records per page
        if (length(chunk) < 30) {
          keep_going <- FALSE 
        } else {
          # Cursor must advance by exactly 30
          cursor <- cursor + 30
          
          # Adjust the console printing frequency to match the new 30-record pace
          if (cursor %% 300 == 0) cat(".") 
        }
      }
    }
    cat("\n")
  }
  if (length(all_hits) == 0) return(NULL)
  bind_rows(all_hits)
}

# ==============================================================================
# MAIN EXECUTION: Loop -> Flush to Disk (No pooling in RAM)
# ==============================================================================

years <- START_YEAR:END_YEAR
print(paste(">>> STARTING LOCAL HARVEST:", START_YEAR, "-", END_YEAR))

for (yr in years) {
  print(paste("--- Processing Year:", yr, "---"))
  start_d <- paste0(yr, "-01-01")
  end_d   <- paste0(yr, "-12-31")
  
  file_path <- file.path(LOCAL_DB_DIR, paste0("biorxiv_", yr, ".parquet"))
  
  # Skip if already downloaded (prevents re-downloading 13 years of data on a crash)
  if (file.exists(file_path)) {
    print(paste("    -> File already exists for", yr, "- Skipping."))
    next
  }
  
  year_data <- get_content_data(start_d, end_d)
  
  if (!is.null(year_data) && nrow(year_data) > 0) {
    print(paste("    -> Retrieved:", nrow(year_data), "records. Writing to disk..."))
    # Flush directly to SSD
    write_parquet(year_data, file_path)
    # Force Garbage Collection to clear RAM
    rm(year_data)
    gc()
  } else {
    print("    -> No records found.")
  }
}

print(">>> SUCCESS: Local Database Built.")
