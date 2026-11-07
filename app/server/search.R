# app/server/search.R
#
# Running a search in the background, showing the results table and
# Deduplicatinator, and the search triggers (button, Enter, quick chips).
#
# Runs inside server() in app.R (sourced with local = TRUE), so it shares
# input, output, session and every variable defined by the parts before it.

  # ========================================================================
  # SEARCH BUTTON LOGIC
  # ========================================================================
  # Background search task. Runs the search as a promise so this visitor's
  # search never freezes the app for anyone else (all visitors share one R process).
  search_ctx <- new.env()
  search_task <- ExtendedTask$new(function(term, elsevier, core, uspto, limit) {
    orchestrate_data_extraction_async(
      search_term = term, limit = limit,
      elsevier_key = elsevier, core_key = core, uspto_key = uspto
    )
  })
  
  # --- 1. START A SEARCH ---
  observeEvent(search_request(), {
    req_info <- search_request()
    search_term <- req_info$term
    req(search_term)
    if (nchar(trimws(search_term)) == 0) return()
    
    if (search_task$status() == "running") {
      showNotification("A search is already running for you. Results will appear shortly.",
                       type = "warning", duration = 4)
      return()
    }
    
    shinyjs::hide("landing_container")
    
    # ... [Top of observeEvent] ...
    session$sendCustomMessage(type = 'show_loading', message = list())
    session$sendCustomMessage(type = 'update_loading_message', message = "")
    
    output$searchResults <- renderText("")
    
    # --- RESET ICONS ---
    shinyjs::hide("completionIconLeft")
    shinyjs::hide("completionIconRight")
    # -------------------
    
    start_time <- Sys.time()
    
    session$sendCustomMessage(type = 'show_loading', message = list())
    session$sendCustomMessage(type = 'update_loading_message', message = "")
    
    
    output$searchResults <- renderText("")
    output$completionIconLeft <- renderImage(NULL, deleteFile = FALSE)
    output$completionIconRight <- renderImage(NULL, deleteFile = FALSE)
    output$resultsDisplay <- renderDataTable(NULL)
    output$deduplicationTable <- DT::renderDataTable(NULL)
    rv$original_article_df <- NULL
    rv$article_df(NULL)
    rv$deduplication_table <- NULL
    
    session$sendCustomMessage(type = 'toggle_feedback', message = list(show = FALSE))
    
    # Remember what this search is, for when the results come back
    search_ctx$term       <- search_term
    search_ctx$start_time <- start_time
    search_ctx$deep       <- isTRUE(req_info$deep)
    search_ctx$elsevier   <- resolve_api_key(session_keys$elsevier, "ELSEVIER_API_KEY")
    search_ctx$core       <- resolve_api_key(session_keys$core, "CORE_API_KEY")
    search_ctx$uspto      <- resolve_api_key(session_keys$uspto, "USPTO_API_KEY")
    
    
    empty_state(NULL)
    shinyjs::addClass("searchButton", "is-searching")
    search_task$invoke(search_term, search_ctx$elsevier, search_ctx$core, search_ctx$uspto, req_info$limit)
  })
  
  # --- 2. RESULTS ARRIVED (or the search failed) ---
  observeEvent(search_task$status(), {
    st <- search_task$status()
    if (st %in% c("initial", "running")) return()
    
    extraction_results <- if (st == "success") {
      search_task$result()
    } else {
      err <- tryCatch(search_task$result(), error = function(e) e)
      msg <- if (inherits(err, "condition")) conditionMessage(err) else "unknown error"
      message("[Search] Failed: ", msg)
      showNotification("Something went wrong with that search. Please try again in a moment.",
                       type = "error", duration = 8)
      list(deduplicated_data = NULL, original_combined_data = NULL)
    }
    
    shinyjs::removeClass("searchButton", "is-searching")
    source_filter("All")
    
    # (1) Make all text from external databases safe to display
    extraction_results$deduplicated_data <- sanitize_results(extraction_results$deduplicated_data)
    
    search_term     <- search_ctx$term
    start_time      <- search_ctx$start_time
    active_elsevier <- search_ctx$elsevier
    active_core     <- search_ctx$core
    active_uspto    <- search_ctx$uspto
    
    rv$initial_extracted_data <- extraction_results$original_combined_data 
    
    
    if (!is.null(extraction_results$deduplicated_data)) {
      rv$article_df(extraction_results$deduplicated_data)
    } else {
      rv$article_df(NULL)
    }
    
    if (!is.null(rv$article_df())) {
      
      rv$deduplication_table <- verify_deduplication(rv$article_df(), rv$initial_extracted_data)
      
      updateSelectInput(session, "primaryCellFilter",
                        choices = c("All", unique(rv$article_df()$primary_cell)))
      
      shinyjs::show("results_container") 
    } else {
      shinyjs::hide("results_container")
    }
    
    if (!is.null(rv$article_df())) {
      end_time <- Sys.time()
      search_duration <- round(as.numeric(difftime(end_time, start_time, units = "secs")), 2)
      
      
      ## --- TIME FOR S3 LOGGER ---
      
      # FIX: Use 'extraction_results' (your actual variable), not 'results'
      log_count <- if (!is.null(extraction_results$deduplicated_data)) nrow(extraction_results$deduplicated_data) else 0
      
      # Defensive check for metadata
      log_source <- "API" 
      if (!is.null(extraction_results$metadata) && !is.null(extraction_results$metadata$source)) {
        log_source <- extraction_results$metadata$source
      }
      
      # 4. LOG TO S3 (Synchronous)
      # Maintainer testing is logged as "self" rather than "website", so it can
      # be excluded from real usage counts: https://abstractinator.me/?self=1
      log_channel <- tryCatch({
        qs <- shiny::parseQueryString(session$clientData$url_search)
        if (identical(qs$self, "1")) "self" else "website"
      }, error = function(e) "website")

      # Records found before deduplication, vs log_count which is after it.
      log_total_found <- tryCatch(
        if (!is.null(extraction_results$original_combined_data)) {
          nrow(extraction_results$original_combined_data)
        } else NA_integer_,
        error = function(e) NA_integer_
      )

      log_sources <- tryCatch({
        d <- extraction_results$deduplicated_data
        if (!is.null(d) && "Source" %in% names(d)) as.list(table(d$Source)) else NULL
      }, error = function(e) NULL)

      log_search_to_s3(
        search_term    = search_term,
        duration_sec   = search_duration,
        result_count   = log_count,
        source_type    = log_source,
        elsevier_key   = active_elsevier,
        uspto_key      = active_uspto,
        core_key       = active_core,
        channel        = log_channel,
        event          = "search",
        deep           = isTRUE(search_ctx$deep),
        total_found    = log_total_found,
        returned       = log_count,
        from_cache     = identical(log_source, "CACHE"),
        source_counts  = log_sources
      )

    
      

      unique_results_count <- nrow(rv$article_df())
      time_message <- paste0(unique_results_count, " unique Abstractinations in ", search_duration, " seconds")
      
      output$searchTime <- renderUI({
        tags$div(class = "search-time-summary", time_message)
      })
      
      output$searchResults <- renderText(paste("Found", nrow(rv$article_df()), "articles."))
      
      # --- NEW VISIBILITY LOGIC ---
      # Instead of re-rendering (which resets the theme), we just reveal the hidden elements
      shinyjs::show("completionIconLeft")
      shinyjs::show("completionIconRight")
      
      
      session$sendCustomMessage(type = 'toggle_feedback', message = list(show = TRUE))
      
      # --- STANDARDIZE & DISPLAY ---
      # Ensure all expected columns exist, even if a search was skipped
      
      rv$article_df(
        rv$article_df() %>%
          # 1. Fix JSON formatting (Existing)
          
          
          # 2. Defensive Schema Enforcement
          mutate(
            CORE_ID = if ("CORE_ID" %in% names(.)) CORE_ID else NA_character_,
            EPMC_ID = if ("EPMC_ID" %in% names(.)) EPMC_ID else NA_character_,
            NCTId   = if ("NCTId" %in% names(.)) NCTId else NA_character_,
            DOI     = if ("DOI" %in% names(.)) DOI else NA_character_,
            URL     = if ("URL" %in% names(.)) URL else NA_character_,
            # Columns only some sources provide (e.g. Affiliations/AdverseEvents come
            # from ClinicalTrials.gov), so a search with no trials still has them
            Abstract             = if ("Abstract" %in% names(.)) Abstract else NA_character_,
            Authors              = if ("Authors" %in% names(.)) Authors else NA_character_,
            AuthorAffiliations   = if ("AuthorAffiliations" %in% names(.)) AuthorAffiliations else NA_character_,
            Affiliations         = if ("Affiliations" %in% names(.)) Affiliations else NA_character_,
            AdverseEvents        = if ("AdverseEvents" %in% names(.)) AdverseEvents else NA_character_,
            SeriousAdverseEvents = if ("SeriousAdverseEvents" %in% names(.)) SeriousAdverseEvents else NA_character_,
            primary_cell         = if ("primary_cell" %in% names(.)) primary_cell else NA_character_,
            primary_virus        = if ("primary_virus" %in% names(.)) primary_virus else NA_character_,
            primary_bacteria     = if ("primary_bacteria" %in% names(.)) primary_bacteria else NA_character_,
            # Only EPMC supplies these, so every other source needs them filled in
            PMCID                = if ("PMCID" %in% names(.)) PMCID else NA_character_,
            IsOpenAccess         = if ("IsOpenAccess" %in% names(.)) IsOpenAccess else NA_character_,
            
            # Ensure Boolean Flags exist
            is_bioinformatics = if ("is_bioinformatics" %in% names(.)) as.logical(is_bioinformatics) else FALSE,
            
            # Ensure Hit Counters exist
            immune_cell_hits_combined = if ("immune_cell_hits_combined" %in% names(.)) immune_cell_hits_combined else vector("list", n()),
            virus_hits_combined = if ("virus_hits_combined" %in% names(.)) virus_hits_combined else vector("list", n()),
            bacteria_hits_combined = if ("bacteria_hits_combined" %in% names(.)) bacteria_hits_combined else vector("list", n())
          ) %>%
          
          # --- FIX: WRAP THIS IN MUTATE() ---
          mutate( 
            # Parse each date on its own: sources use different formats
            # (2023-07-15, NSF's 07/15/2023, trials' "Start: 2016-05-20 | ...", bare years).
            # Unparseable dates become NA instead of crashing the table.
            SortDate = as.Date(lubridate::parse_date_time(
              ifelse(grepl("Start:", PublicationDate),
                     trimws(str_extract(PublicationDate, "(?<=Start: )[^|]+")),
                     PublicationDate),
              orders = c("Ymd", "mdY", "Ym", "Y"), quiet = TRUE
            )),
            ItemKey = make_item_key(DOI, URL, Title),

            # Abstract-less records are kept, not dropped: a grant or a trial
            # with no abstract is still a real hit, and dropping them would make
            # the per-source counts dishonest. They are sorted below records that
            # do have one, and the cell says which source came up empty rather
            # than leaving a blank that reads like a bug.
            HasAbstract = !is.na(Abstract) &
                          !trimws(as.character(Abstract)) %in% c("", "NA", "NULL"),
            Abstract = ifelse(
              HasAbstract,
              as.character(Abstract),
              paste0("<span style=\"opacity:0.45; font-style:italic;\">",
                     "No abstract provided by ", Source, "</span>")
            )
          ) %>% # <--- CLOSE MUTATE AND PIPE
          
          # --- UPDATE SELECT ---
          # Column order is a contract: the table's JS reads row[5] URL, row[6] DOI,
          # row[10] Source, row[17] primary_bacteria and row[22] ItemKey. New
          # columns are APPENDED (23, 24, 25) so none of those indices move.
          select(Title, Abstract, Authors, AuthorAffiliations, PublicationDate, URL, DOI,
                 EPMC_ID, CORE_ID, NCTId, Source, Affiliations, AdverseEvents,
                 SeriousAdverseEvents, is_bioinformatics, primary_cell,
                 primary_virus, primary_bacteria, immune_cell_hits_combined, virus_hits_combined,
                 bacteria_hits_combined, SortDate, ItemKey,
                 HasAbstract, PMCID, IsOpenAccess)
      )
      
      output$resultsDisplay <- DT::renderDataTable({
        df <- rv$article_df()
        f <- source_filter()
        if (!is.null(df) && f != "All") df <- df[df$Source == f, , drop = FALSE]
        df
      },
      # Copy dt_options and assign into it, so the shared definition keeps
      # serving the other tables untouched.
      #
      # NOT modifyList(): it recurses whenever both sides are lists, and
      # columnDefs/order are UNNAMED lists. It descended into them, found no
      # names to match, and kept the originals - so the hidden columns showed
      # and the sort never applied. Plain assignment replaces outright.
      #
      # Sort abstract-bearing rows first, then newest-first WITHIN each group:
      # ordering by abstract alone would bury recent grants at the bottom.
      options = local({
        o <- dt_options
        o$order <- list(list(23, "desc"), list(21, "desc"))
        o$columnDefs <- c(
          if (is.null(dt_options$columnDefs)) list() else dt_options$columnDefs,
          list(list(targets = c(23, 24, 25), visible = FALSE))
        )
        o
      }),
      fillContainer = FALSE,
      colnames = c("Title", "Abstract", "Authors", "AuthorAffiliations", "Publication Date", 
                   "URL", "DOI", "EPMC_ID", "CORE_ID", "NCTId", "Source", "Affiliations", 
                   "AdverseEvents", "SeriousAdverseEvents", "Bioinformatics", 
                   "Primary Immune Cell", "Primary Virus", "Primary Bacteria", "Immune Cell Hits", "Virus Hits",
                   "Bacteria Hits", "SortDate", "ItemKey",
                   "HasAbstract", "PMCID", "IsOpenAccess"),
      rownames = FALSE,
      escape = FALSE,
      selection = 'none',
      callback = JS(
        # 1. Initialize Reading List Array
        "if (!window.readingList) { window.readingList = []; }",
        
        # 2. Handle Loading Screen Hiding
        'Shiny.addCustomMessageHandler("hide_loading_dt", function(message) {',
        '  $(".loading-overlay").hide();',
        '});',
        '$(this).on("draw.dt", function() {',
        '  Shiny.setInputValue("dt_rendered", true);',
        '  Shiny.setInputValue("hide_loading_trigger", Math.random());',
        '});',
        
        # 3. Handle Author Affiliation Expansion
        "$(document).off('click', '.author-expand-trigger').on('click', '.author-expand-trigger', function() {",
        "  var affiliationId = $(this).data('affiliation-id');",
        "  $('#' + affiliationId).toggleClass('hidden');",
        "});",
        
        # 4. Handle "Add to Reading List" Click
        "$(document).off('click', '.add-to-reading-list-inline').on('click', '.add-to-reading-list-inline', function() {",
        "  var index = $(this).data('index');",
        "  var doi = $(this).attr('data-key');",
        "  var button = $(this);",
        "  var title = $(this).closest('.title-container').find('a').text() || $(this).closest('.title-container').text();",
        
        # Check if already in list
        "  var itemIndex = -1;",
        "  for (var i = 0; i < window.readingList.length; i++) {",
        "    if (window.readingList[i].key === doi) { itemIndex = i; break; }",
        "  }",
        
        "  if (itemIndex === -1) {",
        "    // Add it",
        "    window.readingList.push({ key: doi, Title: title });",
        "    button.text('Remove from Reading List');",
        "    button.removeClass('btn-outline-light').addClass('btn-success');", # Visual feedback
        "    Shiny.setInputValue('add_to_reading_list', doi, { priority: 'event' });",
        "  } else {",
        "    // Remove it",
        "    window.readingList.splice(itemIndex, 1);",
        "    button.text('Add to Reading List');",
        "    button.removeClass('btn-success').addClass('btn-outline-light');",
        "    Shiny.setInputValue('remove_from_reading_list', doi, { priority: 'event' });",
        "  }",
        "});"
      )
      )
      
      # ========================================================================
      # DEDUPLICATION TABLE
      # ========================================================================
      
      
      output$deduplicationTable <- DT::renderDataTable({
        add_trial_phase_rows(rv$deduplication_table, rv$initial_extracted_data)
      },
      options = list(searching = FALSE, paging = FALSE, info = FALSE),
      # Row numbers carry no meaning here - the rows are sources, not a sequence.
      rownames = FALSE,
      colnames = c("Source", "Total Search Records", "Unique Records", HTML("Duplicate Records Removed")),
      escape = FALSE,
      selection = "none"
      )
      
      # Phase breakdown as indented rows beneath clinicaltrials.gov. Only the
      # record count is filled in: the other two columns are about duplicates,
      # and a phase subset has no honest value to put there, so they stay empty
      # rather than repeating a number that would look computed.
      add_trial_phase_rows <- function(tbl, raw) {
        if (is.null(tbl) || !nrow(tbl)) return(tbl)
        if (is.null(raw) || !"Source" %in% names(raw)) return(tbl)
        tr <- raw[!is.na(raw$Source) & raw$Source == "clinicaltrials.gov", , drop = FALSE]
        if (!nrow(tr)) return(tbl)

        ph <- if ("Phase" %in% names(tr)) as.character(tr$Phase) else rep(NA_character_, nrow(tr))
        # Observational studies have no phase by design; count them rather than
        # hiding them, or the sub-rows will not add up to the trial total.
        ph[is.na(ph) | !nzchar(trimws(ph))] <- "Not applicable"

        counts <- table(ph)
        nm <- names(counts)
        counts <- counts[order(nm == "Not applicable", nm)]
        if (!length(counts)) return(tbl)

        i <- which(trimws(tolower(as.character(tbl[[1]]))) == "clinicaltrials.gov")
        if (!length(i)) return(tbl)
        i <- i[1]

        sub <- tbl[rep(i, length(counts)), , drop = FALSE]
        sub[[1]] <- sprintf(
          "<span style=\"padding-left: 26px; opacity: 0.6;\">&#8627;&nbsp; %s</span>",
          names(counts)
        )
        sub[[2]] <- as.integer(counts)
        if (ncol(sub) >= 3) for (k in 3:ncol(sub)) sub[[k]] <- NA

        dplyr::bind_rows(
          tbl[seq_len(i), , drop = FALSE],
          sub,
          if (i < nrow(tbl)) tbl[(i + 1):nrow(tbl), , drop = FALSE] else NULL
        )
      }

      output$deduplicationSummaryContent <- renderUI({
        # The whole panel is one centred column: heading, table and timing line
        # share an axis, so the heading does not float off to the left of a
        # centred table.
        div(style = "max-width: 760px; margin: 0 auto;",
          h4("Deduplicatinator"),
          # Four short columns stretched across the full page leave a lot of
          # empty space between a source and its count: this is a summary, not
          # a grid. The width goes on the DT output as well as the wrapper,
          # because a max-width on a parent div does not constrain the table
          # element DT generates for itself.
          div(style = "max-width: 760px;",
              DT::dataTableOutput("deduplicationTable", width = "760px")),
          uiOutput("searchTime")
        )
      })
      
      session$sendCustomMessage(type = 'hide_loading', message = list())
      
    } else {
      output$searchResults <- renderText("No results found or an error occurred during the search.")
      empty_state(list(term = search_term, error = (st != "success")))
      # Stay on the results layout. Bouncing back to the landing page threw
      # away the search context, and the notice rendered into a container the
      # user had just been navigated away from.
      shinyjs::show("results_container")
      shinyjs::hide("landing_container")
      output$completionIconLeft <- renderImage({ return(NULL) }, deleteFile = FALSE)
      output$completionIconRight <- renderImage({ return(NULL) }, deleteFile = FALSE)
      output$resultsDisplay <- renderDataTable(NULL)
      output$deduplicationTable <- DT::renderDataTable(NULL)
      rv$original_article_df <- NULL
      rv$article_df(NULL)
      rv$deduplication_table <- NULL
      output$downloadButtonUI <- renderUI(NULL)
      shinyjs::hide("deduplicationSummarySection")
      session$sendCustomMessage(type = 'hide_loading', message = list())
    }
  }, ignoreInit = TRUE)
  
  # ========================================================================
  # REMOVE FROM READING LIST LOGIC
  # ========================================================================
  
  # --- RE-SYNC: Remove from Reading List Logic ---
  observeEvent(input$remove_from_reading_list, {
    # 1. Capture the DOI sent from the JS click event
    target_doi <- input$remove_from_reading_list
    req(target_doi)
    
    # 2. Access the current list
    current_list <- rv$reading_list()
    
    # 3. Use Filter to keep only items that DO NOT match the DOI
    # This is the "Low Time Preference" way to ensure precise removal
    updated_list <- Filter(function(x) {
      # Check if DOI exists and does NOT match target
      !identical(as.character(x$ItemKey), as.character(target_doi))
    }, current_list)
    
    # 4. Update the reactive value
    rv$reading_list(updated_list)
    
    # 5. Visual confirmation
    showNotification("Removed from Reading List.", type = "warning", duration = 2)
  })
  
  # ========================================================================
  # SEARCH TRIGGER LOGIC (The Race Condition Fix)
  # ========================================================================
  
  # A. The Search Button (Manual Entry)
  # When user types and clicks search, we feed the reactive value
  observeEvent(input$searchButton, {
    req(input$searchTerm)
    request_search(input$searchTerm)
  })
  
  # B. Quick Launch Chips (Direct Feed)
  # We update the UI for looks, but feed the trigger DIRECTLY to avoid the race.
  
  observeEvent(input$btn_oncolytic_virus, {
    updateTextInput(session, "searchTerm", value = "Oncolytic Virus")
    request_search("Oncolytic Virus")
  })
  
  observeEvent(input$btn_tvec, {
    updateTextInput(session, "searchTerm", value = "T-VEC")
    request_search("T-VEC")
  })
  
  observeEvent(input$btn_melanoma, {
    updateTextInput(session, "searchTerm", value = "Melanoma")
    request_search("Melanoma")
  })
  
  observeEvent(input$btn_scseq, {
    updateTextInput(session, "searchTerm", value = "scRNA-seq")
    request_search("scRNA-seq")
  })
