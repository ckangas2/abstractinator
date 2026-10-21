#!/usr/bin/Rscript
# deploy/warm_mesh.R
# Populate the MeSH descriptor cache ahead of real traffic.
#
# apply_mesh_tags() looks up any descriptor it has not seen before, bounded to
# 60 new lookups per search so a cold cache can never hang a request. The cost
# of that bound is that early searches fall back to regex for anything past the
# budget. Running this once fills the cache with the descriptors that actually
# occur in this corpus, after which lookups are local and instant.
#
#   Rscript deploy/warm_mesh.R                       # default domain queries
#   Rscript deploy/warm_mesh.R "norovirus" "T-VEC"   # specific terms
#
# Safe to re-run: cached descriptors are skipped, including negative results.

suppressMessages({
  library(httr); library(jsonlite); library(digest)
  library(dplyr); library(stringr); library(purrr)
})
`%||%` <- function(a, b) if (is.null(a)) b else a

source("epmc_standalone_extraction.R")
source("R/mesh_utils.R")

args <- commandArgs(trailingOnly = TRUE)
queries <- if (length(args)) args else c(
  "T cell immunity", "oncolytic virus", "macrophage infection",
  "NK cell", "dendritic cell vaccine", "listeria monocytogenes",
  "norovirus", "influenza vaccine", "HIV latency", "bacteriophage therapy",
  "regulatory T cell", "B cell lymphoma", "neutrophil", "tuberculosis",
  "herpes simplex", "SARS-CoV-2", "rotavirus", "biofilm", "sepsis",
  "checkpoint inhibitor"
)

cat(sprintf("Warming MeSH cache from %d queries\n\n", length(queries)))

seen <- character(0)
for (q in queries) {
  d <- tryCatch(get_epmc_data(q, page_size = 100, max_results = 100),
                error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) { cat(sprintf("  %-28s no records\n", q)); next }
  terms <- unlist(strsplit(paste(c(d$MeSH_Major, d$MeSH_All), collapse = "; "), ";", fixed = TRUE))
  terms <- unique(trimws(terms))
  terms <- terms[nzchar(terms) & terms != "NA" & !is.na(terms)]
  seen <- union(seen, terms)
  cat(sprintf("  %-28s %4d records, %4d descriptors (%d distinct so far)\n",
              substr(q, 1, 28), nrow(d), length(terms), length(seen)))
}

todo <- seen[!vapply(seen, mesh_is_cached, logical(1))]
cat(sprintf("\n%d distinct descriptors, %d not yet cached. Looking them up...\n",
            length(seen), length(todo)))

axes <- c(virus = 0L, bacteria = 0L, cell = 0L, none = 0L)
for (i in seq_along(todo)) {
  rec <- mesh_lookup(todo[i])
  ax  <- mesh_axis(todo[i], rec)
  axes[[if (is.na(ax)) "none" else ax]] <- axes[[if (is.na(ax)) "none" else ax]] + 1L
  if (i %% 25 == 0) cat(sprintf("  %d/%d\n", i, length(todo)))
}

cat("\nNewly classified:\n")
print(axes)
cat(sprintf("\nCache now holds %d descriptors at %s\n",
            length(list.files(mesh_cache_dir(), pattern = "\\.rds$")),
            mesh_cache_dir()))
