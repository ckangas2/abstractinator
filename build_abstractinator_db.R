library(dplyr)
library(RSQLite)
library(DBI)

build_abstractinator_db <- function(data_dir = "working_Abstractinator_v5", 
                                    output_dir = "data",
                                    search_term = NULL) {
  
  stopifnot(dir.exists(data_dir))
  
  # Create output dir if needed
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  
  db_path <- file.path(output_dir, "abstractinator.sqlite")
  con <- dbConnect(RSQLite::SQLite(), db_path)
  
  # Step 1: Load all extracted CSVs
  csv_files <- list.files(data_dir, pattern = "extracted_.*\\.csv$", full.names = TRUE)
  
  if (length(csv_files) == 0) {
    warning("No extracted CSVs found. Run extraction first.")
    return(NULL)
  }
  
  print(sprintf("Found %d extracted CSV files.", length(csv_files)))
  
  # Read all CSVs
  all_data <- lapply(csv_files, function(f) {
    df <- read.csv(f, stringsAsFactors = FALSE)
    df$source_file <- basename(f)
    df
  }) %>% bind_rows()
  
  # Step 2: Create unified documents table
  documents <- all_data %>%
    mutate(
      id = paste0(source, "_", 
                  ifelse(!is.na(DOI), DOI, 
                         ifelse(!is.na(NCTId), paste0("NCT", NCTId), 
                                paste0(source_id, "_", row_number())))),
      source_id = ifelse(!is.na(DOI), DOI,
                         ifelse(!is.na(NCTId), NCTId,
                                ifelse(!is.na(CORE_ID), CORE_ID, NA))),
      has_doi = !is.na(DOI) & DOI != "",
      has_nct = !is.na(NCTId) & NCTId != "",
      has_core = !is.na(CORE_ID) & CORE_ID != "",
      search_term = search_term %||% "unknown_query",
      extracted_at = Sys.time()
    ) %>%
    select(id, source, source_id, DOI, NCTId, CORE_ID, Title, Abstract, 
           Authors, PublicationDate, URL, AdverseEvents, SeriousAdverseEvents,
           primary_virus, primary_cell, is_bioinformatics, has_doi, has_nct, 
           has_core, search_term, extracted_at)
  
  # Assertions
  stopifnot(nrow(documents) > 0)
  stopifnot(!any(is.na(documents$id)))
  stopifnot(!is.null(documents$search_term))
  
  # Write to SQLite
  dbWriteTable(con, "documents", documents, overwrite = TRUE, temporary = FALSE, row.names = FALSE)
  
  # Indexes for fast queries (SQLite syntax)
  dbExecute(con, "CREATE INDEX idx_documents_source ON documents(source)")
  dbExecute(con, "CREATE INDEX idx_documents_has_doi ON documents(has_doi)")
  dbExecute(con, "CREATE INDEX idx_documents_bioinformatics ON documents(is_bioinformatics)")
  dbExecute(con, "CREATE INDEX idx_documents_date ON documents(CAST(publication_date AS DATE))")
  dbExecute(con, "CREATE INDEX idx_documents_search_term ON documents(search_term)")
  
  # Summary stats
  summary_stats <- dbGetQuery(con, "
    SELECT 
      search_term,
      source,
      COUNT(*) as count,
      SUM(has_doi) as with_doi,
      SUM(has_nct) as with_nct,
      SUM(is_bioinformatics) as bioinformatics_count
    FROM documents 
    GROUP BY 1, 2
    ORDER BY 2 DESC, count DESC
  ")
  
  print("=== Database Built ===")
  print(sprintf("Search term: %s", search_term))
  print(sprintf("Total records: %d", nrow(documents)))
  print("=== Summary by Source ===")
  print(summary_stats)
  
  dbDisconnect(con)
  
  return(db_path)
}

# Usage:
# db_path <- build_abstractinator_db(search_term = "oncolytic virus")
# con <- dbConnect(RSQLite::SQLite(), db_path)
# dbGetQuery(con, "SELECT * FROM documents WHERE is_bioinformatics = TRUE LIMIT 10")
