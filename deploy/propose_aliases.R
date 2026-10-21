#!/usr/bin/Rscript
# deploy/propose_aliases.R
# Propose additions to aliases.R, ranked by how often they actually occur.
#
# MeSH tells us what a record is about, and mesh_to_category() folds that onto
# an existing category when one covers it. When none does, it returns the raw
# MeSH label -- which is precisely a coverage gap, named canonically. This
# script collects those, counts how often each occurs in a sample of the
# corpus, and emits R ready to paste into aliases.R, using MeSH entry terms as
# the alias set.
#
# It writes nothing: review the output before adding anything. Two things need
# human judgement -- MeSH's inverted names read badly as categories
# ("Herpesvirus 4, Human" should display as "Epstein-Barr Virus"), and some
# entry terms are too loose to match on ("Cold Sore" for Herpes Labialis).
#
#   Rscript deploy/propose_aliases.R [min_count] [queries...]

suppressMessages({
  library(httr); library(jsonlite); library(digest)
  library(dplyr); library(stringr); library(purrr)
})
`%||%` <- function(a, b) if (is.null(a)) b else a
source("epmc_standalone_extraction.R")
source("aliases.R")
source("R/mesh_utils.R")

aliases_to_regex <- function(al) lapply(lapply(al, tolower), function(a)
  paste0("\\b", gsub("\\s+", "\\\\s+", a), "\\b", collapse = "|"))
rx <- list(virus = aliases_to_regex(virus_alias_expanded),
           bacteria = aliases_to_regex(bacteria_alias_expanded),
           cell = aliases_to_regex(immune_cell_alias_list))

args <- commandArgs(trailingOnly = TRUE)
min_count <- suppressWarnings(as.integer(args[1])); if (is.na(min_count)) min_count <- 3L
queries <- if (length(args) > 1) args[-1] else c(
  "T cell immunity", "oncolytic virus", "macrophage infection", "NK cell",
  "dendritic cell vaccine", "listeria monocytogenes", "norovirus",
  "influenza vaccine", "HIV latency", "bacteriophage therapy",
  "regulatory T cell", "B cell lymphoma", "neutrophil", "tuberculosis",
  "herpes simplex", "SARS-CoV-2", "rotavirus", "biofilm", "sepsis",
  "checkpoint inhibitor")

tally <- new.env(parent = emptyenv())
bump <- function(k) assign(k, (get0(k, envir = tally, ifnotfound = 0L)) + 1L, envir = tally)

for (q in queries) {
  d <- tryCatch(get_epmc_data(q, page_size = 100, max_results = 100),
                error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) next
  for (i in seq_len(nrow(d))) {
    terms <- c(d$MeSH_Major[i], d$MeSH_All[i])
    terms <- unlist(strsplit(paste(terms[!is.na(terms)], collapse = "; "), ";", fixed = TRUE))
    for (t in unique(trimws(terms))) if (nzchar(t)) bump(t)
  }
}

cat(sprintf("\n%d distinct descriptors seen\n", length(ls(tally))))

DENY <- c("Oncolytic Viruses", "Oncolytic Virotherapy",
          "Gram-Negative Bacteria", "Gram-Positive Bacteria",
          "Gram-Negative Aerobic Bacteria", "Gram-Positive Cocci",
          "Bacteria, Anaerobic", "RNA Viruses", "DNA Viruses")

rows <- list()
skipped <- list()
for (t in ls(tally)) {
  n <- get(t, envir = tally)
  if (n < min_count) next
  rec <- mesh_lookup(t)
  ax <- mesh_axis(t, rec)
  if (is.na(ax)) next
  mapped <- mesh_to_category(t, rx[[ax]], rec)
  if (!identical(mapped, t)) next                 # folded onto a category
  if (mapped %in% names(rx[[ax]])) next           # IS a category already:
  # mesh_to_category returns the descriptor unchanged both when nothing
  # matched and when the descriptor happens to be spelled exactly like an
  # existing category ("Salmonella", "Escherichia coli"). Without this check
  # those get proposed as new.

  # Two exclusions, by tree position rather than taste:
  #   - top-level descriptors ("Viruses" B04, "Bacteria" B03) have no dot in
  #     their tree number. Their aliases are bare words that would match most
  #     of the corpus.
  #   - cell lines live under A11.251. Jurkat cells are a reagent, not an
  #     immune cell population.
  if (!any(grepl(".", rec$trees, fixed = TRUE))) {
    skipped[[length(skipped) + 1]] <- list(term = t, n = n, why = "top-level")
    next
  }
  if (any(startsWith(rec$trees, "A11.251"))) {
    skipped[[length(skipped) + 1]] <- list(term = t, n = n, why = "cell line")
    next
  }
  # Functional groupings MeSH files under an organism tree but which are not
  # taxa. Listed explicitly because no tree position distinguishes them.
  if (t %in% DENY) {
    skipped[[length(skipped) + 1]] <- list(term = t, n = n, why = "not a taxon")
    next
  }
  rows[[length(rows) + 1]] <- list(term = t, n = n, axis = ax, terms = rec$terms)
}

rows <- rows[order(-vapply(rows, function(r) r$n, integer(1)))]
cat(sprintf("%d uncovered, occurring at least %d times\n\n", length(rows), min_count))

if (length(skipped)) {
  cat("# ---- skipped ----\n")
  for (r in skipped[order(-vapply(skipped, function(x) x$n, integer(1)))]) {
    cat(sprintf("#   %-36s %-12s seen %d\n", r$term, r$why, r$n))
  }
  cat("\n")
}

for (ax in c("virus", "bacteria", "cell")) {
  sel <- Filter(function(r) r$axis == ax, rows)
  if (!length(sel)) next
  cat(sprintf("# ---- %s: %d proposed ----\n", toupper(ax), length(sel)))
  for (r in sel) {
    al <- unique(tolower(trimws(r$terms)))
    al <- al[nchar(al) >= 3 & !grepl(",", al, fixed = TRUE)]  # drop inverted forms
    cat(sprintf('  "%s" = c(%s),   # seen %d\n', r$term,
                paste0('"', al, '"', collapse = ", "), r$n))
  }
  cat("\n")
}
