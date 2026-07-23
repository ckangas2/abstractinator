# weekly_updater.R

# 0. INJECT ENVIRONMENT VARIABLES (Critical for headless Linux execution)
# Cron jobs do NOT inherit your .bashrc or default .Renviron. 
# You MUST explicitly point to your key file.
readRenviron("~/.openclaw/workspace/workspace-code-team/ABSTRACTINATOR_FINAL/.Renviron")

# 1. Load your existing ecosystem (AWS dependencies stripped)
# --- SOURCE EXTRACTORS ---
source("epmc_standalone_extraction.R")
source("CORE_extraction.R")
source("clinicaltrials.gov_extraction.R")
source("scopus_extraction.R")
source("biorxiv_extraction.R")
source("patentsview_extraction.R") 
source("deduplication.R")
source("scopus_abstract_extraction.R")
source("R/db_utils_local.R")
source("R/log_utils_local.R")
source("openalex_standalone_extraction.R")
source("aliases.R")           
source("orchestrate_extraction.R") 
source("generate_plot.R")      
source("R/log_utils_local.R")
source("NIHReporter_extraction.R")
source("NSFAwards_extraction.R")

# CRITICAL FIX: Target the local SQLite dual-write cache, not S3
source("db_utils_local_cache.R") 

# 2. Run the chips
chips <- c("Oncolytic Virus", "T-VEC", "Melanoma", "scRNA-seq")

for (chip in chips) {
  message(sprintf("\n>>> [%s] Initiating Pipeline for: %s", Sys.time(), chip))
  
  tryCatch({
    orchestrate_data_extraction_cached(
      search_term = chip,
      update_progress = function(...) {} # Shunts Shiny UI updates to the void
    )
    message(sprintf("<<< [%s] Pipeline Complete for: %s", Sys.time(), chip))
  }, error = function(e) {
    message(sprintf("!!! FATAL PIPELINE ERROR on %s: %s", chip, e$message))
  })
  
  Sys.sleep(10) # API breather
}