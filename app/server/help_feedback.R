# app/server/help_feedback.R
#
# Help modal and the feedback form.
#
# Runs inside server() in app.R (sourced with local = TRUE), so it shares
# input, output, session and every variable defined by the parts before it.

  # ========================================================================
  # GLOBAL HELP MODAL (HIGH CONTRAST CSS INJECTION)
  # ========================================================================
  observeEvent(input$footer_help_btn, {
    showModal(modalDialog(
      title = div(icon("info-circle"), " The Abstractinator Guide"),
      
      # --- CSS INJECTION: FORCE HIGH CONTRAST ---
      tags$style(HTML("
        /* 1. Force all modal text to white by default */
        .modal-body, .modal-title { color: #ffffff !important; }
        
        /* 2. Fix Input Labels (e.g. 'Issue Category') */
        .control-label { color: #ecf0f1 !important; font-weight: bold; }
        
        /* 3. Fix Input Boxes (Background & Text) */
        .form-control, .selectize-input {
          background-color: #4b5563 !important; /* Lighter Grey for visibility */
          color: #ffffff !important;            /* White text when typing */
          border: 1px solid #6b7280 !important;
        }
        
        /* 4. Fix Placeholder Text (The faint 'Describe behavior...' text) */
        ::placeholder { color: #d1d5db !important; opacity: 1; }
      ")),
      
      tabsetPanel(
        # --- TAB 1: OVERVIEW ---
        tabPanel("Overview",
                 br(),
                 h4("The Abstractinator", style = "color: #fff; border-bottom: 2px solid var(--accent-primary); padding-bottom: 10px;"),
                 p("An Abstract aggregation pipeline designed for virology and immunology literature review.", style = "font-size: 1.1em; color: #eee;"),
                 
                 br(),
                 tags$ul(style = "list-style-type: none; padding-left: 10px;",
                         
                         # 1. Search
                         tags$li(style = "margin-bottom: 10px;",
                                 icon("search", style = "color: var(--accent-primary); margin-right: 8px;"),
                                 strong("Searchinator:", style = "color: #fff;"), 
                                 span(" Aggregates metadata from ", style = "color: #ccc;"),
                                 strong("Europe PMC, OpenAlex, Embase, bioRxiv/medRxiv, USPTO PatentsView, & ClinicalTrials.gov.")
                         ),
                         
                         # 2. Deduplication
                         tags$li(style = "margin-bottom: 10px;",
                                 icon("filter", style = "color: var(--accent-primary); margin-right: 8px;"),
                                 strong("Deduplicatinator:", style = "color: #fff;"),
                                 span(" Eliminates redundancy between sources using distinct record identification.", style = "color: #ccc;")
                         ),
                         
                         # 3. Plotinator (REVISED)
                         tags$li(style = "margin-bottom: 10px;",
                                 icon("chart-bar", style = "color: var(--accent-primary); margin-right: 8px;"),
                                 strong("Plotinator:", style = "color: #fff;"),
                                 span(" Visualizes the intersection of ", style = "color: #ccc;"),
                                 em("Virology and Immunology.", style = "color: #fff;"),
                                 span(" Categorizes literature by specific cell/virus pairs, with an optional filter for Bioinformatics related subject matter.", style = "color: #ccc;")
                         ),
                         
                         # 4. Readinator
                         tags$li(style = "margin-bottom: 10px;",
                                 icon("book-reader", style = "color: var(--accent-primary); margin-right: 8px;"),
                                 strong("Readinator:", style = "color: #fff;"),
                                 span(" Curate a targeted reading list and export files for reference managers (Zotero/EndNote via RIS) or CSV.", style = "color: #ccc;")
                         )
                 ),
                 
                 br(),
                 h5("Scoring Methodology", style = "color: #ddd; border-bottom: 1px solid #444; padding-bottom: 5px;"),
                 p("Papers are automatically tagged based on controlled vocabularies:", style = "color: #aaa; font-size: 0.9em;"),
                 tags$ul(style = "font-size: 0.9em; color: #ccc;",
                         tags$li(strong("Immune/Viral Scoring:"), " Prioritizes matches in Titles (High Weight) vs. Abstracts (Low Weight)."),
                         tags$li(strong("Bioinformatics:"), " Detects computational keywords (e.g., 'RNA-seq', 'GitHub', 'Algorithm').")
                 ),
                 
                 br(),
                 hr(style = "border-top: 1px solid #666;"), 
                 
                 # --- CITATION SECTION ---
                 h4("Cite This Tool", style = "color: var(--accent-primary); margin-top: 15px;"),
                 p("If you use this tool for your research, please cite it as:", style = "font-style: italic; color: #ccc;"),
                 
                 div(style = "background: #2c3e50; padding: 10px; border-radius: 5px; margin-bottom: 10px; font-family: monospace;",
                     "Kangas, C. (2025). The Abstractinator: Automated Boolean Search Tool for Rapid Acquisition, Classification, and Triage of Immuno-Networks And Therapeutic Oncolytic Research [Computer software]."
                 ),
                 
                 p(strong("BibTeX:"), style = "margin-bottom: 5px;"),
                 tags$textarea(
                   id = "bibtex_citation",
                   class = "form-control",
                   rows = 6,
                   style = "width: 100%; font-family: monospace; color: #fff; background-color: #4b5563;", 
                   readonly = "readonly",
                   "@software{TheAbstractinator2025,\n  author = {Kangas, Chase},\n  title = {The Abstractinator: Automated Boolean Search Tool for Rapid Acquisition, Classification, and Triage of Immuno-Networks And Therapeutic Oncolytic Research},\n  year = {2025},\n  url = {https://theabstractinator.shinyapps.io/Abstractinator/},\n  version = {1.4.0}\n}"
                 ),
                 
        ),
        
        
        
        # --- TAB 2: FEEDBACK ---
        tabPanel("Report a Problem & Feedback",
                 br(),
                 p("Please report pipeline failures or reproducibility issues below."),
                 
                 selectInput("feedback_category", "Issue Category:",
                             choices = c("Report a Bug", "Data Discrepancy", "Feature Request", "Other"),
                             width = "100%"),
                 
                 textAreaInput("feedback_msg", "Description:", 
                               placeholder = "Describe the bug for the Eliminators...",
                               rows = 5, 
                               width = "100%"),
                 
                 div(style = "text-align: right;",
                     actionButton("submit_feedback_btn", "Submit Report", 
                                  icon = icon("paper-plane"), 
                                  class = "btn-primary")
                 ),
                 
                 hr(),
        )
      ),
      
      size = "l", 
      easyClose = TRUE,
      footer = modalButton("Dismiss") 
    ))
  })
  
  # ========================================================================
  # SUBMIT FEEDBACK HANDLER
  # ========================================================================
  # Feedback is always saved locally (.cache/s3_mimic/feedback/), so nothing is
  # lost if Discord is down or no webhook is configured. If DATA_WEBHOOK_URL is
  # set, it's also forwarded to Discord with @mentions disabled.
  last_feedback_time <- NULL
  
  observeEvent(input$submit_feedback_btn, {
    msg_text <- trimws(input$feedback_msg %||% "")
    if (nchar(msg_text) == 0) {
      showNotification("Please write a short description first.", type = "warning")
      return()
    }
    
    # Light spam protection: one report per minute per visitor
    if (!is.null(last_feedback_time) &&
        difftime(Sys.time(), last_feedback_time, units = "secs") < 60) {
      showNotification("Thanks! Please wait a minute before sending another report.", type = "warning")
      return()
    }
    
    msg_text <- substr(msg_text, 1, 2000)
    category <- substr(as.character(input$feedback_category %||% "General"), 1, 100)
    
    # 1. Always keep a local copy
    saved_ok <- tryCatch({
      day_dir <- file.path(".cache", "s3_mimic", "feedback", format(Sys.Date(), "%Y-%m-%d"))
      dir.create(day_dir, recursive = TRUE, showWarnings = FALSE)
      jsonlite::write_json(
        list(time = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), category = category, message = msg_text),
        file.path(day_dir, sprintf("feedback_%s_%s.json", as.numeric(Sys.time()), uuid::UUIDgenerate())),
        auto_unbox = TRUE, pretty = TRUE
      )
      TRUE
    }, error = function(e) {
      message("[Feedback] Local save failed: ", e$message)
      FALSE
    })
    
    # 2. Forward to Discord if configured (never blocks the local copy)
    webhook_url <- Sys.getenv("DATA_WEBHOOK_URL")
    sent_ok <- FALSE
    if (nzchar(webhook_url)) {
      sent_ok <- tryCatch({
        response <- httr::POST(
          url = webhook_url,
          body = list(
            content = paste0("**Abstractinator Report:** ", category),
            allowed_mentions = list(parse = list()),  # visitors can't ping @everyone
            embeds = list(list(
              title = "User Feedback",
              description = msg_text,
              color = 5763719,
              fields = list(list(name = "Time", value = as.character(Sys.time()), inline = TRUE)),
              footer = list(text = "Sent via The Abstractinator")
            ))
          ),
          encode = "json",
          httr::add_headers(`User-Agent` = "R-Abstractinator-Bot"),
          httr::timeout(10)
        )
        httr::status_code(response) >= 200 && httr::status_code(response) < 300
      }, error = function(e) {
        message("[Feedback] Webhook failed: ", e$message)
        FALSE
      })
    }
    
    if (saved_ok || sent_ok) {
      last_feedback_time <<- Sys.time()
      showNotification("Thanks! The Helpinators have recieved your feedback.", type = "message")
      updateTextAreaInput(session, "feedback_msg", value = "")
      removeModal()
    } else {
      showNotification("Sorry, your feedback couldn't be sent right now. Please try again later.", type = "error")
    }
  })
