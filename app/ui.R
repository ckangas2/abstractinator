# app/ui.R
#
# The page layout. app.R reads this file's value as the app's UI. Input and
# output ids here are referenced by www/script.js and by JavaScript in the
# server code, so they are not namespaced.

fluidPage(
  
  useShinyjs(),
  
  title = "The Abstractinator",
  
  theme = bslib::bs_theme(bootswatch = "darkly"),
  
  tags$head(
    
    # --- Icons (tab, bookmarks, phone home screens) ---
    tags$link(rel = "icon", type = "image/x-icon", href = "favicon.ico"),
    tags$link(rel = "icon", type = "image/png", sizes = "32x32", href = "favicon-32.png"),
    tags$link(rel = "apple-touch-icon", sizes = "180x180", href = "apple-touch-icon.png"),
    tags$link(rel = "manifest", href = "site.webmanifest"),
    tags$meta(name = "theme-color", content = "#222222"),
    
    # --- Search engines & link previews (Slack, iMessage, Discord, X, ...) ---
    tags$meta(name = "description", content = "Immunology & virology literature, searched across Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv, NIH and NSF at once. Deduplicated and tagged by immune cell type, virus and bacterium."),
    tags$meta(property = "og:type", content = "website"),
    tags$meta(property = "og:url", content = "https://abstractinator.me/"),
    tags$meta(property = "og:title", content = "The Abstractinator"),
    tags$meta(property = "og:description", content = "Immunology & virology literature, searched across databases at once."),
    tags$meta(property = "og:image", content = "https://abstractinator.me/og-image.png"),
    tags$meta(property = "og:image:width", content = "1200"),
    tags$meta(property = "og:image:height", content = "630"),
    tags$meta(name = "twitter:card", content = "summary_large_image"),
    
    # --- Hints for AI agents that fetch this page ---
    # The Agentinator details live in a modal, which a plain HTTP fetch never
    # renders, so the MCP endpoint is stated statically here and in /llms.txt.
    tags$meta(name = "mcp-server", content = "https://mcp.abstractinator.me/mcp"),
    tags$link(rel = "alternate", type = "text/plain", href = "llms.txt", title = "llms.txt"),
    
    # Cache-busting: the ?v= number changes whenever the file changes, so browsers
    # and Cloudflare always fetch the current version instead of a stale copy
    tags$link(rel = "stylesheet", type = "text/css",
              href = paste0("styles.css?v=", as.integer(file.mtime("www/styles.css")))),
    tags$script(src = paste0("script.js?v=", as.integer(file.mtime("www/script.js"))))
  ),
  
  # ========================================================================
  # BTC DONATION BUTTON
  # ========================================================================
  
  # The donate control lives in the footer now. A pill beside the search
  # box is the first thing a new visitor sees, before the tool has given
  # them anything - which reads against what llms.txt already promises
  # agents: a fact about the project, never a prompt to pay.
  
  # ========================================================================
  # HAMBURGER OPTIONS BUTTON (FLOATING)
  # ========================================================================
  div(
    style = "position: absolute; top: 15px; right: 25px; z-index: 1050;", 
    actionButton(
      inputId = "optsBtn",
      label = NULL,
      icon = icon("bars"), 
      class = "hamburger-btn" # <--- ADD THIS CLASS. Remove the 'style' arg.
    )
  ),
  
  
  
  # ========================================================================
  # LOADING OVERLAY
  # ========================================================================
  div(
    class = "loading-overlay",
    div(class = "loading-icon-container",
        # width/height match the CSS so the box does not jump from 50px to
        # 300px between first paint and stylesheet application.
        img(src = "loading1.png", id = "loadingIcon", alt = "", width = "300px", height = "300px"),
        div(id = "loadingMessage", style = "color: white; margin-top: 20px; text-align: center;",
            # One HTML string rather than two tags$span() children:
            # htmltools separates children with a newline, and a newline
            # between inline elements renders as a space -- which put a gap
            # between the word and its animated ellipsis ("Deeper ..").
            HTML(paste0(
              '<span id="loadingText"></span>',
              '<span id="loadingDots" class="loading-dots"></span>')))
    )
  ),
  
  # ========================================================================
  # FULL-WIDTH SEARCH AREA
  # ========================================================================
  div(
    class = "full-width-search-area",
    
    # --- Enter Key Listener ---
    tags$script(HTML("
    $(document).on('keyup', '#searchTerm', function(e) {
      if(e.which == 13) {
        document.getElementById('searchButton').click();
      }
    });
  ")),
    # ---------------------------------
    
    h2("The Abstractinator"),
    
    # 1. Search Bar Row (Container becomes the anchor)
    div(
      class = "search-container-with-icons",
      # We use relative positioning here so the children can position absolutely inside it.
      style = "position: relative; display: flex; justify-content: center; align-items: center; min-height: 50px;",
      
      # Left Icon (Floating absolutely on the left)
      div(class = "completion-icon-left", 
          style = "position: absolute; left: 10px; top: 50%; transform: translateY(-50%); z-index: 10;",
          tags$img(id = "completionIconLeft", alt = "", 
                   src = "search_complete.png", 
                   height = "150px", # Adjusted size for floating look
                   width = "auto", 
                   style = "display: none;")
      ),
      
      # Search Group (Centered, with margins to avoid the floating icons)
      div(
        class = "search-group",
        # Added "0 60px" margin to keep distance from the absolute icons
        style = "width: 80%; max-width: 700px; margin: 0 60px; display: flex; align-items: stretch;",
        
        textInput("searchTerm", label = NULL, placeholder = "Enter search term:", width = "100%"),
        actionButton("searchButton", "Search")
      ),
      
      # Right Icon (Floating absolutely on the right)
      div(class = "completion-icon-right", 
          style = "position: absolute; right: 10px; top: 50%; transform: translateY(-50%); z-index: 10;",
          tags$img(id = "completionIconRight", alt = "", 
                   src = "search_complete.png", 
                   height = "150px", 
                   width = "auto", 
                   style = "display: none;")
      )
      
    ), # Closes search-container-with-icons
    
    # --- Options row: deep search toggle + quick launch chips (one compact line) ---
    div(
      class = "search-options-row",
      # Deep search: a real checkbox (keyboard + screen reader friendly), styled as a pill switch
      div(
        class = "deep-toggle",
        title = "Up to 250 results per source instead of 50 (slower)",
        checkboxInput("deepSearch",
                      label = span(class = "deep-toggle-pill", span(class = "deep-knob"), "Deep search"),
                      value = FALSE)
      ),
      span(class = "search-options-divider"),
      span("Try:", class = "ql-label"),
      actionButton("btn_oncolytic_virus", "Oncolytic Virus", class = "btn-sm ql-chip"),
      actionButton("btn_tvec", "T-VEC", class = "btn-sm ql-chip"),
      actionButton("btn_melanoma", "Melanoma", class = "btn-sm ql-chip"),
      actionButton("btn_scseq", "scRNA-seq", class = "btn-sm ql-chip")
    ),
    
    # Shown only when a search comes back empty (or fails)
    
    div(
      class = "search-feedback hidden",
      span(textOutput("searchResults")),
      div(class = "completion-icon-left"),
      div(class = "completion-icon-right")
    )
  ),
  
  # ========================================================================
  # 2. LANDING PAGE / MISSION CONTROL
  # ========================================================================
  div(
    id = "landing_container",
    style = "text-align: center; margin-top: 20px; opacity: 0.9;", 
    
    # --- NEW: STATUS BRIEFING (Warnings & Info) ---
    div(
      style = "display: inline-block; text-align: left; background: rgba(0,0,0,0.3); border: 1px solid #444; border-radius: 10px; padding: 15px 25px; margin-bottom: 30px; max-width: 600px;",
      
      # 1. Search timing
      div(
        style = "margin-bottom: 10px; color: #ffab40; font-size: 0.95em;",
        icon("clock"), strong(" SEARCH TIME:"), 
        span(" New searches take ", style="color: #ccc;"),
        strong("~5-10 seconds", style="color: #fff;"),
        span("; repeat searches are instant.", style="color: #ccc;")
      ),
      
      # 2. The API Key Note
      div(
        style = "color: var(--accent-primary); font-size: 0.95em;",
        icon("key"), strong(" Additional Setup Option:"), 
        span(" For CORE & USPTO access, enter your keys in ", style="color: #ccc;"),
        actionLink("link_to_settings", "Settings", style = "color: var(--accent-primary); text-decoration: underline; cursor: pointer;") 
      )
    ),
    
    
    
    # 2. Feature Cards (each one opens a short explainer with a way to try it)
    local({
      feature_card <- function(id, ic, title, blurb) {
        column(3,
          actionLink(id, class = "landing-card-link",
            div(class = "landing-card",
                icon(ic, "fa-3x", style = "color: var(--accent-primary); margin-bottom: 15px;"),
                h4(title),
                p(blurb, style = "color: #aaa;")
            )
          )
        )
      }
      fluidRow(
        feature_card("card_dedup", "filter", "Deduplicatinator",
                     "Searches Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv, NIH, NSF & more at once."),
        feature_card("card_plot", "chart-area", "Plotinator",
                     "Visualize viral-immune trends over time with interactive analytics."),
        feature_card("card_read", "book-open", "Readinator",
                     "Build and export a targeted reading list to Zotero or EndNote."),
        feature_card("agent_info", "robot", "Agentinator",
                     "Let your AI assistant search The Abstractinator and read open-access full text via MCP. Connector URL: https://mcp.abstractinator.me/mcp")
      )
    }),
    
    # --- Share links (plain links: no tracking scripts or third-party widgets) ---
    local({
      site  <- "https://abstractinator.me"
      blurb <- "The Abstractinator: search immunology & virology literature across Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv, NIH and NSF at once"
      enc   <- function(x) utils::URLencode(x, reserved = TRUE)
      share_btn <- function(label, ic, href) {
        tags$a(href = href, target = "_blank", rel = "noopener",
               class = "btn btn-sm btn-outline-secondary",
               style = "margin: 3px; border-radius: 20px; font-size: 0.8em;",
               icon(ic), paste0(" ", label))
      }
      div(
        style = "margin-top: 30px; color: #aaa; font-size: 0.85em;",
        span("Share The Abstractinator: ", style = "margin-right: 6px;"),
        share_btn("LinkedIn", "linkedin", paste0("https://www.linkedin.com/sharing/share-offsite/?url=", enc(site))),
        share_btn("X", "x-twitter", paste0("https://x.com/intent/post?text=", enc(blurb), "&url=", enc(site))),
        share_btn("Bluesky", "bluesky", paste0("https://bsky.app/intent/compose?text=", enc(paste(blurb, site)))),
        share_btn("Reddit", "reddit", paste0("https://www.reddit.com/submit?url=", enc(site), "&title=", enc(blurb))),
        share_btn("Email", "envelope", paste0("mailto:?subject=", enc("The Abstractinator"), "&body=", enc(paste0(blurb, "\n\n", site)))),
        tags$button(class = "btn btn-sm btn-outline-secondary",
                    style = "margin: 3px; border-radius: 20px; font-size: 0.8em;",
                    onclick = sprintf("navigator.clipboard.writeText('%s'); this.innerHTML = 'Link copied!';", site),
                    icon("link"), " Copy link")
      )
    }),
    
    # --- Icon credits (required by the Flaticon free license) ---
    div(
      style = "margin-top: 30px; font-size: 0.75em; color: #777;",
      "Icons: ",
      tags$a("narwhal", href = "https://www.flaticon.com/free-icon/narwhal_2569882", target = "_blank", style = "color: #999;"),
      " by Smashicons, ",
      tags$a("dinosaur", href = "https://www.flaticon.com/free-icon/dinosaur_4574325", target = "_blank", style = "color: #999;"),
      " by imaginationlol, ",
      tags$a("frog prince", href = "https://www.flaticon.com/free-icon/frog-prince_1587055", target = "_blank", style = "color: #999;"),
      " by Magnific, from ",
      tags$a("Flaticon", href = "https://www.flaticon.com", target = "_blank", style = "color: #999;"),
      ". Line-art loading animations from the Noun Project (creators credited in each image)."
    )
  ),
  
  # ========================================================================
  # MAIN CONTENT AREA
  # ========================================================================
  div(
    id = "results_container",
    style = "display: none;", 
    
    # NOTE: The font size controls 'div' has been removed from here.
    
    bslib::navset_pill(
      id = "main_app_tabs", 
      selected = "Search Results", 
      
      # Tab 1: Search Results
      bslib::nav_panel(
        title = "Search Results",
        # A search that finds nothing keeps the results layout and puts this
        # in place of the table, rather than throwing the user back to the
        # landing page and losing their context.
        uiOutput("resultsEmptyNotice"),
        uiOutput("sourceChips"),
        DT::dataTableOutput("resultsDisplay")
      ),
      
      # Tab 2: Deduplication Summary
      bslib::nav_panel(
        title = "Deduplicatinator",
        uiOutput("deduplicationSummaryContent") 
      ),
      
      # Tab 3: Plotinator
      bslib::nav_panel(
        title = "Plotinator",
        
        # Keep this DIV. It provides the breathing room (margin-bottom).
        div(id = "plotFilters", style = "margin-bottom: 10px;",
            
            div(style = "display: flex; align-items: center; gap: 16px; flex-wrap: wrap;",
                h4("Oncolytic-viroimmunoinformatic Plotinator", style = "margin: 0;"),
                # Swaps which category pool forms the plot's pathogen axis.
                # Pools come from aliases.R, so adding one adds a mode here.
                div(class = "pool-switch",
                    shinyWidgets::radioGroupButtons(
                      inputId = "pathogen_pool",
                      label = NULL,
                      choiceNames = lapply(names(PATHOGEN_POOLS), function(nm)
                        tagList(icon(PATHOGEN_POOLS[[nm]]$icon), paste0(" ", nm))),
                      choiceValues = names(PATHOGEN_POOLS),
                      selected = names(PATHOGEN_POOLS)[1],
                      size = "sm", status = "primary", justified = FALSE
                    )
                )
            ),
            
            fluidRow( 
              column(width = 2, dateRangeInput("dateRange", "Date:", start = Sys.Date() - 365, end = Sys.Date())),
              
              # ... inside the fluidRow in UI ...
              
              # --- CELL TYPE COLUMN ---
              column(width = 3,
                     shinyWidgets::pickerInput(
                       inputId = "primaryCellFilter",
                       label = "Cell Type:",
                       choices = c("All"),
                       selected = "All",
                       multiple = TRUE,
                       options = list(
                         `actions-box` = TRUE,             # Adds built-in Select All / Deselect All
                         `selected-text-format` = "count > 2", # <--- THE FIX: Collapses text if >2 selected
                         `count-selected-text` = "{0} Cells Selected",
                         `live-search` = TRUE
                       )
                     ),
                     # Your Custom "Known Only" Button
                     div(style = "margin-top: -5px;", 
                         actionButton("btn_cell_known", "🛡️ Immune Cells Only", 
                                      style = "width: 100%; margin-top: 5px;", # Full width, compact
                                      size = "xs", class = "btn-info btn-xs")
                     )
              ),
              
              # --- VIRUS COLUMN ---
              column(width = 3,
                     shinyWidgets::pickerInput(
                       inputId = "primaryVirusFilter",
                       label = uiOutput("pathogenFilterLabel", inline = TRUE),
                       choices = c("All"),
                       selected = "All",
                       multiple = TRUE,
                       options = list(
                         `actions-box` = TRUE,
                         `selected-text-format` = "count > 2", # <--- THE FIX
                         `count-selected-text` = "{0} Viruses Selected",
                         `live-search` = TRUE
                       )
                     ),
                     # Your Custom "Known Only" Button
                     div(style = "margin-top: -5px;", 
                         uiOutput("pathogenKnownBtn")
                     )
              ),
              
              column(width = 1, selectInput("showBioinformatics", "Subfield:", choices = c("All", "Bioinformatics"), selected = "All")),
              column(width = 1, numericInput("n_articles_to_plot", "N:", value = 50, min = 1, step = 1))
            )
        ),
        
        plotlyOutput("allArticlesPlotOutput", height = "700px")
      ),
      
      # Tab 4: Reading List
      bslib::nav_panel(
        title = "Reading Listinator",
        
          uiOutput("downloadReadingListUI"),
        
        DT::dataTableOutput("readingListDisplay") 
      )
    ) 
  ),
  
  # ========================================================================
  # STICKY FOOTER
  # ========================================================================
  div(class = "thin-footer",
      span("The Abstractinator v2.0", style = "opacity: 0.5; margin-right: 5px;"),
      "|",
      # Using actionLink so it can trigger a Shiny Modal
      actionLink("footer_help_btn", " Help & Documentation", icon = icon("question-circle")),
      "|",
      # Not #btc_donate: stylesheet rules left over from the old floating
      # button still target that id and take it out of flow, which is what
      # broke the footer layout.
      actionLink("footer_donate_btn", "Donate"),
      "|",
      # A plain link rather than an actionLink: it navigates to a static page
      # and needs no server round trip. .thin-footer a styles it like the
      # others. New tab, so following it does not discard a search.
      tags$a(href = "privacy.html", target = "_blank", rel = "noopener", "Privacy")
  ),
  tags$div(style = "height: 25px; display: block; clear: both;") 

  
)
