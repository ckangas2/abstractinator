library(dplyr)
library(future)
library(promises)
library(purrr)
library(jsonlite)
library(stringr)

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# --- HELPER 1: KEYWORD DETECTION ---
bioinformatics_keywords_lower <- c(
  "bioinformatics", "computational biology", "genomics", "proteomics",
  "transcriptomics", "phylogenetic", "sequence analysis", "alignment",
  "database", "algorithm", "statistical genetics", "systems biology",
  "machine learning", "deep learning", "artificial intelligence", "r package",
  "bioconductor", "galaxy platform", "nextflow", "snakemake", "rna-seq",
  "chip-seq", "mass spectrometry", "network analysis", "pathway analysis",
  "structural bioinformatics", "molecular modeling", "docking",
  "simulation", "variant calling", "annotation", "biostatistics"
)

contains_keyword <- function(text_vector, keywords) {
  if (is.null(text_vector) || all(is.na(text_vector))) {
    return(FALSE)
  }
  text <- tolower(paste(text_vector, collapse = " "))
  return(any(sapply(keywords, grepl, text, fixed = TRUE)))
}

# ======================================================================================
# NIH/NSF ROBUST API TRANSFORMATION LAYER
# ======================================================================================

# --- HELPER 3: SAFE EXTRACT ---
# Flattens nested lists/dataframes and coerces to character
safe_extract <- function(df, col_name) {
  if (!col_name %in% names(df)) return(rep(NA_character_, nrow(df)))
  
  col_data <- df[[col_name]]
  
  # Flatten nested lists/dataframes (common in NIH/NSF JSONs)
  if (is.list(col_data)) {
    return(map_chr(col_data, ~paste(unlist(.x), collapse = "; ")))
  }
  
  return(as.character(col_data))
}

transform_nih_to_schema <- function(nih_df) {
  # Strict null and type validation
  if (is.null(nih_df) || !is.data.frame(nih_df) || nrow(nih_df) == 0) {
    return(tibble(Title=character(), Abstract=character(), Authors=character(), AuthorAffiliations=character(), PublicationDate=character(), URL=character(), DOI=character(), Source=character()))
  }
  
  tibble(
    Title = safe_extract(nih_df, "project_title"),
    Abstract = safe_extract(nih_df, "abstract_text"),
    Authors = safe_extract(nih_df, "contact_pi_name"), 
    AuthorAffiliations = safe_extract(nih_df, "organization"), 
    PublicationDate = safe_extract(nih_df, "project_start_date"),
    URL = NA_character_, 
    DOI = NA_character_, 
    Source = "NIH"
  )
}

transform_nsf_to_schema <- function(nsf_df) {
  # Strict null and type validation
  if (is.null(nsf_df) || !is.data.frame(nsf_df) || nrow(nsf_df) == 0) {
    return(tibble(Title=character(), Abstract=character(), Authors=character(), AuthorAffiliations=character(), PublicationDate=character(), URL=character(), DOI=character(), Source=character()))
  }
  
  tibble(
    Title = safe_extract(nsf_df, "title"),
    Abstract = safe_extract(nsf_df, "abstractText"),
    Authors = safe_extract(nsf_df, "pdPIName"),
    AuthorAffiliations = safe_extract(nsf_df, "awardeeName"),
    PublicationDate = safe_extract(nsf_df, "date"),
    # Manually construct the hyperlink using the grant ID
    URL = paste0("https://www.nsf.gov/awardsearch/showAward?AWD_ID=", safe_extract(nsf_df, "id")),
    DOI = NA_character_, 
    Source = "NSF"
  )
}

merge_nih_nsf_to_schema <- function(nih_df, nsf_df) {
  bind_rows(
    transform_nih_to_schema(nih_df),
    transform_nsf_to_schema(nsf_df)
  )
}

