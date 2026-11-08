# app/server/landscape.R -- the Therapinator tab: what's been tried.
# A table of therapy modality x stage (grant, preprint, paper, trial phase)
# for the current results, and the trials themselves, most advanced first.
# The logic lives in R/display_utils.R (therapy_landscape, trials_tried) so it
# can be tested without the app.

if (!isTRUE(SHOW_THERAPINATOR)) {
  # Hidden while in development (see app.R): remove the tab, run nothing else.
  bslib::nav_hide("main_app_tabs", target = "Therapinator", session = session)
} else {

  landscape_df <- reactive({
    df <- rv$article_df()
    if (is.null(df) || nrow(df) == 0) return(NULL)
    df
  })

  output$landscapeTable <- DT::renderDataTable({
    df <- landscape_df()
    req(df)
    tab <- therapy_landscape(df)
    # shiny:: on purpose: jsonlite, loaded after shiny, has its own validate().
    shiny::validate(shiny::need(nrow(tab) > 0,
                  "No therapies were identified in these results. Try a search that names a treatment, target or disease."))
    DT::datatable(tab, rownames = FALSE, selection = "single", escape = TRUE,
                  options = list(dom = "t", pageLength = 50, ordering = TRUE, scrollX = TRUE))
  })

  # The modality picker lists the therapies present, most common first.
  observe({
    df <- landscape_df()
    tab <- if (is.null(df)) NULL else therapy_landscape(df)
    choices <- c("All therapies" = "All", if (!is.null(tab) && nrow(tab)) setNames(tab$Therapy, tab$Therapy))
    # Keep the current pick if it is still there. Before the first search the
    # input is NULL, and if (NULL %in% x) is an error, so test it explicitly.
    current <- isolate(input$landscape_modality)
    keep <- !is.null(current) && length(current) == 1 && current %in% choices
    updateSelectInput(session, "landscape_modality", choices = choices,
                      selected = if (keep) current else "All")
  })

  # Clicking a row of the summary picks that therapy for the trials list.
  observeEvent(input$landscapeTable_rows_selected, {
    df <- landscape_df()
    req(df)
    tab <- therapy_landscape(df)
    i <- input$landscapeTable_rows_selected
    if (length(i) == 1 && i <= nrow(tab)) updateSelectInput(session, "landscape_modality", selected = tab$Therapy[i])
  })

  trials_shown <- reactive({
    trials_tried(landscape_df(), input$landscape_modality %||% "All")
  })

  output$trialsEmptyNote <- renderUI({
    req(landscape_df())
    if (nrow(trials_shown()) == 0) {
      p(class = "plot-caveat", "No trials in these results for this therapy.")
    }
  })

  output$trialsTriedTable <- DT::renderDataTable({
    t <- trials_shown()
    req(nrow(t) > 0)
    # The only HTML here is the trial link, built from the NCT number (letters
    # and digits only); every other column is escaped.
    t$Trial <- ifelse(nzchar(t$Trial),
                      sprintf('<a href="https://clinicaltrials.gov/study/%s" target="_blank" rel="noopener">%s</a>',
                              t$Trial, t$Trial), "")
    DT::datatable(t, rownames = FALSE, escape = -1,
                  options = list(pageLength = 25, scrollX = TRUE, dom = '<"dt-top-toolbar"f>rtip',
                                 language = list(search = "_INPUT_", searchPlaceholder = "Filter trials...")))
  })

}
