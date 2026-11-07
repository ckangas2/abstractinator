# app/server/plot.R
#
# The Plotinator: filtered plot data, the plot, its filter controls, and
# click-to-save.
#
# Runs inside server() in app.R (sourced with local = TRUE), so it shares
# input, output, session and every variable defined by the parts before it.

  # ========================================================================
  # PLOTINATOR LOGIC (Refactored & Consolidated)
  # ========================================================================
  
  filtered_plot_data <- eventReactive(
    {
      input$dateRange
      input$primaryCellFilter
      input$primaryVirusFilter
      input$pathogen_pool
      input$showBioinformatics
      input$n_articles_to_plot
      input$main_app_tabs 
    },
    {
      # 1. Gatekeeping
      req(input$main_app_tabs == "Plotinator")
      req(rv$article_df()) 
      
    
      # ------------------------
      
      # 2. ETL / Normalization Block
      df <- rv$article_df() %>%
        mutate(
          PlotDate = case_when(
            Source == "clinicaltrials.gov" ~ {
              as.Date(str_extract(PublicationDate, "(?<=Start: )[^\\|]+"))
            },
            TRUE ~ as.Date(PublicationDate)
          ),
          is_bioinformatics = as.logical(is_bioinformatics),
          
          # --- THE FIX: ID BACKFILL ---
          # If DOI is missing (e.g., Clinical Trials), fall back to NCTId or URL.
          # This ensures the plot always has a valid key for clicking.
          DOI = case_when(
            !is.na(DOI) & nchar(trimws(DOI)) > 0 ~ DOI,
            !is.na(NCTId) & nchar(trimws(NCTId)) > 0 ~ NCTId,
            !is.na(URL) & nchar(trimws(URL)) > 0 ~ URL,
            TRUE ~ paste0("unknown_id_", row_number()) # Last resort to prevent NA
          )
        )
      
      # 3. Filter Chain
      
      # Date Filter
      if (!is.null(input$dateRange)) {
        df <- df %>% 
          filter(between(PlotDate, input$dateRange[1], input$dateRange[2]))
      }
      
      # Cell Type Filter
      if (!is.null(input$primaryCellFilter) && !"All" %in% input$primaryCellFilter) {
        df <- df %>% filter(primary_cell %in% input$primaryCellFilter)
      }
      
      # Pathogen filter, applied to whichever pool is selected
      pathogen_col <- current_pool()$column
      if (!pathogen_col %in% names(df)) pathogen_col <- "primary_virus"
      if (!is.null(input$primaryVirusFilter) && !"All" %in% input$primaryVirusFilter) {
        df <- df %>% filter(.data[[pathogen_col]] %in% input$primaryVirusFilter)
      }
      
      # Bioinformatics Flag
      if (input$showBioinformatics == "Bioinformatics") {
        df <- df %>% filter(isTRUE(is_bioinformatics))
      }
      
      # 4. Final Polish
      df <- df %>%
        arrange(desc(PublicationDate)) %>%
        slice_head(n = input$n_articles_to_plot) 
      
     
      # ----------------------
      
      return(df)
    },
    ignoreNULL = FALSE 
  )
  
  output$allArticlesPlotOutput <- renderPlotly({
    req(input$main_app_tabs == "Plotinator")
    
    # 1. Get Data
    plot_df <- filtered_plot_data() 
    
    # 2. Empty State Handling (Defensive)
    if (nrow(plot_df) == 0) {
      msg <- if (input$showBioinformatics == "Bioinformatics") {
        "No Bioinformatics Focused Immune Cell Articles Found"
      } else {
        "No Immune Cell Related Articles Found"
      }
      
      # Return a clean empty plot to prevent Plotly grid artifacts
      return(plotly::plot_ly(source = "article_plot_click") %>% 
               plotly::event_register("plotly_click") %>%
               plotly::layout(
                 title = list(text = msg, y = 0.5), 
                 xaxis = list(visible = FALSE),
                 yaxis = list(visible = FALSE)
               ))
    }
    
    # 3. Prepare Data
    # Ensure we have required inputs before processing
    req(input$primaryVirusFilter, input$primaryCellFilter)
    
    prepared_data <- prepare_plot_data(plot_df, pathogen_col = current_pool()$column)
    
    # 4. Validation (THE FIX)
    # Old Code (Crashed): validate(!is.null(prepared_data), "msg")
    # New Code (Works):   validate(need(!is.null(prepared_data), "msg"))
    
    
    
    shiny::validate(
      need(!is.null(prepared_data), "Error: Plot data preparation failed.")
    )
    
    # 5. Generate Plot
    generate_interactive_plot(
      data_filtered = prepared_data,
      selected_viruses = input$primaryVirusFilter,    
      selected_cell_types = input$primaryCellFilter,  
      n_cols_max = input$plot_n_cols_max,
      pathogen_label = current_pool()$label
    )
  })
  
  # ==============================================================================
  # 5. DYNAMIC UI UPDATERS (Dates & Lexicons)
  # ==============================================================================
  
  # A. Auto-Update Date Range based on Data
  observe({
    req(rv$article_df())
    df <- rv$article_df()
    
    dates <- df %>%
      mutate(
        TempDate = case_when(
          Source == "clinicaltrials.gov" ~ as.Date(str_extract(PublicationDate, "(?<=Start: )[^\\|]+")),
          TRUE ~ as.Date(PublicationDate)
        )
      ) %>%
      pull(TempDate)
    
    dates <- dates[!is.na(dates)]
    
    if (length(dates) > 0) {
      min_date <- min(dates)
      max_date <- max(dates)
      
      updateDateRangeInput(session, "dateRange",
                           start = min_date,
                           end = max_date,
                           min = min_date,
                           max = max_date)
    }
  })
  
  # B. Updated Quick Filters (MACROS)
  observeEvent(input$btn_virus_known, {
    req(exists(current_pool()$aliases))
    known_viruses <- names(get(current_pool()$aliases)) 
    
    # We update ONLY the selection here
    shinyWidgets::updatePickerInput(
      session = session,
      inputId = "primaryVirusFilter",
      selected = known_viruses
    )
  })
  
  observeEvent(input$btn_cell_known, {
    req(exists("immune_cell_alias_list"))
    known_cells <- names(immune_cell_alias_list)
    
    shinyWidgets::updatePickerInput(
      session = session,
      inputId = "primaryCellFilter",
      selected = known_cells
    )
  })
  
  # --- C. POPULATE DROPDOWNS (WITH NON-DESCRIPT OPTION) ---
  observe({
    # 2. Populate Cell Choices
    if (exists("immune_cell_alias_list")) {
      # We manually add "Non-descript" to the list
      cell_choices <- c("All", "Non-descript", sort(names(immune_cell_alias_list)))
      
      shinyWidgets::updatePickerInput(
        session = session,
        inputId = "primaryCellFilter",
        choices = cell_choices,
        selected = "All"
      )
    }
  })
  
  # ========================================================================
  # CLICK-TO-TOGGLE (Crash-Proof: Handles Empty Lists)
  # ========================================================================
  observeEvent(event_data("plotly_click", source = "article_plot_click"), {
    
    # 1. Get Event Data
    click_data <- event_data("plotly_click", source = "article_plot_click")
    req(click_data)
    
    clicked_url <- as.character(click_data$key)
    
    # 2. Check Existence (Safe vs Empty List)
    current_list <- rv$reading_list()
    match_index <- integer(0) # Default to empty integer
    
    # CRITICAL FIX: Check length first to avoid 'sapply' returning a list on empty input
    if (length(current_list) > 0) {
      
      # Use vapply instead of sapply. 
      # FUN.VALUE = logical(1) guarantees it returns TRUE/FALSE vector, never a list.
      matches <- vapply(current_list, function(x) {
        isTRUE(as.character(x$URL) == clicked_url)
      }, FUN.VALUE = logical(1))
      
      match_index <- which(matches)
    }
    
    # 3. Toggle Logic
    if (length(match_index) > 0) {
      # --- REMOVE CASE ---
      item_title <- current_list[[match_index[1]]]$Title
      
      updated_list <- current_list[-match_index]
      rv$reading_list(updated_list)
      
      showNotification(
        paste("Removed:", str_trunc(item_title, 30)), 
        type = "warning", 
        duration = 2
      )
      
    } else {
      # --- ADD CASE ---
      article_row <- rv$article_df() %>% 
        filter(URL == clicked_url) %>%
        slice(1) 
      
      if (nrow(article_row) > 0) {
        article_item <- list(
          Title = article_row$Title,
          Abstract = article_row$Abstract,
          Authors = article_row$Authors,
          AuthorAffiliations = article_row$AuthorAffiliations, 
          PublicationDate = article_row$PublicationDate,
          URL = article_row$URL,
          DOI = article_row$DOI,
          Source = article_row$Source,
        primary_cell = article_row$primary_cell, primary_virus = article_row$primary_virus,
        primary_bacteria = article_row$primary_bacteria,
          ItemKey = article_row$ItemKey
        )
        
        rv$reading_list(append(current_list, list(article_item)))
        
        showNotification(
          paste("Added:", str_trunc(article_row$Title, 30)), 
          type = "message", 
          duration = 2
        )
      }
    }
  })
