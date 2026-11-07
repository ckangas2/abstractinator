# app/server/settings.R
#
# Donate modal, settings menu (API keys, theme, font), theme engine and saving
# keys for this session.
#
# Runs inside server() in app.R (sourced with local = TRUE), so it shares
# input, output, session and every variable defined by the parts before it.

  # ========================================================================
  # BTC DONATION BUTTON
  # ========================================================================
  
  observeEvent(input$footer_donate_btn, {
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
            p("They are never logged, saved or written to disk. Input keys prior to search for full results. ",
              "(Search terms themselves are logged anonymously, without any account or IP address, to help improve the tool.)", 
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
              icon("check"), " Keys saved for this session.")
          
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
