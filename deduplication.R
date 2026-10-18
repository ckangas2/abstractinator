library(dplyr)

deduplicate_data <- function(df) {
  initial_count <- nrow(df)
  
  # Priority Order: 
  # 1. EPMC (Gold standard metadata)
  # 2. Scopus (High quality)
  # 3. bioRxiv (If it's a unique preprint)
  # 4. CORE / ClinicalTrials
  priority_order <- c("EPMC", "Scopus", "Preprint (biorxiv)", "Preprint (medrxiv)", "bioRxiv", "CORE", "ClinicalTrials.gov")
  
  # --- DEFENSIVE SCHEMA CHECK (The Crash Fix) ---
  # If bioRxiv returns no results, this column will be missing.
  # We force it to exist as NA so the logic below doesn't break.
  if (!"Published_DOI_biorxiv" %in% names(df)) {
    df$Published_DOI_biorxiv <- NA_character_
  }
  
  df <- df %>% 
    mutate(
      # 1. THE SWAP LOGIC
      # If we have a bioRxiv published link, use IT as the master DOI for deduplication.
      # If not, use the standard DOI.
      Master_DOI = case_when(
        !is.na(Published_DOI_biorxiv) & Published_DOI_biorxiv != "" ~ Published_DOI_biorxiv,
        TRUE ~ DOI
      ),
      
      # Clean the Master DOI for matching
      DOI_clean = trimws(tolower(Master_DOI)) %>% 
        gsub("^https?://(dx\\.)?doi\\.org/", "", .),
      
      # Clean Title. The previous pattern was "[[:punct:]]$ " - a space AFTER the
      # end-of-string anchor, which can never match. Trailing punctuation was
      # therefore never stripped, so "Some Title." and "Some Title" were treated
      # as two different papers.
      clean_title = trimws(tolower(Title)) %>% gsub("[[:punct:]]+$", "", .),
      
      # Handle Author Affiliations
      AuthorAffiliations = if_else(
        is.na(AuthorAffiliations) | AuthorAffiliations %in% c("No affiliation available", "", "NULL"), 
        "[]", 
        as.character(AuthorAffiliations)
      )
    )
  
  # 1b. CROSS-FILL BEFORE CHOOSING A WINNER
  # Sources carry different fields for the same paper: EPMC may have an abstract
  # where OpenAlex has none, and only EPMC knows the PMCID. Picking one winner
  # discards whatever only the losing copies had, which is how records ended up
  # in the table with an empty abstract even though a sibling record had one.
  # Fill the gaps across each duplicate group first; for the abstract, take the
  # longest available, since sources truncate to different lengths.
  blank_to_na <- function(x) {
    x <- as.character(x)
    x[trimws(x) %in% c("", "NA", "NULL", "No abstract available")] <- NA_character_
    x
  }

  fill_within <- function(d, key, cols) {
    cols <- intersect(cols, names(d))
    if (!length(cols) || !key %in% names(d) || !nrow(d)) return(d)
    for (cl in cols) d[[cl]] <- blank_to_na(d[[cl]])
    d %>%
      group_by(across(all_of(key))) %>%
      mutate(across(all_of(cols), function(v) {
        present <- v[!is.na(v)]
        if (!length(present)) v else present[which.max(nchar(present))]
      })) %>%
      ungroup()
  }

  fill_cols <- c("Abstract", "PMCID", "IsOpenAccess")
  is_doi <- !is.na(df$DOI_clean) & df$DOI_clean != ""
  if (any(is_doi))  df[is_doi, ]  <- fill_within(df[is_doi, ],  "DOI_clean",   fill_cols)
  if (any(!is_doi)) df[!is_doi, ] <- fill_within(df[!is_doi, ], "clean_title", fill_cols)

  # 2. Deduplicate with DOI (Using the new Master_DOI)
  with_doi <- df %>% filter(!is.na(DOI_clean) & DOI_clean != "")
  na_doi <- df %>% filter(is.na(DOI_clean) | DOI_clean == "")
  
  # 3. Perform Deduplication
  dedup_doi <- with_doi %>%
    mutate(
      # Robust factor matching (handles variations in Source names)
      Priority_Level = match(Source, priority_order, nomatch = 100),
      # OpenAlex, NIH and NSF all score 100, so ties were previously broken by
      # whichever future happened to return first - sometimes handing the row to
      # a copy with no abstract. Break the tie on content instead.
      Abstract_Rank = ifelse(is.na(blank_to_na(Abstract)), 1L, 0L)
    ) %>%
    arrange(Priority_Level, Abstract_Rank) %>%
    filter(!duplicated(DOI_clean)) %>%
    select(-Priority_Level, -Abstract_Rank, -DOI_clean, -clean_title, -Master_DOI)
  
  # 4. Deduplicate Title
  dedup_na <- na_doi %>%
    mutate(
      Priority_Level = match(Source, priority_order, nomatch = 100),
      Abstract_Rank  = ifelse(is.na(blank_to_na(Abstract)), 1L, 0L)
    ) %>%
    arrange(Priority_Level, Abstract_Rank) %>%
    filter(!duplicated(clean_title)) %>%
    # DOI_clean was previously left in on this branch only, so bind_rows() below
    # produced a phantom DOI_clean column that was NA for every DOI-matched row.
    select(-Priority_Level, -Abstract_Rank, -DOI_clean, -clean_title, -Master_DOI)
  
  # 5. Combine
  deduplicated_df <- bind_rows(dedup_doi, dedup_na)
  
  print(paste("Deduplication complete. Retained", nrow(deduplicated_df), "of", initial_count, "records."))
  
  return(list(deduplicated = deduplicated_df, removed = initial_count - nrow(deduplicated_df)))
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