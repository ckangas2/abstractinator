# agent_api.R
# Protocol: Headless Interface for AI Agents
# Purpose: Provide a safe, simplified API for autonomous agents to interact 
#          with The Abstractinator without managing complex orchestration.

library(dplyr)
library(RSQLite)
library(knitr) # Added for markdown formatting

# --- DEPENDENCIES & BOOTSTRAP ---
# Ensure we source all extraction workers and config files
worker_files <- c(
  "aliases.R", 
  "db_utils_local_cache.R",
  "orchestrate_extraction.R",
  "epmc_standalone_extraction.R",
  "clinicaltrials.gov_extraction.R",
  "biorxiv_extraction.R",
  "openalex_standalone_extraction.R",
  "CORE_extraction.R",
  "patentsview_extraction.R",
  "scopus_extraction.R",
  "scopus_abstract_extraction.R",
  "NIHReporter_extraction.R",
  "NSFAwards_extraction.R",
  "deduplication.R"
)

for (f in worker_files) {
  if (file.exists(f)) source(f) else warning(paste("Missing worker file:", f))
}

# ==============================================================================
# LOW-LEVEL API (Core functions)
# ==============================================================================



#' Execute a standardized search and return results
agent_search <- function(search_term, keys = list()) {
  message(sprintf("[Agent-API] Initiating search for: %s", search_term))
  
  e_key <- if(!is.null(keys$elsevier)) keys$elsevier else Sys.getenv("ELSEVIER_API_KEY")
  c_key <- if(!is.null(keys$core)) keys$core else Sys.getenv("CORE_API_KEY")
  u_key <- if(!is.null(keys$uspto)) keys$uspto else Sys.getenv("USPTO_API_KEY")
  
  results <- orchestrate_data_extraction_cached(
    search_term = search_term,
    elsevier_key = e_key,
    core_key = c_key,
    uspto_key = u_key
  )
  
  return(results$deduplicated_data)
}

#' Perform a direct SQL query on the Knowledge Base
agent_query_kb <- function(sql_query) {
  conn <- dbConnect(SQLite(), "data/abstractinator.sqlite")
  on.exit(dbDisconnect(conn))
  
  tryCatch({
    res <- dbGetQuery(conn, sql_query)
    return(res)
  }, error = function(e) {
    warning(paste("[Agent-API] SQL Error:", e$message))
    return(NULL)
  })
}

# ==============================================================================
# HIGH-LEVEL AGENT HELPERS (Context-Aware functions)
# ==============================================================================

#' Find Top N most relevant abstracts for a specific keyword in the KB
agent_find_top_abstracts <- function(keyword, n = 10) {
  message(sprintf("[Agent-API] Scanning Knowledge Base for top %d matches to '%s'...", n, keyword))
  
  # Parameterized query to prevent syntax crashes from apostrophes or injection
  query <- "SELECT Title as title, Abstract as abstract, Source_Label as source, PublicationDate as publication_date, DOI as doi, primary_virus, primary_cell 
            FROM documents 
            WHERE Abstract LIKE ? OR Title LIKE ? 
            LIMIT ?"
  
  search_str <- paste0("%", keyword, "%")
  
  conn <- dbConnect(SQLite(), "data/abstractinator.sqlite")
  on.exit(dbDisconnect(conn))
  
  tryCatch({
    res <- dbGetQuery(conn, query, params = list(search_str, search_str, n))
    return(res)
  }, error = function(e) {
    warning(paste("[Agent-API] SQL Error:", e$message))
    return(NULL)
  })
}

#' GAP ANALYSIS: Enforces N >= 3 Triangulation Rule
agent_analyze_gap <- function(topic, threshold = 10) {
  message(sprintf("[Agent-API] Analyzing knowledge gap for topic: %s", topic))
  
  query <- "SELECT Source_Label as source, COUNT(*) as count FROM documents WHERE Abstract LIKE ? OR Title LIKE ? GROUP BY Source_Label"
  search_str <- paste0("%", topic, "%")
  
  conn <- dbConnect(SQLite(), "data/abstractinator.sqlite")
  res <- tryCatch(dbGetQuery(conn, query, params = list(search_str, search_str)), 
                  error = function(e) NULL, finally = dbDisconnect(conn))
  
  total <- if(!is.null(res)) sum(res$count) else 0
  distinct_sources <- if(!is.null(res)) nrow(res) else 0
  
  # Triangulation logic: Must hit volume threshold AND cross at least 3 distinct domains
  status <- if(total >= threshold && distinct_sources >= 3) "SUFFICIENT" else "GAP DETECTED"
  
  recommendation <- if(status == "SUFFICIENT") {
    "Knowledge base is sufficient."
  } else if (distinct_sources < 3 && total >= threshold) {
    sprintf("Triangulation failure. %d records found, but only across %d source(s). Minimum 3 required.", total, distinct_sources)
  } else {
    "Trigger new agent_search() to fill volume gap."
  }
  
  return(list(
    topic = topic,
    status = status,
    total_records = total,
    distinct_sources = distinct_sources,
    distribution = res,
    recommendation = recommendation
  ))
}

#' FORMATTER: Bulletproofed for Case-Sensitivity
agent_format_as_md <- function(df) {
  if (is.null(df) || nrow(df) == 0) return("No results found.")
  
  # Coerce all column names to lowercase to unify Orchestrator (Title) and SQLite (title) outputs
  names(df) <- tolower(names(df))
  
  # Safely handle missing analytical columns
  if (!"primary_cell" %in% names(df)) df$primary_cell <- "N/A"
  if (!"primary_virus" %in% names(df)) df$primary_virus <- "N/A"
  
  if (nrow(df) <= 15) {
    output <- ""
    for (i in 1:nrow(df)) {
      row <- df[i, ]
      output <- paste0(output, sprintf(
        "\n### %s\n**Source:** %s | **Date:** %s | **DOI:** %s\n**Classification:** Cell: %s | Virus: %s\n\n%s\n\n---\n", 
        row$title, row$source, row$publication_date, row$doi, 
        row$primary_cell, row$primary_virus, row$abstract
      ))
    }
    return(output)
  } else {
    cols_to_keep <- intersect(names(df), c("title", "abstract", "source", "publication_date", "doi"))
    md_table <- knitr::kable(df[, cols_to_keep], format = "markdown")
    return(paste(as.character(md_table), collapse = "\n"))
  }
}

#' Get a system summary
agent_get_stats <- function() {
  conn <- dbConnect(SQLite(), "data/abstractinator.sqlite")
  on.exit(dbDisconnect(conn))
  
  total <- dbGetQuery(conn, "SELECT COUNT(*) as count FROM documents")$count
  sources <- dbGetQuery(conn, "SELECT Source_Label as source, COUNT(*) as count FROM documents GROUP BY Source_Label")
  
  return(list(
    total_articles = total,
    distribution = sources
  ))
}