# --- HELPER 3: AFFILIATION PROCESSOR ---
process_affiliations_for_shiny <- function(final_shiny_data) {
  print("    > Processing Affiliations for Shiny...")
  
  processed_data <- final_shiny_data %>%
    mutate(
      AuthorAffiliations = case_when(
        !is.na(Affiliations) ~ Affiliations,
        TRUE ~ NA_character_
      ),
      AuthorAffiliations = map2_chr(Authors, AuthorAffiliations, function(authors_str, affiliations_str) {
        if (is.na(authors_str)) return(toJSON(list(), auto_unbox = TRUE))
        
        authors <- str_split(authors_str, "; ")[[1]]
        affiliation_list <- list()
        
        if (!is.na(affiliations_str)) {
          for (author in authors) {
            affiliation_list <- append(affiliation_list, list(list(name = author, affiliations = affiliations_str)))
          }
        } else {
          for (author in authors) {
            affiliation_list <- append(affiliation_list, list(list(name = author, affiliations = "No affiliation available")))
          }
        }
        toJSON(affiliation_list, auto_unbox = TRUE)
      })
    )
  return(processed_data)
}

# --- HELPER 3: SCORING LOGIC ---
score_hits_combined <- function(hit_location_pairs, weight_title, weight_abstract) {
  valid_pairs <- hit_location_pairs[hit_location_pairs != ""]
  
  if (length(valid_pairs) == 0) return("Non-descript")
  
  weighted_scores <- valid_pairs %>%
    map_df(function(pair) {
      split_pair <- str_split(pair, ";", simplify = TRUE)
      if(length(split_pair) < 2) return(NULL) 
      
      hit <- trimws(split_pair[1])
      location <- split_pair[2]
      weight <- ifelse(location == "Title", weight_title,
                       ifelse(location == "Abstract", weight_abstract, 0))
      return(data.frame(hit = hit, score = weight))
    })
  
  if (nrow(weighted_scores) == 0) return("Non-descript")
  
  top_hit <- weighted_scores %>%
    group_by(hit) %>%
    summarise(score = sum(score), .groups = 'drop') %>%
    arrange(desc(score)) %>%
    slice_head(n = 1)
  
  if (nrow(top_hit) > 0) return(pull(top_hit, hit)) else return("Non-descript")
}

# --- HELPER 4: UNIFIED HIT DETECTION ---

