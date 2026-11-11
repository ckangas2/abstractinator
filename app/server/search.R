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
    rv$source_counts <- extraction_results$source_counts
    rv$retrieved_at  <- extraction_results$metadata$retrieved_at
    rv$from_cache    <- identical(extraction_results$metadata$source, "CACHE")

    # Say so when a database didn't answer (or stopped part-way): the results
    # are then incomplete, and weren't cached, so searching again retries it.
    incomplete <- incomplete_source_labels(extraction_results$source_counts)
    if (length(incomplete) > 0) {
      showNotification(
        paste0(paste(incomplete, collapse = ", "),
               " didn't respond fully",
               ", so these results may be incomplete. Searching again will retry."),
        type = "warning", duration = 10)
    }
    
    
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
          
          # Trials carry start, end and status as separate fields; the table
          # shows them as one label, which SortDate and the Plotinator parse.
          mutate(
            PublicationDate = if ("TrialStatus" %in% names(.)) {
              ifelse(Source == "clinicaltrials.gov",
                     trial_date_label(TrialStart, TrialEnd, TrialStatus), PublicationDate)
            } else PublicationDate
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

          # Columns the Therapinator, the Deduplicatinator report and the
          # reading list read. Not every search has them (no trials, a cached
          # result from before a field existed), so fill them in.
          mutate(
            primary_modality       = if ("primary_modality" %in% names(.)) primary_modality else NA_character_,
            modality_hits_combined = if ("modality_hits_combined" %in% names(.)) modality_hits_combined else vector("list", n()),
            Interventions          = if ("Interventions" %in% names(.)) Interventions else NA_character_,
            Conditions             = if ("Conditions" %in% names(.)) Conditions else NA_character_,
            Phase                  = if ("Phase" %in% names(.)) Phase else NA_character_,
            TrialStatus            = if ("TrialStatus" %in% names(.)) TrialStatus else NA_character_,
            TrialStart             = if ("TrialStart" %in% names(.)) TrialStart else NA_character_,
            TrialEnd               = if ("TrialEnd" %in% names(.)) TrialEnd else NA_character_,
            MergedFrom             = if ("MergedFrom" %in% names(.)) MergedFrom else NA_character_,
            GrantID                = if ("GrantID" %in% names(.)) GrantID else NA_character_
          ) %>%

          # Chips for registered programs the title or abstract names, with the
          # registry's own linking rules (R/registry_chips.R). HTML, "" where none;
          # the title renderer in app/dt_options.R draws them from row[36].
          mutate(RegistryPrograms = registry_programs_html(Title, Abstract)) %>%
          
          # --- UPDATE SELECT ---
          # Column order is a contract: the table's JS reads row[5] URL, row[6] DOI,
          # row[10] Source, row[17] primary_bacteria and row[22] ItemKey. New
          # columns are APPENDED (23 onwards) so none of those indices move.
          # Anything another tab reads must be listed here: this select is
          # what every tab sees (test-app.R checks the list).
          select(Title, Abstract, Authors, AuthorAffiliations, PublicationDate, URL, DOI,
                 EPMC_ID, CORE_ID, NCTId, Source, Affiliations, AdverseEvents,
                 SeriousAdverseEvents, is_bioinformatics, primary_cell,
                 primary_virus, primary_bacteria, immune_cell_hits_combined, virus_hits_combined,
                 bacteria_hits_combined, SortDate, ItemKey,
                 HasAbstract, PMCID, IsOpenAccess,
                 primary_modality, modality_hits_combined, Interventions, Conditions,
                 Phase, TrialStatus, TrialStart, TrialEnd, MergedFrom, GrantID,
                 RegistryPrograms)
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
          list(list(targets = 23:36, visible = FALSE))
        )
        o
      }),
      fillContainer = FALSE,
      colnames = c("Title", "Abstract", "Authors", "AuthorAffiliations", "Publication Date", 
                   "URL", "DOI", "EPMC_ID", "CORE_ID", "NCTId", "Source", "Affiliations", 
                   "AdverseEvents", "SeriousAdverseEvents", "Bioinformatics", 
                   "Primary Immune Cell", "Primary Virus", "Primary Bacteria", "Immune Cell Hits", "Virus Hits",
                   "Bacteria Hits", "SortDate", "ItemKey",
                   "HasAbstract", "PMCID", "IsOpenAccess",
                   "Therapy", "Therapy Hits", "Interventions", "Conditions", "Phase",
                   "TrialStatus", "TrialStart", "TrialEnd", "MergedFrom", "GrantID",
                   "Programs"),
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
      
      
      # ========================================================================
      # DEDUPLICATINATOR: the search report
      # ========================================================================
      # Per database: matched, retrieved, kept, merged, status; headline
      # numbers; and a log of merged records. Built from the per-source counts
      # stored with each result, so a cache hit reports the same numbers.
      dedup_stats <- dedup_source_stats(rv$source_counts, rv$article_df())
      flow <- dedup_flow(dedup_stats, nrow(rv$article_df()))

      output$dedupMergesTable <- DT::renderDataTable({
        d <- rv$article_df()
        req(d, "MergedFrom" %in% names(d))
        m <- d[!is.na(d$MergedFrom) & nzchar(d$MergedFrom), , drop = FALSE]
        req(nrow(m) > 0)
        DT::datatable(
          data.frame(Title = substr(html_to_text(m$Title), 1, 140), Kept = m$Source,
                     `Also found as` = m$MergedFrom, check.names = FALSE, stringsAsFactors = FALSE),
          rownames = FALSE, escape = TRUE, selection = "none",
          options = list(pageLength = 10, scrollX = TRUE, dom = "frtip",
                         language = list(search = "_INPUT_", searchPlaceholder = "Filter merges...")))
      })

      output$deduplicationSummaryContent <- renderUI({
        fmt <- function(n) if (length(n) == 0 || is.na(n)) "\u2014" else format(n, big.mark = ",", trim = TRUE)
        when <- rv$retrieved_at
        when_txt <- if (inherits(when, "POSIXt")) paste0(
          if (isTRUE(rv$from_cache)) "Cached result; databases queried " else "Databases queried ",
          format(when, "%b %d, %H:%M UTC", tz = "UTC"), ".")
        bad <- incomplete_source_labels(rv$source_counts)
        d <- rv$article_df()
        n_merged_rows <- if ("MergedFrom" %in% names(d)) sum(!is.na(d$MergedFrom) & nzchar(d$MergedFrom)) else 0L

        # The search as a flow, left to right: what the databases hold, what
        # was fetched, what was folded together, what is shown.
        step <- function(value, label) span(class = "flow-step",
          span(class = "flow-value", value), span(class = "flow-label", label))
        arrow <- span(class = "flow-arrow", "\u2192")
        flow_line <- div(class = "dedup-flow",
          step(paste0(fmt(flow$matched), if (!flow$matched_complete && !is.na(flow$matched)) "+"), "matched"), arrow,
          step(fmt(flow$retrieved), "retrieved"), arrow,
          step(fmt(flow$merged), "duplicates merged"), arrow,
          step(fmt(flow$unique), "unique works"))

        # One row per database, plain HTML: a handful of rows doesn't need a
        # data grid. Trial phases fold into one line under ClinicalTrials.gov.
        phases <- trial_phase_summary(d)
        status_dot <- function(st) {
          cls <- switch(st, "OK" = "ok", "Stopped early" = "partial", "No response" = "failed", "ok")
          span(class = paste("status", cls), title = st, span(class = "status-dot"),
               span(class = "status-text", st))
        }
        rows <- lapply(seq_len(nrow(dedup_stats)), function(i) {
          r <- dedup_stats[i, ]
          main <- tags$tr(
            tags$td(class = "db", r$Source),
            tags$td(class = "num", fmt(r$Retrieved)),
            tags$td(class = "num muted", fmt(r$Matched)),
            tags$td(class = "num", fmt(r$Unique)),
            tags$td(class = "num", if (r$Merged > 0) fmt(r$Merged) else span(class = "muted", "0")),
            tags$td(status_dot(r$Status)))
          if (r$Source == "ClinicalTrials.gov" && length(phases)) {
            sub <- tags$tr(class = "sub", tags$td(colspan = 6,
              span(class = "sub-label", "Phases"),
              lapply(seq_along(phases), function(k) span(class = "phase-chip",
                names(phases)[k], span(class = "phase-n", phases[[k]])))))
            tagList(main, sub)
          } else main
        })
        db_table <- div(class = "dedup-table-wrap", tags$table(class = "dedup-table",
          tags$thead(tags$tr(
            tags$th("Database"), tags$th(class = "num", "Retrieved"), tags$th(class = "num", "Matched"),
            tags$th(class = "num", "Kept"), tags$th(class = "num", "Merged"), tags$th(span(class = "status-text", "Status")))),
          tags$tbody(rows)))

        div(class = "dedup-panel",
          h4("Deduplicatinator"),
          p(class = "dedup-lead", time_message,
            if (!is.null(when_txt)) span(class = "dedup-when", when_txt)),
          if (length(bad)) div(class = "dedup-warning",
            paste0(paste(bad, collapse = ", "), " didn't respond fully, so these results are incomplete and weren't cached. Searching again will retry.")),
          flow_line,
          h5("By database"),
          if (nrow(dedup_stats)) db_table,
          p(class = "plot-caveat",
            "Retrieved: records fetched (a database's top matches, not all of them). Matched: the database's own total. Kept: unique records shown with that database as the source. Merged: its records folded into another copy of the same work (the same DOI, the same grant project, or the same title when one copy has no DOI)."),
          if (n_merged_rows > 0) tags$details(class = "dedup-merges",
            tags$summary(sprintf("Merged records (%d)", n_merged_rows)),
            DT::dataTableOutput("dedupMergesTable"))
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
