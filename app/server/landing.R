# app/server/landing.R
#
# Landing page: feature-card explainers, the "Use with AI" modal, and font
# size.
#
# Runs inside server() in app.R (sourced with local = TRUE), so it shares
# input, output, session and every variable defined by the parts before it.

  # ========================================================================
  # FEATURE CARD EXPLAINERS (short, with one way to try each)
  # ========================================================================
  card_modal <- function(ic, title, ..., action_id = NULL, action_label = NULL) {
    showModal(modalDialog(
      title = tagList(icon(ic), " ", title),
      size = "m",
      easyClose = TRUE,
      div(style = "color: #ccc; line-height: 1.6;", ...),
      footer = tagList(
        if (!is.null(action_id)) actionButton(action_id, action_label, class = "btn-sm ql-chip"),
        modalButton("Close")
      )
    ))
  }
  
  observeEvent(input$card_dedup, {
    card_modal("filter", "Deduplicatinator",
      p("One search covers Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv/medRxiv, NIH grants and NSF awards, plus CORE and patents if you add your own keys in Settings."),
      p("The same paper often shows up in several databases. These copies are merged so each one appears once, keeping the best-curated version. The Deduplication Summary tab shows what was merged."),
      action_id = "try_dedup", action_label = "Try it: search Oncolytic Virus")
  })
  observeEvent(input$try_dedup, { removeModal(); request_search("Oncolytic Virus") })
  
  observeEvent(input$card_plot, {
    card_modal("chart-area", "Plotinator",
      p("After a search, the Plotinator tab charts your results over time, grouped by the immune cells and viruses they mention, so you can see where a field is heading."),
      p("Click any point to add that paper to your reading list."),
      action_id = "try_plot", action_label = "Try it: search T-VEC")
  })
  observeEvent(input$try_plot, { removeModal(); request_search("T-VEC") })
  
  observeEvent(input$card_read, {
    card_modal("book-open", "Readinator",
      p("Click Add to Reading List on any result, or click a point in the Plotinator. Your picks collect in the Reading List tab."),
      p("Export the list to Zotero, EndNote or CSV. The list lasts for this visit only, so export it before you leave."))
  })
  
  # ========================================================================
  # "USE WITH AI" MODAL (Agentinator card)
  # ========================================================================
  observeEvent(input$agent_info, {
    mcp_url <- "https://mcp.abstractinator.me/mcp"
    showModal(modalDialog(
      title = tagList(icon("robot"), " Use The Abstractinator with AI"),
      size = "m",
      easyClose = TRUE,
      footer = modalButton("Close"),
      
      p("The Abstractinator is available as an ", strong("MCP server"),
        ", the open standard AI assistants use to connect to tools. Once connected, ",
        "your assistant can search the literature for you, read the results, and build on them in conversation."),
      
      h5("Connector URL", style = "margin-top: 20px;"),
      div(style = "display: flex; gap: 8px; align-items: center;",
          tags$code(mcp_url, style = "flex-grow: 1; padding: 8px 10px; background: rgba(0,0,0,0.4); border-radius: 5px; color: var(--accent-primary);"),
          tags$button(class = "btn btn-sm btn-outline-light", icon("copy"), " Copy",
                      onclick = sprintf("navigator.clipboard.writeText('%s'); this.innerHTML = 'Copied!';", mcp_url))
      ),
      
      h5("Add it to Claude", style = "margin-top: 20px;"),
      tags$ol(style = "color: #ccc;",
        tags$li("Open ", strong("Settings → Connectors"), "."),
        tags$li("Choose ", strong("Add custom connector"), " and paste the URL above."),
        tags$li("In a chat, ask something like: ", em("\"Search the Abstractinator for oncolytic virus trials in melanoma.\""))
      ),
      p("Other MCP-compatible assistants work too: add the same URL as a remote (streamable HTTP) MCP server.",
        style = "color: #aaa; font-size: 0.9em;"),
      
      h5("What your assistant gets", style = "margin-top: 20px;"),
      tags$ul(style = "color: #ccc;",
        tags$li(code("search_literature"), " \u2014 Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv/medRxiv, NIH RePORTER and NSF awards, in one call."),
        tags$li(code("get_fulltext"), " \u2014 reads one open-access article in full from Europe PMC, so your assistant can go past the abstract. ",
                "Only the open-access subset can be served; a paywalled paper comes back marked ", em("not open access"), " rather than failing, and the DOI is there to follow by hand."),
        tags$li("Deduplicated records with title, abstract, authors, date, DOI and link. Open-access records also carry a ", code("pmcid"), ", which is what ", code("get_fulltext"), " takes."),
        tags$li("Each record tagged with its most prominent immune cell type, virus and bacterium."),
        tags$li("Results balanced across sources rather than taken from whichever database returned most; repeat searches return instantly from cache.")
      ),
      p(icon("circle-info"), " The AI connector uses open-access sources only, so no API keys are needed or shared. ",
        "Searches and full-text requests are rate-limited separately, so one cannot crowd out the other.",
        style = "color: #888; font-size: 0.85em; margin-top: 15px;")
    ))
  })
  
  # ========================================================================
  # ADJUST FONT (Server-side logic)
  # ========================================================================
  # This listens to the button inside the modal
  observeEvent(input$applyFont, {
    js_code <- sprintf(
      "$('#resultsDisplay table').css('font-size', '%spx'); 
       $('#resultsDisplay table td').css('font-size', '%spx');", 
      input$fontSize, input$fontSize
    )
    shinyjs::runjs(js_code)
    showNotification("Font size updated.", type = "message", duration = 2)
  })