perform_hit_detection <- function(df, immune_regex_list, virus_regex_list, weight_title = 20, weight_abstract = 3) {
  print("    > Running Vectorized Detection & Matrix Scoring...")
  
  # Ensure input is safe
  df$Title <- df$Title %||% ""
  df$Abstract <- df$Abstract %||% ""
  
  # Pre-compute lowercase vectors (Huge speedup)
  title_vec <- stringr::str_to_lower(df$Title)
  abst_vec  <- stringr::str_to_lower(df$Abstract)
  
  # --- INTERNAL HELPER: DETECT & SCORE ---
  get_best_hit_and_list <- function(regex_list, w_title, w_abst) {
    
    # 1. SCAN TITLES (Vectorized)
    # Returns list of indices: matches_title[[regex_name]] = c(row1, row5, ...)
    matches_title <- purrr::imap(regex_list, ~ which(stringr::str_detect(title_vec, .x)))
    
    # 2. SCAN ABSTRACTS (Vectorized)
    matches_abst  <- purrr::imap(regex_list, ~ which(stringr::str_detect(abst_vec, .x)))
    
    # 3. BUILD "LONG" SCORING TABLE (The Magic Step)
    # We create a simple math table: Row | Hit | Score
    
    # Title Data
    counts_t <- lengths(matches_title)
    df_t <- if(sum(counts_t) > 0) {
      data.frame(
        row_idx = unlist(matches_title, use.names = FALSE),
        hit = rep(names(matches_title), counts_t),
        score = w_title,
        source = "Title",
        stringsAsFactors = FALSE
      ) 
    } else NULL
    
    # Abstract Data
    counts_a <- lengths(matches_abst)
    df_a <- if(sum(counts_a) > 0) {
      data.frame(
        row_idx = unlist(matches_abst, use.names = FALSE),
        hit = rep(names(matches_abst), counts_a),
        score = w_abst,
        source = "Abstract",
        stringsAsFactors = FALSE
      )
    } else NULL
    
    # Combine
    long_df <- rbind(df_t, df_a)
    
    if (is.null(long_df) || nrow(long_df) == 0) {
      return(list(
        primary = rep("Non-descript", nrow(df)),
        hits_list = vector("list", nrow(df))
      ))
    }
    
    # 4. CALCULATE SCORES (Grouped Math - Fast!)
    # Sum scores for each (Row + Hit) pair
    scores <- long_df %>%
      group_by(row_idx, hit) %>%
      summarise(total_score = sum(score), .groups = "drop")
    
    # 5. DETERMINE WINNER (Per Row)
    winners <- scores %>%
      group_by(row_idx) %>%
      arrange(desc(total_score)) %>%
      slice(1) %>% # Take top scorer
      ungroup()
    
    # 6. BUILD OUTPUTS
    # A. Primary Hit Vector (Default "Non-descript")
    primary_vec <- rep("Non-descript", nrow(df))
    primary_vec[winners$row_idx] <- winners$hit
    
    # B. Hit List Column (For UI display: "Hit;Source")
    # Paste source for UI: "NK Cell;Title"
    long_df$ui_string <- paste0(long_df$hit, ";", long_df$source)
    # Deduplicate strings per row (e.g. if hit in Title AND Abstract, keep distinct entries)
    ui_splits <- split(long_df$ui_string, long_df$row_idx)
    
    # Align to original rows
    final_list_col <- vector("list", nrow(df))
    # Fill matches
    final_list_col[as.integer(names(ui_splits))] <- map(ui_splits, unique)
    
    return(list(primary = primary_vec, hits_list = final_list_col))
  }
  
  # --- EXECUTION ---
  
  print("      - Processing Immune Cells...")
  immune_res <- get_best_hit_and_list(immune_regex_list, weight_title, weight_abstract)
  
  print("      - Processing Viruses...")
  virus_res  <- get_best_hit_and_list(virus_regex_list, weight_title, weight_abstract)
  
  print("      - Attaching Results...")
  df %>%
    mutate(
      primary_cell = immune_res$primary,
      immune_cell_hits_combined = immune_res$hits_list,
      
      primary_virus = virus_res$primary,
      virus_hits_combined = virus_res$hits_list
    )
}

# ==============================================================================
# MAIN ORCHESTRATOR (CREDENTIAL-AWARE S3)
# ==============================================================================

