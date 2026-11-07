library(dplyr)

# ==============================================================================
# DEDUPLICATION
# ==============================================================================
# The same paper often arrives from several databases (Europe PMC, OpenAlex,
# its bioRxiv preprint...). Records are grouped into "same work" sets, the gaps
# in each set are filled from its other copies, and one copy is kept.
#
# What counts as the same work:
#   1. The same DOI (after normalising, and after swapping a preprint's DOI
#      for the DOI of its published version when bioRxiv knows it).
#   2. Grants: the same funder project (NIH core project number, NSF award
#      id), so a project's fiscal-year records collapse to one. Grants are
#      never merged on title: unrelated projects can share a generic one.
#   3. A record with no DOI joins a record with the same title key (letters
#      and digits only, see normalize_title_key) and
#      a compatible year (same or adjacent; or either unknown). Titles shorter
#      than MIN_TITLE_MATCH characters are too generic to match on. Two records
#      that both have DOIs are never merged on title alone.
# Which copy is kept: the most trusted source (priority_order), then one
# with an abstract, then the most recent.
# Every kept record lists what was folded into it in MergedFrom, so a merge
# can be audited.

MIN_TITLE_MATCH <- 20L

# Letters and digits only, lowercased, after removing markup and HTML
# entities: "IL-2 <i>in vivo</i>: a T-cell review." and "IL2 in vivo - a
# T cell review" both become "il2invivoatcellreview". Spacing, hyphens and
# punctuation vary between databases; the words don't.
normalize_title_key <- function(x) {
  x <- tolower(as.character(x))
  x <- gsub("<[^>]+>", " ", x, perl = TRUE)
  x <- gsub("&[a-z#0-9]+;", " ", x, perl = TRUE)
  x <- gsub("[^\\p{L}\\p{N}]+", "", x, perl = TRUE)
  x[is.na(x) | !nzchar(x)] <- NA_character_
  x
}

# A short, human-readable id for one record, used in MergedFrom.
record_ref <- function(df) {
  pick <- function(col) if (col %in% names(df)) as.character(df[[col]]) else rep(NA_character_, nrow(df))
  id <- pick("DOI")
  for (alt in c("NCTId", "PMID", "GrantID", "URL")) {
    fill <- is.na(id) | !nzchar(id)
    id[fill] <- pick(alt)[fill]
  }
  id[is.na(id) | !nzchar(id)] <- substr(pick("Title")[is.na(id) | !nzchar(id)], 1, 60)
  paste0(df$Source, ": ", id)
}

