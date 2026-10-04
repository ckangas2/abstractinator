# app.R

Sys.setenv(INTEGRATE_NIH_NSF = "1")

# Load necessary libraries
library(shiny)
library(shinythemes)
library(tidyverse)
library(htmltools)
library(DT)
library(stringr)
library(htmlwidgets)
library(htmlTable)
library(bslib)
library(jsonlite)
library(shinyjs)
library(plotly)
library(shinyWidgets)
#library(aws.s3)
#library(qs)
library(digest)
library(future)
library(parallelly)
library(future)

plan(multisession, workers = 8)

# --- SOURCE EXTRACTORS ---
source("epmc_standalone_extraction.R")
source("CORE_extraction.R")
source("clinicaltrials.gov_extraction.R")
source("scopus_extraction.R")
source("biorxiv_extraction.R")
source("patentsview_extraction.R") 
source("deduplication.R")
source("scopus_abstract_extraction.R")
source("R/db_utils_local.R")
source("R/log_utils_local.R")
source("openalex_standalone_extraction.R")
source("aliases.R")           
source("orchestrate_extraction.R") 
source("generate_plot.R")      
source("R/log_utils_local.R")
source("NIHReporter_extraction.R")
source("NSFAwards_extraction.R")



# ==========================================================================
# DEFINE DT OPTIONS
# ==========================================================================
dt_options <- list(
  pageLength = 25,
  lengthMenu = c(10, 25, 50, 100),
  scrollX = TRUE,
  scrollY = FALSE,
  autoWidth = TRUE,
  
  # 1. Custom DOM Structure
  # <"dt-top-toolbar"lf> = Puts Length (l) and Filter (f) in a custom div class "dt-top-toolbar"
  # r = Processing
  # t = Table
  # i = Info
  # p = Pagination
  dom = '<"dt-top-toolbar"lf>rtip', 
  
  # 2. Custom Labels (Language)
  language = list(
    search = "_INPUT_",            # Removes the "Search:" label (we'll use placeholder)
    searchPlaceholder = "Filter results...", # Adds placeholder text inside the box
    lengthMenu = "Show _MENU_"     # Shortens "Show 10 entries" to just "Show 10"
  ), 
  columnDefs = list(
    list(
      targets = 0, 
      render = JS(
        "function(data, type, row, meta) {
          if (type === 'display') {
            var cleanTitle = data.replace(/<\\/?i>/gi, '');
            var url = row[5]; 
            var doi = row[6]; 
            var source = row[10]; // Source is at index 10
            
            // --- 1. BADGE LOGIC ---
            var badge = '';
            
            // A. Check for Preprint (Orange)
            if (source && (source.toLowerCase().includes('biorxiv') || source.toLowerCase().includes('medrxiv') || source.toLowerCase().includes('preprint'))) {
               badge = ' <span style=\"color: #ffab40; font-weight: bold; font-size: 0.75em; border: 1px solid #ffab40; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle;\">PREPRINT</span>';
            }
            // B. Check for Patent (Red)
            else if (source && (source.toLowerCase().includes('patent') || source.toLowerCase().includes('uspto'))) {
               badge = ' <span style=\"color: #ff5252; font-weight: bold; font-size: 0.75em; border: 1px solid #ff5252; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle;\">PATENT</span>';
            }
            // C. Check for NIH Grant (Blue)
            else if (source && source.toLowerCase().includes('nih')) {
               badge = ' <span style=\"color: #4da6ff; font-weight: bold; font-size: 0.75em; border: 1px solid #4da6ff; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle;\">NIH GRANT</span>';
            }
            // D. Check for NSF Grant (Green)
            else if (source && source.toLowerCase().includes('nsf')) {
               badge = ' <span style=\"color: #4caf50; font-weight: bold; font-size: 0.75em; border: 1px solid #4caf50; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle;\">NSF GRANT</span>';
            }
            
            // --- 2. CREATE TITLE LINK ---
            var titleHtml = '';
            if (url) {
              titleHtml = '<div class=\"title-container\"><a href=\"' + url + '\" target=\"_blank\">' + cleanTitle + '</a>' + badge + '</div>';
            } else {
              titleHtml = '<div class=\"title-container\">' + cleanTitle + badge + '</div>';
            }
            
            // --- 3. CREATE BUTTON ---
            var btnHtml = '<button class=\"btn btn-xs btn-outline-light add-to-reading-list-inline\" ' +
                          'style=\"margin-top: 5px; font-size: 0.8em; padding: 2px 6px;\" ' +
                          'data-index=\"' + meta.row + '\" ' +
                          'data-doi=\"' + doi + '\">' +
                          'Add to Reading List</button>';
            
            return titleHtml + btnHtml;
          }
          return data;
        }"
      )
    ),
    list(targets = 1, width = "63%", visible = TRUE),
    list(
      targets = 2,     
      render = JS(
        "function(data, type, row, meta) {
      if (type === 'display' && data) {
        var authors = data.split('; ');
        var affiliationsData = row[3]; 
        var parsed = {};
        try { parsed = JSON.parse(affiliationsData); } catch(e) { }
        return authors.map(function(author, index) {
          var affText = 'No affiliation available';
          var key = (index + 1).toString();
          if (parsed && typeof parsed === 'object') {
            if (parsed[key] && parsed[key].affiliations) {
              affText = parsed[key].affiliations;
            } else if (Array.isArray(parsed) && parsed[index]) {
              affText = parsed[index].affiliations || 'No affiliation available';
            }
          }
          var divId = 'aff-' + meta.row + '-' + index;
          return '<span class=\"author-expand-trigger\" data-affiliation-id=\"' + divId + '\">' + author + '</span>' +
                 '<div id=\"' + divId + '\" class=\"affiliation-details hidden\">' + affText + '</div>';
        }).join('; ');
      }
      return data;
    }"
      )
    ),
    list(targets = 3, visible = FALSE, sName = "AuthorAffiliations"),
    # --- COL 4: DATE (THE LINK) ---
    list(
      targets = 4, 
      width = "100px",
      orderData = 19 # <--- THIS LINKS COL 4 CLICK TO COL 19 DATA
    ),
    list(targets = 5, visible = FALSE),
    list(targets = 6, visible = FALSE), 
    list(targets = 7, visible = FALSE), 
    list(targets = 8, visible = FALSE), 
    list(targets = 9, visible = FALSE), 
    list(targets = 10, visible = FALSE), 
    list(targets = 11, visible = FALSE), 
    list(targets = 12, visible = FALSE), 
    list(targets = 13, visible = FALSE), 
    list(targets = 14, visible = FALSE), 
    list(targets = 15, visible = FALSE), 
    list(targets = 16, visible = FALSE), 
    list(targets = 17, visible = FALSE), 
    list(targets = 18, visible = FALSE),
    list(targets = 19, visible = FALSE)
  ),
  callback = JS(
    "if (!window.readingList) {",
    "  window.readingList = [];",
    "}",
    "",
    "$(document).on('click', '.author-expand-trigger', function() {",
    "  var affiliationId = $(this).data('affiliation-id');",
    "  $('#' + affiliationId).toggleClass('hidden');",
    "});",
    "",
    "$(document).on('click', '.add-to-reading-list-inline', function() {",
    "  var index = $(this).data('index');",
    "  var doi = $(this).data('doi');",
    "  var button = $(this);",
    "  var title = $(this).closest('.title-container').find('a').text() || $(this).closest('.title-container').text();",
    "",
    "  var itemIndex = -1;",
    "  for (var i = 0; i < window.readingList.length; i++) {",
    "    if (window.readingList[i].DOI === doi) {",
    "      itemIndex = i;",
    "      break;",
    "    }",
    "  }",
    "",
    "  if (itemIndex === -1) {",
    "    window.readingList.push({ DOI: doi, Title: title });",
    "    button.text('Remove from Reading List');",
    "    button.addClass('added-to-reading-list');",
    "    Shiny.setInputValue('add_to_reading_list', index, { priority: 'event' });", 
    "  } else {",
    "    window.readingList.splice(itemIndex, 1);",
    "    button.text('Add to Reading List');",
    "    button.removeClass('added-to-reading-list');",
    "    Shiny.setInputValue('remove_from_reading_list', doi, { priority: 'event' });", 
    "  }",
    "});"
  )
)

