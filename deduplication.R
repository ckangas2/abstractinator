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
      
      # Clean Title
      clean_title = trimws(tolower(Title)) %>% gsub("[[:punct:]]$ ", "", .),
      
      # Handle Author Affiliations
      AuthorAffiliations = if_else(
        is.na(AuthorAffiliations) | AuthorAffiliations %in% c("No affiliation available", "", "NULL"), 
        "[]", 
        as.character(AuthorAffiliations)
      )
    )
  
  # 2. Deduplicate with DOI (Using the new Master_DOI)
  with_doi <- df %>% filter(!is.na(DOI_clean) & DOI_clean != "")
  na_doi <- df %>% filter(is.na(DOI_clean) | DOI_clean == "")
  
  # 3. Perform Deduplication
  dedup_doi <- with_doi %>%
    mutate(
      # Robust factor matching (handles variations in Source names)
      Priority_Level = match(Source, priority_order, nomatch = 100) 
    ) %>%
    arrange(Priority_Level) %>%
    filter(!duplicated(DOI_clean)) %>%
    select(-Priority_Level, -DOI_clean, -clean_title, -Master_DOI)
  
  # 4. Deduplicate Title
  dedup_na <- na_doi %>%
    mutate(Priority_Level = match(Source, priority_order, nomatch = 100)) %>%
    arrange(Priority_Level) %>%
    filter(!duplicated(clean_title)) %>%
    select(-Priority_Level, -clean_title, -Master_DOI)
  
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