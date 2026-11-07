# _targets.R
library(targets)
library(tarchetypes) # For dynamic branching

# 1. Source all isolated worker functions
# --- SOURCE EXTRACTORS ---
source("epmc_standalone_extraction.R")
source("CORE_extraction.R")
source("clinicaltrials.gov_extraction.R")
source("scopus_extraction.R")
source("biorxiv_extraction.R")
source("patentsview_extraction.R") 
source("deduplication.R")
source("scopus_abstract_extraction.R")
source("db_utils_local_cache.R")
source("openalex_standalone_extraction.R")
source("aliases.R")           
source("orchestrate_extraction.R") 
source("generate_plot.R")      
source("NIHReporter_extraction.R")
source("NSFAwards_extraction.R")

# 2. Define the Pipeline Graph
list(
  # Node A: Define the input vector
  tar_target(
    name = search_chips,
    command = c("Oncolytic Virus", "T-VEC", "Melanoma", "scRNA-seq")
  ),
  
  # Node B: Dynamic Branching - Orchestrate extraction for each chip independently
  # If "T-VEC" fails via API timeout, the other three chips still complete and save to disk.
  tar_target(
    name = raw_extractions,
    command = orchestrate_data_extraction_cached(search_chips),
    pattern = map(search_chips), # Creates 4 parallel branches
    error = "continue"           # Failures isolate to their specific branch
  ),
  
  # Node C: Consolidate Knowledge Base Stats
  tar_target(
    name = pipeline_audit,
    command = {
      conn <- RSQLite::dbConnect(RSQLite::SQLite(), "data/abstractinator.sqlite")
      on.exit(RSQLite::dbDisconnect(conn))
      RSQLite::dbGetQuery(conn, "SELECT source, COUNT(*) as n FROM articles GROUP BY source")
    }
  )
)