# ==========================================================================
# UI
# ==========================================================================

ui <- fluidPage(
  
  useShinyjs(),
  
  title = "The Abstractinator",
  
  theme = bslib::bs_theme(bootswatch = "darkly"),
  
  tags$head(
    tags$title("The Abstractinator"),
    
    # --- Icons (tab, bookmarks, phone home screens) ---
    tags$link(rel = "icon", type = "image/x-icon", href = "favicon.ico"),
    tags$link(rel = "icon", type = "image/png", sizes = "32x32", href = "favicon-32.png"),
    tags$link(rel = "apple-touch-icon", sizes = "180x180", href = "apple-touch-icon.png"),
    tags$link(rel = "manifest", href = "site.webmanifest"),
    tags$meta(name = "theme-color", content = "#222222"),
    
    # --- Search engines & link previews (Slack, iMessage, Discord, X, ...) ---
    tags$meta(name = "description", content = "Immunology & virology literature, searched across Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv, NIH and NSF at once. Deduplicated and tagged by immune cell type and virus."),
    tags$meta(property = "og:type", content = "website"),
    tags$meta(property = "og:url", content = "https://abstractinator.me/"),
    tags$meta(property = "og:title", content = "The Abstractinator"),
    tags$meta(property = "og:description", content = "Immunology & virology literature, searched across databases at once."),
    tags$meta(property = "og:image", content = "https://abstractinator.me/og-image.png"),
    tags$meta(property = "og:image:width", content = "1200"),
    tags$meta(property = "og:image:height", content = "630"),
    tags$meta(name = "twitter:card", content = "summary_large_image"),
    
    tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
    tags$script(src = "script.js")
  ),
  
  # ========================================================================
  # BTC DONATION BUTTON
  # ========================================================================
  
  actionButton(
    inputId = "btc_donate",
    label = "Donate",
    icon = icon("bitcoin"), # Requires FontAwesome (standard in Shiny)
    class = "btn-btc-pill", # <--- This links to the CSS above
  ),
  
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
        img(src = "loading1.png", id = "loadingIcon", width = "50px", height = "50px"),
        div(id = "loadingMessage", style = "color: white; margin-top: 20px; text-align: center;")
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
          tags$img(id = "completionIconLeft", 
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
          tags$img(id = "completionIconRight", 
                   src = "search_complete.png", 
                   height = "150px", 
                   width = "auto", 
                   style = "display: none;")
      )
      
    ), # Closes search-container-with-icons
    
    # Deep search toggle (standard = 50 results per source)
    div(
      style = "margin-top: 8px; color: #aaa; font-size: 0.9em;",
      checkboxInput("deepSearch",
                    label = span(icon("layer-group"), " Deep search: up to 250 results per source (slower)"),
                    value = FALSE)
    ),
    
    # --- MOVED HERE: QUICK LAUNCH (Inside the Glass) ---
    div(
      style = "margin-top: 25px;", # Add spacing from the search bar
      span("Quick Launch: ", style = "color: #aaa; font-size: 0.9em; margin-right: 10px; font-weight: 300;"),
      actionButton("btn_oncolytic_virus", "Oncolytic Virus", class = "btn-outline-secondary btn-sm", style = "margin: 2px; border-radius: 20px; border-color: #555; color: #ccc;"),
      actionButton("btn_tvec", "T-VEC", class = "btn-outline-secondary btn-sm", style = "margin: 2px; border-radius: 20px; border-color: #555; color: #ccc;"),
      actionButton("btn_melanoma", "Melanoma", class = "btn-outline-secondary btn-sm", style = "margin: 2px; border-radius: 20px; border-color: #555; color: #ccc;"),
      actionButton("btn_scseq", "scRNA-seq", class = "btn-outline-secondary btn-sm", style = "margin: 2px; border-radius: 20px; border-color: #555; color: #ccc;")
    ),
    
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
    
    
    
    # 2. Feature Cards
    fluidRow(
      column(3, 
             div(class = "landing-card",
                 icon("filter", "fa-3x", style = "color: var(--accent-primary); margin-bottom: 15px;"),
                 h4("Deduplicatinator"),
                 p("Aggregation of Abstracts from Europe PMC, OpenAlex, ClinicalTrials.gov, NIH, NSF & more.", style = "color: #aaa;")
             )
      ),
      column(3, 
             div(class = "landing-card",
                 icon("chart-area", "fa-3x", style = "color: var(--accent-primary); margin-bottom: 15px;"),
                 h4("Plotinator"),
                 p("Visualize viral-immune trends over time with interactive analytics.", style = "color: #aaa;")
             )
      ),
      column(3, 
             div(class = "landing-card",
                 icon("book-open", "fa-3x", style = "color: var(--accent-primary); margin-bottom: 15px;"),
                 h4("Readinator"),
                 p("Build and export a targeted reading list to Zotero or EndNote.", style = "color: #aaa;")
             )
      ),
      column(3, 
             # Clickable card: opens the "Use with AI" modal (observer: input$agent_info)
             actionLink("agent_info", style = "text-decoration: none; color: inherit;",
               div(class = "landing-card", style = "cursor: pointer;",
                   icon("robot", "fa-3x", style = "color: var(--accent-primary); margin-bottom: 15px;"),
                   h4("Agentinator"),
                   p("Let your AI assistant search The Abstractinator directly via MCP. Click to connect.", style = "color: #aaa;")
               )
             )
      )
    ),
    
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
        DT::dataTableOutput("resultsDisplay")
      ),
      
      # Tab 2: Deduplication Summary
      bslib::nav_panel(
        title = "Deduplication Summary",
        uiOutput("deduplicationSummaryContent") 
      ),
      
      # Tab 3: Plotinator
      bslib::nav_panel(
        title = "Plotinator",
        
        # Keep this DIV. It provides the breathing room (margin-bottom).
        div(id = "plotFilters", style = "margin-bottom: 10px;",
            
            h4("Oncolytic-viroimmunoinformatic Plotinator"),
            
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
                       label = "Virus:",
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
                         actionButton("btn_virus_known", "🦠 Viruses Only", 
                                      style = "width: 100%; margin-top: 5px;", 
                                      size = "xs", class = "btn-info btn-xs")
                     )
              ),
              
              column(width = 2, selectInput("showBioinformatics", "Subfield:", choices = c("All", "Bioinformatics"), selected = "All")),
              column(width = 2, numericInput("n_articles_to_plot", "Number of Articles:", value = 50, min = 1, step = 1))
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
      span("(Demo) The Abstractinator v1.4", style = "opacity: 0.5; margin-right: 5px;"),
      "|",
      # Using actionLink so it can trigger a Shiny Modal
      actionLink("footer_help_btn", " Help & Documentation", icon = icon("question-circle"))
  ),
  tags$div(style = "height: 25px; display: block; clear: both;") 

  
)