orchestrate_data_extraction_cached <- function(search_term, limit = 50, elsevier_key = NULL, core_key = NULL, uspto_key = NULL, update_progress = NULL) {
  
  # --- [NEW] PROGRESS HELPER WITH UI FLUSH ---
  report_status <- function(step, text) {
    if (is.function(update_progress)) {
      update_progress(step_val = step, detail_text = text)
      # CRITICAL FIX: Force a tiny pause to let the UI render the text
      # before the main thread gets blocked by the next operation.
      Sys.sleep(0.25) 
    }
  }
  
  report_status(0.05, "Checking Local Cache...")
  
  # --------------------------------------------------------------------------
  # 1. GLOBAL CACHE CHECK
  # --------------------------------------------------------------------------
  if (check_s3_cache(search_term, elsevier_key = elsevier_key, uspto_key = uspto_key, core_key = core_key, max_age_days = 7)) {
    
    cached_result <- fetch_from_s3(search_term, elsevier_key = elsevier_key, uspto_key = uspto_key, core_key = core_key)
    
    if (!is.null(cached_result)) {
      report_status(0.5, "Cache Hit! Loading local binary blob...") 
      return(list(
        deduplicated_data = cached_result, 
        original_combined_data = cached_result,
        metadata = list(source = "CACHE", timestamp = Sys.time()) 
      ))
    }
  }
  
  message(sprintf("[Orchestrator] Cache MISS: Initiating multi-source extraction for '%s'...", search_term))
  report_status(0.05, "Initializing Extraction Agents...")
  
  # --------------------------------------------------------------------------
  # 2. PART A: PUBLIC & OPEN DATA
  # --------------------------------------------------------------------------
  
  report_status(0.1, "Dispatching Open Access Workers...")
  
  # 1. Always Run
  future_epmc <- future({ get_epmc_data(search_term, page_size = 1000, max_results = limit) })
  future_clinical_trials <- future({ get_clinical_trials_data(search_term, limit = limit) })
  future_biorxiv <- future({ get_biorxiv_data(search_term, limit = limit) })
  
  user_email <- Sys.getenv("USER_EMAIL")
  if (user_email == "") user_email <- NULL
  future_openalex <- future({ 
    print("    > Dispatching OpenAlex Worker...")
    get_openalex_data(search_term, mailto = user_email, max_results = limit, per_page = 200) 
  })
  
  # 2. Conditional Run (CORE)
  future_core <- if (!is.null(core_key) && nchar(core_key) > 0) {
    print("    > Dispatching CORE Worker...")
    future({ get_core_data(search_term, limit = limit, api_key = core_key) })
  } else { NULL }
  
  # 3. Conditional Run (PatentsView)
  future_patents <- if (!is.null(uspto_key) && nchar(uspto_key) > 0) {
    print("    > Dispatching PatentsView Worker...")
    future({ get_patentsview_data(search_term, limit = limit, api_key = uspto_key) })
  } else { NULL }
  
  # --------------------------------------------------------------------------
  # 3. PART B: RESTRICTED DATA (Scopus)
  # --------------------------------------------------------------------------
  restricted_data <- NULL
  
  if (!is.null(elsevier_key) && nchar(elsevier_key) > 0) {
    
    # This message often got skipped because Scopus logic blocked immediately.
    # The Sys.sleep inside report_status fixes this.
    report_status(0.05, "Indexing Scopus/Embase (Synchronous)...")
    
    scopus_cache_key <- paste0(search_term, "_scopus")
    
    if (check_s3_cache(scopus_cache_key, max_age_days = 7)) {
      print("    > S3 SUB-HIT: Scopus Data")
      restricted_data <- fetch_from_s3(scopus_cache_key)
    } 
    
    if (is.null(restricted_data)) {
      print("    > S3 SUB-MISS: Scopus Data - Scraping...")
      scopus_meta <- get_scopus_data(search_term, max_records = limit, api_key = elsevier_key)
      
      if (!is.null(scopus_meta) && nrow(scopus_meta) > 0) {
        restricted_data <- retrieve_scopus_abstracts(scopus_meta, search_term = search_term, api_key = elsevier_key)
        if (!is.null(restricted_data) && nrow(restricted_data) > 0) {
          save_to_s3(scopus_cache_key, restricted_data)
        }
      }
    }
  } else {
    print("    > No Elsevier Key - Skipping Scopus")
  }
  
  # --- COLLECT RESULTS ---
  # Crucial: We announce this BEFORE calling value(), which freezes the app.
  report_status(0.1, "Waiting for Workers to Return...") 
  
  epmc <- value(future_epmc)
  oa   <- value(future_openalex) 
  ct   <- value(future_clinical_trials)
  bx   <- value(future_biorxiv)
  core <- if (!is.null(future_core)) value(future_core) else NULL
  pt   <- if (!is.null(future_patents)) value(future_patents) else NULL
  
  report_status(0.1, "Binding Data Sources...")
  public_data <- bind_rows(list(
    EPMC = epmc, 
    OpenAlex = oa, 
    CORE = core, 
    `clinicaltrials.gov` = ct, 
    bioRxiv = bx,
    Patent = pt
  ), .id = "Source_Label")
  
  # --------------------------------------------------------------------------
  # 4. PART B: NIH & NSF INTEGRATION (if requested)
  # --------------------------------------------------------------------------
  nih_nsf_merged <- NULL
  
  # --- NEW: CONDITIONAL NIH/NSF INTEGRATION ---
  if (Sys.getenv("INTEGRATE_NIH_NSF") == "1") {
    report_status(0.1, "Extracting NIH & NSF...")
    print("    > Dispatching NIH & NSF Workers...")
    
    # Defensive execution
    nih_raw <- tryCatch({ get_nih_reporter_data(search_term, desired_results = limit) }, error = function(e) data.frame())
    
    # UPDATED: NSF with strict print_fields truncation
    # UPDATED: Removed 'url' to prevent API rejection
    nsf_raw <- tryCatch({ 
      get_all_nsf_awards_baseR_v2(
        search_term, 
        max_results = limit, 
        print_fields = "id,title,abstractText,pdPIName,awardeeName,date"
      ) 
    }, error = function(e) {
      print(paste("NSF Hard Catch:", e$message))
      data.frame()
    })
    
    # Apply the strict mapping schema
    nih_nsf_merged <- merge_nih_nsf_to_schema(nih_raw, nsf_raw)
    
    # Bind to the master pipeline
  }
  
  # --------------------------------------------------------------------------
  # 5. PART C: COMBINE & PROCESS
  # --------------------------------------------------------------------------
  print("--- Processing Combined Results ---")
  report_status(0.1, "Deduplicating Records...")
  
  combined_data <- bind_rows(public_data, restricted_data, nih_nsf_merged, .id = "Source_Label")
  
  if (nrow(combined_data) == 0) {
    print("No results found across any database.")
    return(list(deduplicated_data = NULL, original_combined_data = NULL))
  }
  
  # Deduplicate
  dedup_results <- deduplicate_data(combined_data)
  final_data <- dedup_results$deduplicated
  
  # --------------------------------------------------------------------------
  # 5. PART D: CLEANUP & FORMATTING
  # --------------------------------------------------------------------------
  if (!"AuthorAffiliations" %in% names(final_data) || all(is.na(final_data$AuthorAffiliations))) {
    final_data <- process_affiliations_for_shiny(final_data)
  }
  
  # --------------------------------------------------------------------------
  # 6. PART E: HIT DETECTION & BIOINFORMATICS FLAG
  # --------------------------------------------------------------------------
  report_status(0.1, "Running Hit Detection (Viruses/Cells)...")
  
  if (exists("immune_cell_alias_list") && exists("virus_alias_expanded")) {
    immune_cell_alias_list_lower <- lapply(immune_cell_alias_list, tolower)
    virus_alias_expanded_lower <- lapply(virus_alias_expanded, tolower)
    
    immune_regex_list <- lapply(immune_cell_alias_list_lower, function(aliases) {
      paste0("\\b", gsub("\\s+", "\\\\s+", aliases), "\\b", collapse = "|")
    })
    virus_regex_list <- lapply(virus_alias_expanded_lower, function(aliases) {
      paste0("\\b", gsub("\\s+", "\\\\s+", aliases), "\\b", collapse = "|")
    })
    
    final_data <- perform_hit_detection(final_data, immune_regex_list, virus_regex_list)
  }
  
  # FAST: Vectorized check
  bio_regex <- paste(bioinformatics_keywords_lower, collapse = "|")
  
  final_data <- final_data %>%
    mutate(
      combined_text = paste(tolower(Title), tolower(Abstract)),
      is_bioinformatics = grepl(bio_regex, combined_text)
    ) %>%
    select(-combined_text)
  
  final_output <- final_data %>% distinct(DOI, Title, .keep_all = TRUE)
  
  # --------------------------------------------------------------------------
  # 7. GLOBAL CACHE SAVE
  # --------------------------------------------------------------------------
  report_status(0.1, "Finalizing & Caching...")
  
  save_to_s3(search_term, final_output, elsevier_key = elsevier_key, uspto_key = uspto_key, core_key = core_key)
  
  return(list(
    deduplicated_data = final_output, 
    original_combined_data = combined_data,
    metadata = list(source = "API", timestamp = Sys.time()) 
  ))
}

