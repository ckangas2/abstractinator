# app/server/reading_list.R
#
# Reading list: adding, showing and removing items, and the CSV / Markdown /
# Zotero / EndNote downloads.
#
# Runs inside server() in app.R (sourced with local = TRUE), so it shares
# input, output, session and every variable defined by the parts before it.

  # ========================================================================
  # READING LIST LOGIC
  # ========================================================================
  observeEvent(input$add_to_reading_list, {
    # The button sends the result's stable ID (not its position on screen, which
    # changes with filtering, sorting and paging)
    selected_key <- as.character(input$add_to_reading_list)
    req(rv$article_df(), selected_key)
    
    matches <- which(rv$article_df()$ItemKey == selected_key)
    if (length(matches) > 0) {
      article_to_add <- rv$article_df()[matches[1], ]
      
      article_to_add_detailed <- list(
        Title = article_to_add$Title,
        Abstract = article_to_add$Abstract,
        Authors = article_to_add$Authors,
        AuthorAffiliations = article_to_add$AuthorAffiliations, 
        PublicationDate = article_to_add$PublicationDate,
        URL = article_to_add$URL,
        DOI = article_to_add$DOI,
        Source = article_to_add$Source,
        primary_cell = article_to_add$primary_cell, primary_virus = article_to_add$primary_virus,
        primary_bacteria = article_to_add$primary_bacteria,
        ItemKey = article_to_add$ItemKey
      )
      
      is_duplicate <- any(vapply(rv$reading_list(), function(x) identical(x$ItemKey, article_to_add_detailed$ItemKey), logical(1)))
      
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
      ItemKey = character(0),
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
          ItemKey = if(!is.null(item$ItemKey)) item$ItemKey else NA_character_,
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
                   badge = ' <span style=\"color: #ffab40; font-weight: bold; font-size: 0.75em; border: 1px solid #ffab40; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">PREPRINT</span>';
                } else if (source && (source.toLowerCase().includes('patent') || source.toLowerCase().includes('uspto'))) {
                   badge = ' <span style=\"color: #ff5252; font-weight: bold; font-size: 0.75em; border: 1px solid #ff5252; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">PATENT</span>';
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
                              'data-key=\"' + row[8] + '\">' +
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
          list(targets = 7, visible = FALSE),
          list(targets = 8, visible = FALSE)  # ItemKey
        )
      ),
      colnames = c("Title", "Abstract", "Authors", "Affiliations", "Publication Date", "URL", "DOI", "Source", "ItemKey"),
      rownames = FALSE,
      escape = FALSE,
      selection = "none",
      
      # --- DEDICATED CALLBACK FOR READING LIST ---
      callback = JS(
        "$(document).off('click', '.remove-from-list-btn').on('click', '.remove-from-list-btn', function() {",
        "  var url = $(this).attr('data-key');",
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
        isTRUE(as.character(x$ItemKey) == as.character(target_url))
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
      
      p("Select a format for your reference manager, a spreadsheet, or your notes.", style = "color: #ccc; margin-bottom: 25px;"),
      
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
      
      # --- MARKDOWN BUTTON ---
      downloadButton("downloadReadingListMd",
                     label = " Download as Markdown (.md)",
                     class = "btn-download-pill md",
                     icon = icon("markdown")
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
      reading_list_data <- lapply(rv$reading_list(), plain_text_item)
      
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
  
  # --- MARKDOWN HANDLER ---
  output$downloadReadingListMd <- downloadHandler(
    filename = function() paste0("Abstractinator_List_", Sys.Date(), ".md"),
    content = function(file) {
      md <- reading_list_markdown(lapply(rv$reading_list(), plain_text_item))
      writeLines(enc2utf8(md), file, useBytes = TRUE)
    }
  )

  # --- ZOTERO HANDLER ---
  output$downloadZoteroRIS <- downloadHandler(
    filename = function() {
      paste0("Abstractinator_Zotero_", Sys.Date(), ".ris")
    },
    content = function(file) {
      reading_list_data <- lapply(rv$reading_list(), plain_text_item)
      
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
      reading_list_data <- lapply(rv$reading_list(), plain_text_item)
      
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
