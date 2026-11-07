# triangulation_engine.R
library(dplyr)
library(tidygraph)
library(RSQLite)

extract_consensus_network <- function(min_sources = 3) {
  conn <- dbConnect(SQLite(), "data/abstractinator.sqlite")
  on.exit(dbDisconnect(conn))
  
  # 1. Fetch relational entity pairings
  raw_edges <- dbGetQuery(conn, "
    SELECT primary_virus, primary_cell, source, doi 
    FROM articles 
    WHERE primary_virus != 'N/A' AND primary_cell != 'N/A'
  ")
  
  # 2. Strict Data Validation
  stopifnot(
    "Database returned no valid virus-cell interactions" = nrow(raw_edges) > 0
  )
  
  # 3. Calculate Edge Weights based on distinct sources (Triangulation Logic)
  weighted_edges <- raw_edges %>%
    group_by(from = primary_virus, to = primary_cell) %>%
    summarise(
      total_papers = n(),
      distinct_sources = n_distinct(source), # The N >= 3 metric
      evidence_dois = paste(unique(doi), collapse = "; "),
      .groups = "drop"
    )
  
  # 4. Construct the Graph & Apply Triangulation Filter
  consensus_graph <- as_tbl_graph(weighted_edges, directed = TRUE) %>%
    activate(edges) %>%
    # Isolate only high-confidence interactions
    filter(distinct_sources >= min_sources) %>%
    
    # Calculate Node Centrality (Which virus hits the most distinct cell targets?)
    activate(nodes) %>%
    mutate(degree_centrality = centrality_degree(mode = "out"))
  
  return(consensus_graph)
}

# Extraction for Seurat:
# Pull the high-confidence cell types targeted by T-VEC to inform your scRNA-seq clustering
# seurat_targets <- consensus_graph %>% activate(edges) %>% filter(from == "T-VEC") %>% pull(to)