# ==========================================================================
# SERVER LOGIC
# ==========================================================================

server <- function(input, output, session) {
  
  # --- 1. NEW: The Central "Brain" for Search Terms ---
  # This bypasses the UI delay that was causing the crash
  active_search_term <- reactiveVal("")
  
  # Every search goes through request_search(). The nonce makes repeat searches
  # of the same term (e.g. standard, then deep) still trigger.
  search_request <- reactiveVal(NULL)
  request_search <- function(term) {
    deep <- isTRUE(input$deepSearch)
    active_search_term(term)
    search_request(list(
      term  = term,
      deep  = deep,
      limit = if (deep) DEEP_SEARCH_LIMIT else 50L,
      nonce = runif(1)
    ))
  }
  
  # --- [INSERT HERE: HELPER FUNCTION] ---
  # Keys typed by THIS visitor live only in this session object.
  # Never use Sys.setenv() for user keys: all visitors share one R process,
  # so environment variables would leak one visitor's key to everyone.
  session_keys <- reactiveValues(elsevier = "", core = "", uspto = "")

  resolve_api_key <- function(user_key, env_name) {
    # 1. This visitor's own key (Priority)
    if (!is.null(user_key) && nchar(trimws(user_key)) > 0) {
      return(trimws(user_key))
    }
    # 2. Fallback to server master key (.Renviron). Used silently, never shown in the UI.
    return(Sys.getenv(env_name))
  }
  
  rv <- reactiveValues(
    initial_extracted_data = NULL, 
    original_article_df = NULL,    
    article_df = reactiveVal(NULL), 
    deduplication_table = NULL,    
    plot_data = NULL,              
    reading_list = reactiveVal(list()) 
  )
  
  
  
  # ... [Pre-processing logic for aliases remains unchanged] ...
  virus_alias_expanded_processed <- lapply(virus_alias_expanded, function(aliases) {
    lapply(aliases, function(alias) {
      if (!is.na(alias) && nchar(trimws(alias)) > 0) strsplit(tolower(trimws(alias)), "\\s+")[[1]] else character(0)
    })
  })
  
  immune_cell_alias_list_processed <- lapply(immune_cell_alias_list, function(aliases) {
    lapply(aliases, function(alias) {
      if (!is.na(alias) && nchar(trimws(alias)) > 0) strsplit(tolower(trimws(alias)), "\\s+")[[1]] else character(0)
    })
  })
  
  contains_exact_phrase_preprocessed <- function(text_words, phrase_words) {
    n_phrase <- length(phrase_words)
    n_text <- length(text_words)
    if (n_phrase == 0) return(TRUE)
    if (n_text == 0) return(FALSE)
    for (i in 1:(n_text - n_phrase + 1)) {
      if (all(text_words[i:(i + n_phrase - 1)] == phrase_words)) return(TRUE)
    }
    return(FALSE)
  }
  
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
        tags$li("A ", code("search_literature"), " tool covering Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv/medRxiv, NIH RePORTER and NSF awards."),
        tags$li("Deduplicated records with title, abstract, authors, date, DOI and link."),
        tags$li("Each record tagged with its most prominent immune cell type and virus."),
        tags$li("Results balanced across sources; repeat searches return instantly.")
      ),
      p(icon("circle-info"), " The AI connector uses open-access sources only, so no API keys are needed or shared. ",
        "Searches are rate-limited to keep the service available for everyone.",
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
    
    session$sendCustomMessage(type = 'update_loading_message',
      message = if (search_ctx$deep) "Deep search: querying databases, this can take a minute" else "Querying databases")
    
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
      showNotification(paste("Search failed:", msg), type = "error", duration = 8)
      list(deduplicated_data = NULL, original_combined_data = NULL)
    }
    
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
      updateSelectInput(session, "primaryVirusFilter",
                        choices = c("All", unique(rv$article_df()$primary_virus)))
      
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
      log_search_to_s3(
        search_term = search_term,
        duration_sec = search_duration,
        result_count = log_count,
        source_type = log_source,
        elsevier_key = active_elsevier,
        uspto_key = active_uspto,
        core_key = active_core # <--- Add this!
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
            
            # Ensure Boolean Flags exist
            is_bioinformatics = if ("is_bioinformatics" %in% names(.)) as.logical(is_bioinformatics) else FALSE,
            
            # Ensure Hit Counters exist
            immune_cell_hits_combined = if ("immune_cell_hits_combined" %in% names(.)) immune_cell_hits_combined else list(),
            virus_hits_combined = if ("virus_hits_combined" %in% names(.)) virus_hits_combined else list()
          ) %>%
          
          # --- FIX: WRAP THIS IN MUTATE() ---
          mutate( 
            SortDate = case_when(
              # If it's a Clinical Trial string ("Start: YYYY..."), extract the date
              grepl("Start:", PublicationDate) ~ as.Date(str_extract(PublicationDate, "(?<=Start: )[^\\|]+")),
              # Otherwise, try to read it as a standard date
              TRUE ~ as.Date(PublicationDate)
            )
          ) %>% # <--- CLOSE MUTATE AND PIPE
          
          # --- UPDATE SELECT ---
          select(Title, Abstract, Authors, AuthorAffiliations, PublicationDate, URL, DOI, 
                 EPMC_ID, CORE_ID, NCTId, Source, Affiliations, AdverseEvents, 
                 SeriousAdverseEvents, is_bioinformatics, primary_cell, 
                 primary_virus, immune_cell_hits_combined, virus_hits_combined, 
                 SortDate) 
      )
      
      output$resultsDisplay <- DT::renderDataTable({
        rv$article_df()
      },
      options = dt_options, 
      fillContainer = FALSE,
      colnames = c("Title", "Abstract", "Authors", "AuthorAffiliations", "Publication Date", 
                   "URL", "DOI", "EPMC_ID", "CORE_ID", "NCTId", "Source", "Affiliations", 
                   "AdverseEvents", "SeriousAdverseEvents", "Bioinformatics", 
                   "Primary Immune Cell", "Primary Virus", "Immune Cell Hits", "Virus Hits", "SortDate"),
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
        "  var doi = $(this).data('doi');",
        "  var button = $(this);",
        "  var title = $(this).closest('.title-container').find('a').text() || $(this).closest('.title-container').text();",
        
        # Check if already in list
        "  var itemIndex = -1;",
        "  for (var i = 0; i < window.readingList.length; i++) {",
        "    if (window.readingList[i].DOI === doi) { itemIndex = i; break; }",
        "  }",
        
        "  if (itemIndex === -1) {",
        "    // Add it",
        "    window.readingList.push({ DOI: doi, Title: title });",
        "    button.text('Remove from Reading List');",
        "    button.removeClass('btn-outline-light').addClass('btn-success');", # Visual feedback
        "    Shiny.setInputValue('add_to_reading_list', index, { priority: 'event' });",
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
        rv$deduplication_table
      },
      options = list(searching = FALSE, paging = FALSE, info = FALSE),
      colnames = c("Source", "Total Search Records", "Unique Records", HTML("Duplicate Records Removed")),
      escape = FALSE,
      selection = "none"
      )
      
      output$deduplicationSummaryContent <- renderUI({
        tagList(
          h4("Deduplicatinator"),
          DT::dataTableOutput("deduplicationTable"),
          uiOutput("searchTime")
        )
      })
      
      session$sendCustomMessage(type = 'hide_loading', message = list())
      
    } else {
      output$searchResults <- renderText("No results found or an error occurred during the search.")
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
      !identical(as.character(x$DOI), as.character(target_doi))
    }, current_list)
    
    # 4. Update the reactive value
    rv$reading_list(updated_list)
    
    # 5. Visual confirmation
    showNotification("Removed from Reading List.", type = "warning", duration = 2)
  })
  
  observeEvent(input$showDeduplicator, {
    shinyjs::toggle("deduplicationSummarySection")
    current_label <- input$showDeduplicator
    new_label <- ifelse(current_label == "Show Deduplicatinator", "Hide Deduplicatinator", "Show Deduplicatinator")
    updateActionButton(session, "showDeduplicator", label = new_label)
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
  

  # ========================================================================
  # BTC DONATION BUTTON
  # ========================================================================
  
  observeEvent(input$btc_donate, {
    showModal(modalDialog(
      title = div(icon("bitcoin"), " Value for Value"),
      
      # Center the content
      div(
        style = "text-align: center;",
        
        # 1. The QR Code Image (Save your QR code as 'btc_qr.png' in the www folder)
        img(src = "btc_qr.png", height = "200px", width = "200px"),
        br(), br(),
        
        # 2. The Text Address (Use a code block for easy copying)
        p("Support the development of The Abstractinator:"),
        tags$code(id = "wallet_address", "bc1qtetgq5hlfx82nl6wlwynp2k60l4skaqelzhdtc"),
        br(), br(),
        
        # 3. Copy to Clipboard Button (Optional JavaScript)
        # Simpler approach: Just ask them to copy it manually to be safe.
        helpText("On-chain BTC.")
      ),
      
      easyClose = TRUE,
      footer = modalButton("Close") # Standard close button
    ))
  })
  
  # ========================================================================
  # HAMBURGER MENU (Settings & API Keys) - FIXED (Brute Force Load)
  # ========================================================================
  observeEvent(input$optsBtn, {
    
    # Prefill ONLY with keys this visitor entered in this session.
    # Server keys from .Renviron are never sent to the browser.
    current_elsevier <- isolate(session_keys$elsevier)
    current_core     <- isolate(session_keys$core)
    current_uspto    <- isolate(session_keys$uspto)
    
    # 3. Open the Modal
    showModal(modalDialog(
      title = "Abstractinator Settings",
      size = "m", 
      easyClose = TRUE,
      
      bslib::navset_pill(
        id = "settings_tabs",
        
        # --- TAB 1: API CONNECTIONS ---
        bslib::nav_panel(
          title = "API Connections",
          br(),
          p("Manage your database connections below.", style = "color: #aaa; font-size: 0.9em; margin-bottom: 20px;"),
          
          # --- SECTION 1: OPEN ACCESS SERVICES ---
          h5("Open Access Services", style = "color: #ddd; border-bottom: 1px solid #444; padding-bottom: 5px; margin-bottom: 15px;"),
          
          # Europe PMC
          div(style = "display: flex; align-items: flex-end; margin-bottom: 15px;",
              div(style="flex-grow: 1;",
                  shinyjs::disabled(
                    textInput("epmc_status_opt", 
                              label = tagList("Europe PMC", icon("check-circle", style="color: #00e676; margin-left: 5px;")), 
                              value = "Integrated (Open Access)", 
                              width = "100%")
                  )
              )
          ),
          
          # OpenAlex
          div(style = "display: flex; align-items: flex-end; margin-bottom: 15px;",
              div(style="flex-grow: 1;",
                  shinyjs::disabled(
                    textInput("OpenAlex_status_opt", 
                              label = tagList("OpenAlex", icon("check-circle", style="color: #00e676; margin-left: 5px;")), 
                              value = "Integrated (Open Access)", 
                              width = "100%")
                  )
              )
          ),
          
          # ClinicalTrials.gov
          div(style = "display: flex; align-items: flex-end; margin-bottom: 15px;",
              div(style="flex-grow: 1;",
                  shinyjs::disabled(
                    textInput("ct_status_opt", 
                              label = tagList("ClinicalTrials.gov", icon("check-circle", style="color: #00e676; margin-left: 5px;")), 
                              value = "Integrated (Open Access)", 
                              width = "100%")
                  )
              )
          ),
          
          # Biorxiv/medrxiv
          div(style = "display: flex; align-items: flex-end; margin-bottom: 25px;",
              div(style="flex-grow: 1;",
                  shinyjs::disabled(
                    textInput("bx_status_opt", 
                              label = tagList("bioRxiv/medRxiv", icon("check-circle", style="color: #00e676; margin-left: 5px;")), 
                              value = "Integrated (Open Access)", 
                              width = "100%")
                  )
              )
          ),
          
          # --- SECTION 2: AUTHENTICATED SERVICES ---
          h5("Authenticated Services", style = "color: #ddd; border-bottom: 1px solid #444; padding-bottom: 5px; margin-bottom: 15px;"),
          
          # --- PRIVACY HANDSHAKE ---
          div(
            style = "background-color: rgba(var(--accent-rgb), 0.1); border-left: 3px solid var(--accent-primary); padding: 10px; margin-bottom: 20px; border-radius: 0 5px 5px 0;",
            p(icon("user-shield"), strong(" API keys are only held in your current session."), style = "color: var(--accent-primary); margin: 0;"),
            p("They are never logged, saved or written to disk. Input keys prior to search for full results.", 
              style = "color: #ccc; font-size: 0.85em; margin: 5px 0 0 0;")
          ),
          
          # Scopus field only appears when ENABLE_SCOPUS=1 (see orchestrate_extraction.R)
          if (ENABLE_SCOPUS) tagList(
            passwordInput("key_elsevier", "Elsevier (Scopus/Embase):", value = current_elsevier, placeholder = "Enter Elsevier API Key"),
            p("Required for Scopus & Embase.", style = "font-size: 0.8em; color: #666; margin-top: -10px; margin-bottom: 15px;")
          ) else p(icon("circle-pause"), " Scopus/Embase is currently unavailable.",
                   style = "font-size: 0.85em; color: #888; margin-bottom: 15px;"),
          
          passwordInput("key_core", "CORE Discovery:", value = current_core, placeholder = "Enter CORE API Key"),
          p("Required for full Open Access aggregation.", style = "font-size: 0.8em; color: #666; margin-top: -10px; margin-bottom: 25px;"),
          
          passwordInput("key_uspto", "USPTO (PatentsView):", 
                    value = current_uspto, 
                    placeholder = "Enter PatentsView API Key"),
          p("Required for Patent search.", style = "font-size: 0.8em; color: #666; margin-top: -10px; margin-bottom: 25px;"),
          
          # --- SAVE BUTTON SECTION ---
          hr(),
          
          actionButton("saveKeys", "Save Configuration", class = "btn-success", width = "100%"),
          
          div(id = "key_save_msg", style = "margin-top: 15px; color: var(--accent-primary); font-weight: bold; text-align: center; display: none;", 
              icon("check"), " Settings Saved! (Reloading app...)")
          
        ),
        
        # --- TAB 2: APPEARANCE (CHARACTER SELECT) ---
        bslib::nav_panel(
          title = "Appearance",
          br(),
          
          # 1. Header
          div(style = "text-align: center; margin-bottom: 20px;",
              h4("Choose Your Companion", style = "font-weight: 700; letter-spacing: 1px; color: #fff;"),
              p("Select the agent that powers your pipeline.", style = "color: #aaa; font-size: 0.9em;")
          ),
          
          # 2. The Selector (With Icons inside)
          div(style = "display: flex; justify-content: center; margin-bottom: 30px;",
              shinyWidgets::radioGroupButtons(
                inputId = "theme_selector",
                label = NULL,
                # Explicitly map Names (Icons) to Values (strings)
                choiceNames = list(
                  tagList(icon("water"), " Narwhal"), 
                  tagList(icon("dragon"), " Dino"),
                  tagList(icon("frog"), " Frog")
                ),
                choiceValues = c("narwhal", "dino", "frog"),
                # Fail-safe: if input is null, default to narwhal
                selected = if(is.null(input$theme_selector)) "narwhal" else input$theme_selector,
                justified = TRUE, 
                status = "primary",
                size = "lg", # Make them chonky
                checkIcon = list(
                  yes = icon("check-circle"),
                  no = icon("circle", style = "opacity: 0.2;") 
                )
              )
          ),
          
          # --- ADD THIS SECTION HERE ---
          hr(style = "border-top: 1px solid #444; margin: 30px 0;"),
          
          div(style = "text-align: center; margin-bottom: 20px;",
              h4("Adjust Text Size", style = "font-weight: 700; letter-spacing: 1px; color: #fff;")
          ),
          
          div(style = "display: flex; justify-content: center; align-items: flex-end; gap: 15px;",
              
              # The Input (Matches your Dark Pill theme automatically)
              div(style = "width: 120px;",
                  numericInput("fontSize", "Font Size (px):", value = 16, min = 5, max = 36)
              ),
              
              # The Button (Cleaned up)
              div(
                # Remove the inline styles here; CSS handles the height now.
                actionButton("applyFont", "Apply Size", 
                             icon = icon("text-height"), 
                             class = "" # Removing btn-primary so CSS takes over
                )
              )
          ),
          
        )
      ) # End navset_pill
    )) # End modalDialog and showModal
  })
  
  
  # ========================================================================
  # THEME ENGINE
  # ========================================================================
  observeEvent(input$theme_selector, {
    
    # 1. Get the selected theme string (e.g., "dino", "frog")
    selected_theme <- input$theme_selector
    
    # 2. JS: Update the CSS Class on Body (Instant Color Swap)
    # We remove all known theme classes and add the new one
    shinyjs::runjs(sprintf(
      "$('body').removeClass('theme-narwhal theme-dino theme-frog').addClass('theme-%s');", 
      selected_theme
    ))
    
    # 3. JS: Update the Images (Assets)
    session$sendCustomMessage("change_theme", selected_theme)
    
    # 4. Notification
    msg <- switch(selected_theme,
      "dino" = "🦖 Dino Mode Activated!",
      "frog" = "🐸 Frog Mode Activated!",
      "🦄 Narwhal Mode Activated!"
    )
    showNotification(msg, type = "message", duration = 2)
  })
  
  
  
  # ========================================================================
  # SAVE API KEYS (EPHEMERAL SESSION STORAGE)
  # ========================================================================
  observeEvent(input$saveKeys, {
    
    # 1. Update Feedback (Immediate Visual Response)
    # FIX: Removed 'class' argument which causes the crash
    updateActionButton(session, "saveKeys",
                       label = "Configuration Saved!",
                       icon = icon("check"))
    
    shinyjs::show("key_save_msg") # Show the little text message too
    
    # 2. STORE KEYS IN THIS SESSION ONLY (empty box = no key)
    session_keys$elsevier <- trimws(input$key_elsevier %||% "")
    session_keys$core     <- trimws(input$key_core %||% "")
    session_keys$uspto    <- trimws(input$key_uspto %||% "")
    
    # 3. Graceful Exit
    shinyjs::delay(1500, {
      removeModal()
      
      # Reset button for next time (FIX: Removed 'class' here too)
      updateActionButton(session, "saveKeys",
                         label = "Save Configuration",
                         icon = NULL) # Removing the icon
      
      shinyjs::hide("key_save_msg")
      
      showNotification("API Keys updated for this session.", type = "message")
    })
  })
  
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
  # SUBMIT FEEDBACK HANDLER (NO DISK BACKUP)
  # ========================================================================
  observeEvent(input$submit_feedback_btn, {
    
    req(input$feedback_msg)
    
    # 1. Latency Masking
    id <- showNotification("Transmitting report...", type = "message", duration = NULL)
    on.exit(removeNotification(id), add = TRUE)
    
    # 2. Prepare Data
    webhook_url <- Sys.getenv("DATA_WEBHOOK_URL")
    
    if (webhook_url == "") {
      showNotification("Config Error: Webhook URL missing.", type = "error")
      return()
    }
    
    # 3. Construct Payload (Discord)
    payload <- list(
      content = paste0("🚨 **Abstractinator Report:** ", input$feedback_category),
      embeds = list(list(
        title = "User Feedback",
        description = input$feedback_msg,
        color = 5763719,
        fields = list(
          list(name = "Session Token", value = session$token, inline = FALSE),
          list(name = "Time", value = as.character(Sys.time()), inline = TRUE)
        ),
        footer = list(text = "Sent via RShiny Pipeline")
      ))
    )
    
    # 4. Execute Pipeline (Webhook Only)
    tryCatch({
      
      response <- httr::POST(
        url = webhook_url,
        body = payload,
        encode = "json",
        httr::add_headers(`User-Agent` = "R-Abstractinator-Bot")
      )
      
      if (httr::status_code(response) >= 200 && httr::status_code(response) < 300) {
        showNotification("Helpinators notified!", type = "message")
        updateTextAreaInput(session, "feedback_msg", value = "")
        removeModal()
      } else {
        stop(paste("API Error:", httr::status_code(response)))
      }
      
    }, error = function(e) {
      message(paste("Webhook Transmission Failed:", e$message))
      showNotification("Transmission failed. Please check your internet connection.", type = "error")
    })
  })
  
  # ========================================================================
  # PLOTINATOR LOGIC (Refactored & Consolidated)
  # ========================================================================
  
  filtered_plot_data <- eventReactive(
    {
      input$dateRange
      input$primaryCellFilter
      input$primaryVirusFilter
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
      
      # Virus Filter
      if (!is.null(input$primaryVirusFilter) && !"All" %in% input$primaryVirusFilter) {
        df <- df %>% filter(primary_virus %in% input$primaryVirusFilter)
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
    
    prepared_data <- prepare_plot_data(plot_df)
    
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
      n_cols_max = input$plot_n_cols_max              
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
    req(exists("virus_alias_expanded"))
    known_viruses <- names(virus_alias_expanded) 
    
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
  
  observeEvent(input$btn_reset_all, {
    shinyWidgets::updatePickerInput(session, "primaryVirusFilter", selected = "All")
    shinyWidgets::updatePickerInput(session, "primaryCellFilter", selected = "All")
  })
  
  # --- C. POPULATE DROPDOWNS (WITH NON-DESCRIPT OPTION) ---
  observe({
    # 1. Populate Virus Choices
    if (exists("virus_alias_expanded")) {
      # We manually add "Non-descript" to the list
      virus_choices <- c("All", "Non-descript", sort(names(virus_alias_expanded)))
      
      shinyWidgets::updatePickerInput(
        session = session,
        inputId = "primaryVirusFilter",
        choices = virus_choices,
        selected = "All"
      )
    }
    
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
          Source = article_row$Source 
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
  
  # ========================================================================
  # READING LIST LOGIC
  # ========================================================================
  observeEvent(input$add_to_reading_list, {
    selected_index <- as.integer(input$add_to_reading_list)
    req(rv$article_df()) 
    
    if (!is.na(selected_index) && selected_index >= 0 && selected_index < nrow(rv$article_df())) {
      article_to_add <- rv$article_df()[selected_index + 1, ]
      
      article_to_add_detailed <- list(
        Title = article_to_add$Title,
        Abstract = article_to_add$Abstract,
        Authors = article_to_add$Authors,
        AuthorAffiliations = article_to_add$AuthorAffiliations, 
        PublicationDate = article_to_add$PublicationDate,
        URL = article_to_add$URL,
        DOI = article_to_add$DOI,
        Source = article_to_add$Source # <--- NEW: SAVE SOURCE
      )
      
      is_duplicate <- any(sapply(rv$reading_list(), function(x) identical(x$DOI, article_to_add_detailed$DOI)))
      
      if (!is_duplicate) {
        current_list <- rv$reading_list()
        rv$reading_list(append(current_list, list(article_to_add_detailed)))
        showNotification("Article added to reading list!", type = "message")
      } else {
        showNotification("Article is already in your reading list.", type = "warning")
      }
    }
  })
  
  output$downloadReadingListUI <- renderUI({
    actionButton("openDownloadOptions", "Download List")
  })
  
  # ========================================================================
  # OUTPUT: READING LIST DISPLAY (With Remove Button)
  # ========================================================================
  output$readingListDisplay <- DT::renderDataTable({
    
    # 1. Update Empty DF Schema
    empty_df <- data.frame(
      Title = character(0), Abstract = character(0), Authors = character(0), 
      AuthorAffiliations = character(0), PublicationDate = character(0), 
      URL = character(0), DOI = character(0), Source = character(0), 
      stringsAsFactors = FALSE
    )
    
    # 2. Build Display DF
    display_df <- if (length(rv$reading_list()) > 0) {
      do.call(rbind, lapply(rv$reading_list(), function(item) {
        data.frame(
          Title = item$Title, Abstract = item$Abstract, Authors = item$Authors,
          AuthorAffiliations = item$AuthorAffiliations, 
          PublicationDate = item$PublicationDate, URL = item$URL, DOI = item$DOI,
          Source = if(!is.null(item$Source)) item$Source else NA_character_, 
          stringsAsFactors = FALSE
        )
      }))
    } else {
      empty_df
    }
    
    DT::datatable(
      display_df,
      options = list(
        pageLength = 10, 
        dom = '<"dt-top-toolbar"lf>rtip',
        language = list(
          search = "_INPUT_",
          searchPlaceholder = "Filter list...",
          lengthMenu = "Show _MENU_"
        ),
        columnDefs = list(
          # --- TARGET 0: TITLE + REMOVE BUTTON ---
          list(
            targets = 0, 
            render = JS(
              "function(data, type, row, meta) {
              if (type === 'display') { 
                var cleanTitle = data.replace(/<\\/?i>/gi, '');
                var url = row[5];
                var source = row[7]; 
                
                // --- BADGE LOGIC ---
                var badge = '';
                if (source && (source.toLowerCase().includes('biorxiv') || source.toLowerCase().includes('medrxiv') || source.toLowerCase().includes('preprint'))) {
                   badge = ' <span style=\"color: #ffab40; font-weight: bold; font-size: 0.75em; border: 1px solid #ffab40; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle;\">PREPRINT</span>';
                } else if (source && (source.toLowerCase().includes('patent') || source.toLowerCase().includes('uspto'))) {
                   badge = ' <span style=\"color: #ff5252; font-weight: bold; font-size: 0.75em; border: 1px solid #ff5252; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle;\">PATENT</span>';
                }
                
                var titleHtml = '';
                if (url) {
                  titleHtml = '<div class=\"title-container\"><a href=\"' + url + '\" target=\"_blank\">' + cleanTitle + '</a>' + badge + '</div>';
                } else {
                  titleHtml = '<div class=\"title-container\">' + cleanTitle + badge + '</div>';
                }
                
                // --- REMOVE BUTTON INJECTION ---
                // We use 'btn-outline-danger' for visual feedback
                var btnHtml = '<button class=\"btn btn-xs btn-outline-danger remove-from-list-btn\" ' +
                              'style=\"margin-top: 5px; font-size: 0.8em; padding: 2px 6px;\" ' +
                              'data-url=\"' + url + '\">' +
                              'Remove from Reading List</button>';
                
                return titleHtml + btnHtml;
              }
              return data;
            }"
            )
          ),
          list(targets = 1, width = "63%", visible = TRUE), # Abstract
          list(
            targets = 2, 
            render = JS(
              "function(data, type, row, meta) {
                if (type === 'display' && data) {
                  var authors = data.split('; ');
                  var affiliationsData = row[3]; 
                  var parsed = {};
                  try { parsed = JSON.parse(affiliationsData); } catch(e) { }

                  return authors.map(function(author, index) {
                    var affText = 'No affiliation available';
                    var r_index_key = (index + 1).toString();
                    if (parsed && typeof parsed === 'object') {
                      if (parsed[r_index_key] && parsed[r_index_key].affiliations) {
                        affText = parsed[r_index_key].affiliations;
                      } else if (parsed[index] && parsed[index].affiliations) {
                        affText = parsed[index].affiliations;
                      }
                    }
                    var divId = 'rl-aff-' + meta.row + '-' + index;
                    return '<span class=\"author-expand-trigger\" data-affiliation-id=\"' + divId + '\">' + 
                           author + '</span>' +
                           '<div id=\"' + divId + '\" class=\"affiliation-details hidden\">' + affText + '</div>';
                  }).join('; ');
                }
                return data;
              }"
            )
          ),
          list(targets = 3, visible = FALSE), 
          list(targets = 4, visible = TRUE),  
          list(targets = 5, visible = FALSE), # URL (Used for ID)
          list(targets = 6, visible = FALSE), 
          list(targets = 7, visible = FALSE)  
        )
      ),
      colnames = c("Title", "Abstract", "Authors", "Affiliations", "Publication Date", "URL", "DOI", "Source"),
      rownames = FALSE,
      escape = FALSE,
      selection = "none",
      
      # --- DEDICATED CALLBACK FOR READING LIST ---
      callback = JS(
        "$(document).off('click', '.remove-from-list-btn').on('click', '.remove-from-list-btn', function() {",
        "  var url = $(this).data('url');",
        "  // Send the URL to the server input 'remove_from_reading_list_btn'",
        "  Shiny.setInputValue('remove_from_reading_list_btn', url, { priority: 'event' });",
        "});",
        
        "$(document).off('click', '.author-expand-trigger').on('click', '.author-expand-trigger', function() {",
        "  var affiliationId = $(this).data('affiliation-id');",
        "  $('#' + affiliationId).toggleClass('hidden');",
        "});"
      )
    )
  })
  
  # ========================================================================
  # REMOVE BUTTON LISTENER (Reading List Tab)
  # ========================================================================
  observeEvent(input$remove_from_reading_list_btn, {
    target_url <- input$remove_from_reading_list_btn
    req(target_url)
    
    current_list <- rv$reading_list()
    
    # 1. Defensive Check: Ensure list is not empty
    if (length(current_list) > 0) {
      
      # 2. Find the match using URL (Robust)
      matches <- vapply(current_list, function(x) {
        isTRUE(as.character(x$URL) == as.character(target_url))
      }, FUN.VALUE = logical(1))
      
      match_index <- which(matches)
      
      # 3. Remove if found
      if (length(match_index) > 0) {
        # Capture title for notification
        item_title <- current_list[[match_index[1]]]$Title
        
        # Remove item
        updated_list <- current_list[-match_index]
        rv$reading_list(updated_list)
        
        showNotification(
          paste("Removed:", str_trunc(item_title, 30)), 
          type = "warning", 
          duration = 2
        )
      }
    }
  })
  
  # ========================================================================
  # DOWNLOAD READING LIST LOGIC (Fixed: Handlers moved to Top Level)
  # ========================================================================
  
  # 1. THE TRIGGER (UI ONLY)
  # This only opens the menu. It does NOT define the downloads.
  observeEvent(input$openDownloadOptions, {
    showModal(modalDialog(
      title = div(icon("download"), " Download Reading List"),
      
      p("Select a format compatible with your reference manager.", style = "color: #ccc; margin-bottom: 25px;"),
      
      # --- CSV BUTTON ---
      downloadButton("downloadReadingListCsv", 
                     label = " Download as CSV (Excel)", 
                     class = "btn-download-pill csv", 
                     icon = icon("file-csv")
      ),
      
      # --- ZOTERO BUTTON ---
      downloadButton("downloadZoteroRIS", 
                     label = " Download for Zotero (.ris)", 
                     class = "btn-download-pill ris", 
                     icon = icon("book")
      ),
      
      # --- ENDNOTE BUTTON ---
      downloadButton("downloadEndnoteENW", 
                     label = " Download for EndNote (.enw)", 
                     class = "btn-download-pill enw", 
                     icon = icon("quote-right")
      ),
      
      easyClose = TRUE,
      footer = modalButton("Dismiss"),
      size = "s" 
    ))
  })
  
  # 2. THE HANDLERS (DATA LOGIC)
  # CRITICAL: These must be OUTSIDE the observeEvent to work!
  
  # --- CSV HANDLER ---
  output$downloadReadingListCsv <- downloadHandler(
    filename = function() {
      paste0("Abstractinator_List_", Sys.Date(), ".csv")
    },
    content = function(file) {
      reading_list_data <- rv$reading_list()
      
      if (length(reading_list_data) > 0) {
        # robust data frame creation
        combined_df <- do.call(rbind, lapply(reading_list_data, function(x) {
          data.frame(
            Title = if(is.null(x$Title)) NA else x$Title,
            Authors = if(is.null(x$Authors)) NA else x$Authors,
            PublicationDate = if(is.null(x$PublicationDate)) NA else x$PublicationDate,
            Source = if(is.null(x$Source)) NA else x$Source,
            DOI = if(is.null(x$DOI)) NA else x$DOI,
            URL = if(is.null(x$URL)) NA else x$URL,
            Abstract = if(is.null(x$Abstract)) NA else x$Abstract,
            Affiliations = if(is.null(x$AuthorAffiliations)) NA else x$AuthorAffiliations,
            stringsAsFactors = FALSE
          )
        }))
        write.csv(combined_df, file, row.names = FALSE, na = "")
      } else {
        write.csv(data.frame(Message = "Reading list is empty."), file, row.names = FALSE)
      }
    }
  )
  
  # --- ZOTERO HANDLER ---
  output$downloadZoteroRIS <- downloadHandler(
    filename = function() {
      paste0("Abstractinator_Zotero_", Sys.Date(), ".ris")
    },
    content = function(file) {
      reading_list_data <- rv$reading_list()
      
      if (length(reading_list_data) > 0) {
        ris_entries <- lapply(reading_list_data, function(item) {
          entry <- c("TY  - JOUR")
          if (!is.null(item$Title)) entry <- c(entry, paste0("TI  - ", item$Title))
          
          if (!is.null(item$Authors) && nchar(item$Authors) > 0) {
            # Fix: Handle multiple authors correctly for RIS
            authors <- strsplit(item$Authors, ";\\s*")[[1]]
            for(au in authors) {
              entry <- c(entry, paste0("AU  - ", au))
            }
          }
          
          if (!is.null(item$PublicationDate)) entry <- c(entry, paste0("DA  - ", item$PublicationDate))
          if (!is.null(item$Source))          entry <- c(entry, paste0("JO  - ", item$Source))
          if (!is.null(item$Abstract))        entry <- c(entry, paste0("AB  - ", item$Abstract))
          if (!is.null(item$DOI))             entry <- c(entry, paste0("DO  - ", item$DOI))
          if (!is.null(item$URL))             entry <- c(entry, paste0("UR  - ", item$URL))
          
          entry <- c(entry, "ER  - ", "") 
          return(entry)
        })
        writeLines(unlist(ris_entries), file)
      } else {
        writeLines("Empty Reading List", file)
      }
    }
  )
  
  # --- ENDNOTE HANDLER ---
  output$downloadEndnoteENW <- downloadHandler(
    filename = function() {
      paste0("Abstractinator_EndNote_", Sys.Date(), ".enw")
    },
    content = function(file) {
      reading_list_data <- rv$reading_list()
      
      if (length(reading_list_data) > 0) {
        enw_entries <- lapply(reading_list_data, function(item) {
          entry <- c("%0 Journal Article")
          if (!is.null(item$Title)) entry <- c(entry, paste0("%T ", item$Title))
          
          if (!is.null(item$Authors) && nchar(item$Authors) > 0) {
            authors <- strsplit(item$Authors, ";\\s*")[[1]]
            for(au in authors) {
              entry <- c(entry, paste0("%A ", au))
            }
          }
          
          if (!is.null(item$PublicationDate)) {
            entry <- c(entry, paste0("%D ", substr(item$PublicationDate, 1, 4))) 
            entry <- c(entry, paste0("%8 ", item$PublicationDate)) 
          }
          
          if (!is.null(item$Source))   entry <- c(entry, paste0("%J ", item$Source))
          if (!is.null(item$Abstract)) entry <- c(entry, paste0("%X ", item$Abstract))
          if (!is.null(item$DOI))      entry <- c(entry, paste0("%R ", item$DOI))
          if (!is.null(item$URL))      entry <- c(entry, paste0("%U ", item$URL))
          
          entry <- c(entry, "") 
          return(entry)
        })
        writeLines(unlist(enw_entries), file)
      } else {
        writeLines("Empty Reading List", file)
      }
    }
  )
}

shinyApp(ui = ui, server = server)