deduplicate_data <- function(df) {
  initial_count <- nrow(df)
  if (initial_count == 0) return(list(deduplicated = df, removed = 0L))

  # Most trusted first. Labels must match the Source values the extractors
  # emit. A published record (EPMC, OpenAlex) is preferred over its preprint.
  priority_order <- c("EPMC", "Scopus", "OpenAlex", "Preprint (biorxiv)", "Preprint (medrxiv)",
                      "bioRxiv", "CORE", "clinicaltrials.gov", "NIH", "NSF")

  for (cl in c("Published_DOI_biorxiv", "GrantID", "DOI", "PublicationDate", "Abstract",
              "AuthorAffiliations")) {
    if (!cl %in% names(df)) df[[cl]] <- NA_character_
  }

  blank_to_na <- function(x) {
    x <- as.character(x)
    x[trimws(x) %in% c("", "NA", "NULL", "No abstract available")] <- NA_character_
    x
  }

  df <- df %>%
    mutate(
      # A preprint that bioRxiv knows was published is matched by the
      # published DOI, so it groups with the journal version.
      Master_DOI = if_else(!is.na(Published_DOI_biorxiv) & Published_DOI_biorxiv != "",
                           as.character(Published_DOI_biorxiv), as.character(DOI)),
      DOI_clean = gsub("^(https?://(dx\\.)?doi\\.org/|doi:\\s*)", "", trimws(tolower(Master_DOI))),
      DOI_clean = if_else(is.na(DOI_clean) | DOI_clean == "", NA_character_, DOI_clean),
      title_key = normalize_title_key(Title),
      pub_year = suppressWarnings(as.integer(substr(as.character(PublicationDate), 1, 4))),
      is_grant = Source %in% c("NIH", "NSF"),
      AuthorAffiliations = if_else(
        is.na(AuthorAffiliations) | AuthorAffiliations %in% c("No affiliation available", "", "NULL"),
        "[]", as.character(AuthorAffiliations))
    )

  # --- Group records that are the same work ---
  # Every record starts in its own group; each rule then relabels groups.
  grp <- seq_len(nrow(df))
  merge_on <- function(grp, key) {
    ok <- !is.na(key)
    if (!any(ok)) return(grp)
    first <- tapply(grp[ok], key[ok], min)
    grp[ok] <- first[key[ok]]
    grp
  }
  # 1. DOI
  grp <- merge_on(grp, df$DOI_clean)
  # 2. Grants by funder project id
  grant_key <- ifelse(df$is_grant & !is.na(df$GrantID) & nzchar(df$GrantID),
                      paste0(df$Source, ":", df$GrantID), NA_character_)
  grp <- merge_on(grp, grant_key)
  # 3. DOI-less non-grant records join a same-title record of a compatible year
  title_ok <- !df$is_grant & !is.na(df$title_key) & nchar(df$title_key) >= MIN_TITLE_MATCH
  orphans <- which(title_ok & is.na(df$DOI_clean))
  for (i in orphans) {
    cand <- which(title_ok & df$title_key == df$title_key[i] & seq_len(nrow(df)) != i)
    if (!length(cand)) next
    yi <- df$pub_year[i]
    yc <- df$pub_year[cand]
    cand <- cand[is.na(yi) | is.na(yc) | abs(yc - yi) <= 1]
    if (!length(cand)) next
    # Prefer joining a record that has a DOI, then the earliest group.
    cand <- cand[order(is.na(df$DOI_clean[cand]), grp[cand])]
    target <- grp[cand[1]]
    grp[grp == grp[i]] <- target
  }
  df$dup_group <- grp

  # --- Fill gaps across each group before choosing which copy to keep ---
  # Sources carry different fields for the same paper (only EPMC knows the
  # PMCID; OpenAlex may lack the abstract). For the abstract, take the longest.
  fill_cols <- intersect(c("Abstract", "PMCID", "PMID", "IsOpenAccess"), names(df))
  for (cl in fill_cols) df[[cl]] <- blank_to_na(df[[cl]])
  df <- df %>%
    group_by(dup_group) %>%
    mutate(across(all_of(fill_cols), function(v) {
      present <- v[!is.na(v)]
      if (!length(present)) v else present[which.max(nchar(present))]
    })) %>%
    ungroup()

  # --- Keep one copy per group, recording what it absorbed ---
  df$record_ref <- record_ref(df)
  deduplicated_df <- df %>%
    mutate(
      Priority_Level = match(Source, priority_order, nomatch = 100),
      Abstract_Rank  = ifelse(is.na(Abstract), 1L, 0L),
      Date_Rank      = -rank(as.character(PublicationDate), na.last = FALSE, ties.method = "min")
    ) %>%
    arrange(dup_group, Priority_Level, Abstract_Rank, Date_Rank) %>%
    group_by(dup_group) %>%
    mutate(MergedFrom = if (n() > 1) paste(record_ref[-1], collapse = "; ") else NA_character_) %>%
    slice(1) %>%
    ungroup() %>%
    select(-Priority_Level, -Abstract_Rank, -Date_Rank, -DOI_clean, -title_key, -Master_DOI,
           -pub_year, -is_grant, -dup_group, -record_ref)

  print(paste("Deduplication complete. Retained", nrow(deduplicated_df), "of", initial_count, "records."))
  list(deduplicated = deduplicated_df, removed = initial_count - nrow(deduplicated_df))
}

verify_deduplication <- function(dedup_df, original_df) {
  # 1. Calculate source-wise counts for original and deduplicated data
  source_counts_original <- original_df %>%
    group_by(Source) %>%
    summarise(`Total Search Records` = n())
  
  source_counts_dedup <- dedup_df %>%
    group_by(Source) %>%
    summarise(`Unique Records` = n())
  
  # 2. Combine source counts and calculate removed duplicates
  combined_source_counts <- source_counts_original %>%
    left_join(source_counts_dedup, by = "Source") %>%
    mutate(`Number of Duplicate Records Removed` = `Total Search Records` - `Unique Records`) %>%
    arrange(desc(`Total Search Records`))
  
  # 3. Add a total row
  total_row <- tibble(
    Source = "TOTAL",
    `Total Search Records` = sum(combined_source_counts$`Total Search Records`),
    `Unique Records` = sum(combined_source_counts$`Unique Records`),
    `Number of Duplicate Records Removed` = sum(combined_source_counts$`Number of Duplicate Records Removed`)
  )
  
  final_source_counts <- bind_rows(combined_source_counts, total_row)
  
  print("--- Deduplication Verification Summary ---")
  print(final_source_counts)
  return(final_source_counts)
}
