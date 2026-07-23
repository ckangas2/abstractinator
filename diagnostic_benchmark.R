# ==============================================================================
# DIAGNOSTIC PROTOCOL: API LATENCY & MEMORY PROFILING
# ==============================================================================
library(dplyr)
library(purrr)
library(pryr) # Standard for memory tracking (install.packages("pryr"))
library(tictoc)
library(future)

# 1. SETUP & SOURCING ----------------------------------------------------------
cat("\n[1/4] Loading Extraction Protocols...\n")

# Source your extractors (adjust filenames if needed based on your folder)
source("epmc_standalone_extraction.R")
source("CORE_extraction.R")
source("clinicaltrials.gov_extraction.R")
source("biorxiv_extraction.R")
source("patentsview_extraction.R") 
source("openalex_standalone_extraction.R")
# We also need the deduplicator to test downstream cost
source("deduplication.R") 

# 2. CONFIGURATION -------------------------------------------------------------
SEARCH_TERM <- "oncolytic virus" # Use a term that guarantees hits
LIMIT       <- 50                # Keep it moderate to measure latency, not just volume
KEYS        <- list(
  CORE    = Sys.getenv("CORE_API_KEY"),
  USPTO   = Sys.getenv("USPTO_API_KEY"),
  ELSEVIER= Sys.getenv("ELSEVIER_API_KEY")
)

# 3. BENCHMARKING FUNCTION -----------------------------------------------------
benchmark_task <- function(name, expr) {
  cat(sprintf("   > Testing: %-20s", name))
  
  # Force Garbage Collection before run to get clean baseline
  gc(verbose = FALSE)
  start_mem <- mem_used()
  
  # Timing
  tic()
  result <- tryCatch({
    expr
  }, error = function(e) {
    cat(" [FAILED]\n")
    return(NULL)
  })
  time_elapsed <- toc(quiet = TRUE)
  
  # Metrics
  end_mem <- mem_used()
  mem_diff <- as.numeric(end_mem - start_mem) / 1024^2 # Convert to MB
  
  row_count <- if (is.data.frame(result)) nrow(result) else 0
  obj_size  <- as.numeric(object.size(result)) / 1024^2 # Size in MB
  
  cat(sprintf("| Time: %6.2fs | RAM Delta: %6.2f MB | Data Size: %6.2f MB | Rows: %4d\n", 
              time_elapsed$toc - time_elapsed$tic, 
              mem_diff, 
              obj_size, 
              row_count))
  
  return(list(
    Source = name,
    Time_Sec = time_elapsed$toc - time_elapsed$tic,
    RAM_Delta_MB = mem_diff,
    Object_Size_MB = obj_size,
    Rows = row_count,
    Data = result # Keep data for downstream test
  ))
}

# 4. EXECUTION LOOP ------------------------------------------------------------
cat("\n[2/4] Benchmarking Individual Extractors (Sequential)...\n")
results <- list()

# --- A. Europe PMC ---
results$epmc <- benchmark_task("Europe PMC", {
  get_epmc_data(SEARCH_TERM, page_size = 100, max_results = LIMIT)
})

# --- B. ClinicalTrials.gov ---
results$ct <- benchmark_task("ClinicalTrials.gov", {
  get_clinical_trials_data(SEARCH_TERM, limit = LIMIT)
})

# --- C. BioRxiv ---
results$bx <- benchmark_task("BioRxiv", {
  get_biorxiv_data(SEARCH_TERM, limit = LIMIT)
})

# --- D. OpenAlex ---
results$oa <- benchmark_task("OpenAlex", {
  get_openalex_data(SEARCH_TERM, mailto = NULL, max_results = LIMIT)
})

# --- E. CORE (Conditional) ---
if (nchar(KEYS$CORE) > 0) {
  results$core <- benchmark_task("CORE Discovery", {
    get_core_data(SEARCH_TERM, limit = LIMIT, api_key = KEYS$CORE)
  })
} else {
  cat("   > Skipping CORE (No Key)\n")
}

# --- F. USPTO (Conditional) ---
if (nchar(KEYS$USPTO) > 0) {
  results$uspto <- benchmark_task("USPTO Patents", {
    get_patentsview_data(SEARCH_TERM, limit = LIMIT, api_key = KEYS$USPTO)
  })
} else {
  cat("   > Skipping USPTO (No Key)\n")
}

# 5. DOWNSTREAM PROCESSING TEST ------------------------------------------------
cat("\n[3/4] Benchmarking Downstream Processing...\n")

# Combine whatever data we got
all_data <- bind_rows(
  lapply(results, function(x) x$Data), 
  .id = "Source"
)

cat(sprintf("   > Combined Dataset: %d rows\n", nrow(all_data)))

# Test Deduplication Cost
benchmark_task("Deduplication", {
  deduplicate_data(all_data)$deduplicated
})
usethis::edit_r_environ()
# 6. SUMMARY REPORT ------------------------------------------------------------
cat("\n[4/4] Final Diagnostic Report\n")
summary_df <- map_df(results, ~ data.frame(
  Source = .x$Source,
  Time_Sec = round(.x$Time_Sec, 2),
  RAM_Delta_MB = round(.x$RAM_Delta_MB, 2),
  Object_Size_MB = round(.x$Object_Size_MB, 2),
  Rows = .x$Rows
))

print(summary_df)

# Check for "Heavy Objects" that kill parallelization
high_mem_offenders <- summary_df %>% filter(Object_Size_MB > 50)
if (nrow(high_mem_offenders) > 0) {
  cat("\n[WARNING] The following sources produce large objects that will choke parallel workers:\n")
  print(high_mem_offenders)
} else {
  cat("\n[OK] Object sizes look manageable for multisession parallelization.\n")
}




source("epmc_standalone_extraction.R")

df = get_epmc_data(search_term = 1000)