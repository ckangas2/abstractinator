# cli_engine.R
# Bridge between Shell/Agent and the Abstractinator API

suppressMessages(library(optparse))
suppressMessages(library(dplyr))
suppressMessages(library(jsonlite)) # Required for LLM payload parsing
suppressMessages(library(readr))    # Required for flat-file CSV export

# --- LOAD SYSTEM ---
# The bash wrapper enforces the directory context. Fail loudly if bypassed.
stopifnot(
  "FATAL: agent_api.R not found. You must execute this via abstractinator.sh" = file.exists("agent_api.R")
)
source("agent_api.R")

option_list <- list(
  make_option(c("-s", "--search"), type="character", default=NULL, 
              help="Search term for literature retrieval", metavar="character"),
  make_option(c("-q", "--query"), type="character", default=NULL, 
              help="Direct SQL query against the knowledge base", metavar="character"),
  make_option(c("-t", "--top"), type="character", default=NULL, 
              help="Find top N abstracts for a keyword", metavar="character"),
  make_option(c("-g", "--gap"), type="character", default=NULL, 
              help="Perform gap analysis on a topic", metavar="character"),
  make_option(c("-n", "--limit"), type="integer", default=10, 
              help="Limit results (for search/top)", metavar="number"),
  make_option(c("-f", "--format"), type="character", default="md", 
              help="Output format: md, csv, json [default: md]", metavar="character")
)

opt <- parse_args(OptionParser(option_list=option_list))

# --- OUTPUT ROUTER ---
export_payload <- function(res, format_type) {
  if (is.null(res)) {
    cat(if(format_type == "json") "{}" else "No results found.\n")
    return()
  }
  
  if (format_type == "json") {
    # auto_unbox ensures single values aren't wrapped in arrays [ ] which confuses agents
    cat(toJSON(res, auto_unbox = TRUE, pretty = TRUE), "\n")
  } else if (format_type == "csv") {
    if (is.data.frame(res)) {
      cat(format_csv(res))
    } else {
      stop("Cannot coerce non-dataframe payload to CSV.")
    }
  } else {
    # Default to Markdown
    cat(agent_format_as_md(res), "\n")
  }
}

# --- EXECUTION LOGIC ---
tryCatch({
  if (!is.null(opt$search)) {
    res <- agent_search(opt$search)
    export_payload(res, opt$format)
    
  } else if (!is.null(opt$query)) {
    res <- agent_query_kb(opt$query)
    export_payload(res, opt$format)
    
  } else if (!is.null(opt$top)) {
    res <- agent_find_top_abstracts(opt$top, n = opt$limit)
    export_payload(res, opt$format)
    
  } else if (!is.null(opt$gap)) {
    res <- agent_analyze_gap(opt$gap)
    
    if (opt$format == "md") {
      # INJECTED: N >= 3 Triangulation metric (distinct_sources)
      cat(sprintf("### Gap Analysis: %s\n**Status:** %s\n**Total Records:** %d\n**Distinct Sources:** %d\n**Recommendation:** %s\n", 
                  res$topic, res$status, res$total_records, res$distinct_sources, res$recommendation))
    } else {
      export_payload(res, opt$format)
    }
    
  } else {
    cat("Error: No command provided. Execute with --help for options.\n")
    quit(status=1)
  }
}, error = function(e) {
  # If the R script crashes, output a strict JSON error so the Python agent doesn't hang
  cat(toJSON(list(error = e$message), auto_unbox = TRUE), "\n")
  quit(status=1)
})