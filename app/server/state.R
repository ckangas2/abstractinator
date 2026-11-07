# app/server/state.R
#
# Shared per-visitor state: the search request, API keys, results and reading
# list (rv), the Plotinator pool, source chips and the empty-results notice.
# Later parts use these by name.
#
# Runs inside server() in app.R (sourced with local = TRUE), so it shares
# input, output, session and every variable defined by the parts before it.

  # Every search goes through request_search(). The nonce makes repeat searches
  # of the same term (e.g. standard, then deep) still trigger.
  search_request <- reactiveVal(NULL)
  request_search <- function(term) {
    deep <- isTRUE(input$deepSearch)
    search_request(list(
      term  = term,
      deep  = deep,
      limit = if (deep) DEEP_SEARCH_LIMIT else 50L,
      nonce = runif(1)
    ))
  }
  
  # Keys typed by THIS visitor live only in this session object.
  # Never use Sys.setenv() for user keys: all visitors share one R process,
  # so environment variables would leak one visitor's key to everyone.
  session_keys <- reactiveValues(elsevier = "", core = "", uspto = "")

  # Strict bring-your-own-key: only this visitor's own key is ever used.
  # Server keys in .Renviron are deliberately ignored here, so they can never be
  # spent on (or exposed to) website visitors. (env_name is kept for readability.)
  resolve_api_key <- function(user_key, env_name) {
    if (!is.null(user_key) && nchar(trimws(user_key)) > 0) trimws(user_key) else ""
  }
  
  rv <- reactiveValues(
    initial_extracted_data = NULL, 
    original_article_df = NULL,    
    article_df = reactiveVal(NULL), 
    deduplication_table = NULL,    
    reading_list = reactiveVal(list()),
    # Per-source retrieved/total/status, and when the databases were queried
    source_counts = NULL,
    retrieved_at = NULL,
    from_cache = FALSE
  )
  
  
  
  
  # ========================================================================
  # PLOTINATOR POOL SWITCH (Viruses <-> Bacteria <-> ...)
  # ========================================================================
  current_pool <- reactive({
    nm <- input$pathogen_pool %||% names(PATHOGEN_POOLS)[1]
    PATHOGEN_POOLS[[nm]] %||% PATHOGEN_POOLS[[1]]
  })
  
  output$pathogenFilterLabel <- renderUI(paste0(current_pool()$label, ":"))
  output$pathogenKnownBtn <- renderUI({
    actionButton("btn_virus_known", current_pool()$known_label,
                 style = "width: 100%; margin-top: 5px;", size = "xs", class = "btn-info btn-xs")
  })
  
  # Switching pools refills the pathogen picker from that pool's alias list
  observeEvent(current_pool(), {
    pool <- current_pool()
    choices <- if (exists(pool$aliases)) sort(names(get(pool$aliases))) else character(0)
    shinyWidgets::updatePickerInput(
      session, "primaryVirusFilter",
      choices = c("All", "Non-descript", choices),
      selected = "All"
    )
  })
  
  # ========================================================================
  # SOURCE CHIPS (filter the results table by database)
  # ========================================================================
  source_filter <- reactiveVal("All")
  
  # --- Empty state: what to show when a search finds nothing ---
  empty_state <- reactiveVal(NULL)
  # One definition, rendered in two places: in the results layout (where a
  # zero-result search now stays) and on the landing page (first visit).
  empty_state_box <- function(es) {
    if (is.null(es)) return(NULL)
    if (isTRUE(es$error)) {
      div(class = "empty-state",
          h5("That search didn't go through"),
          p("The databases couldn't be reached just now. Try again in a moment."))
    } else {
      div(class = "empty-state",
          h5(paste0("No results for \u201c", es$term, "\u201d")),
          p("Try fewer or broader words, check the spelling, or turn on Deep search for a wider net."))
    }
  }

  output$resultsEmptyNotice <- renderUI(empty_state_box(empty_state()))
  
  # Shiny suspends an output while it is not visible, and after a successful
  # search the landing container is hidden -- so a later zero-result search
  # set empty_state() into a suspended output, and shinyjs::show() toggles CSS
  # display without reliably resuming it. The box then never appeared, but
  # only on a second search: from the home page the container had never been
  # hidden, so the output was live and it worked.
  outputOptions(output, "resultsEmptyNotice", suspendWhenHidden = FALSE)

  source_display_name <- function(x) {
    lookup <- c("EPMC" = "Europe PMC", "clinicaltrials.gov" = "Trials",
                "Preprint (biorxiv)" = "bioRxiv", "Preprint (medrxiv)" = "medRxiv",
                "NIH" = "NIH grants", "NSF" = "NSF awards")
    ifelse(x %in% names(lookup), lookup[x], x)
  }
  
  output$sourceChips <- renderUI({
    df <- rv$article_df()
    req(df, nrow(df) > 0, "Source" %in% names(df))
    counts <- sort(table(df$Source), decreasing = TRUE)
    active <- source_filter()
    
    chip <- function(value, label, n) {
      tags$button(
        type = "button",
        class = paste("source-chip", if (identical(active, value)) "is-active"),
        `aria-pressed` = tolower(as.character(identical(active, value))),
        onclick = sprintf("Shiny.setInputValue('source_chip', %s, {priority: 'event'})",
                          jsonlite::toJSON(value, auto_unbox = TRUE)),
        span(label), span(class = "source-chip-count", n)
      )
    }
    div(
      class = "source-chip-row",
      chip("All", "All", nrow(df)),
      lapply(names(counts), function(src) chip(src, source_display_name(src), counts[[src]]))
    )
  })
  
  # One line above the results: how many records each database contributed
  # out of how many it matched, and when. The results are each database's top
  # matches, not every match, and this keeps that visible.
  output$sourceCoverage <- renderUI({
    req(rv$article_df())
    items <- source_coverage_items(rv$source_counts)
    if (length(items) == 0) return(NULL)
    when <- rv$retrieved_at
    when_txt <- if (inherits(when, "POSIXt")) {
      paste0(if (isTRUE(rv$from_cache)) "Cached result, retrieved " else "Retrieved ",
             format(when, "%b %d, %H:%M UTC", tz = "UTC"))
    }
    div(class = "source-coverage",
        span(class = "source-coverage-lead", "Top matches from each database:"),
        paste(items, collapse = " \u00b7 "),
        if (!is.null(when_txt)) span(class = "source-coverage-when", when_txt))
  })

  # Click a chip to filter; click the active chip again to show everything
  observeEvent(input$source_chip, {
    picked <- as.character(input$source_chip)
    source_filter(if (identical(picked, source_filter()) || picked == "All") "All" else picked)
  })
