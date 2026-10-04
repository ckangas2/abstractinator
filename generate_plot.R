# generate_plot.R

library(plotly)
library(tidyverse)
library(stringr)
library(ggbeeswarm) 

# ========================================================================
# 1. HELPER FUNCTIONS (Extraction Logic)
# ========================================================================
# (These remain unchanged)

extract_primary_cell_weighted_base <- function(row, immune_cell_alias_list) {
  title <- row["Title"]
  abstract <- row["Abstract"]
  best_match <- "Non-descript"
  highest_weight <- 0
  
  title_words <- if (!is.na(title) && nchar(trimws(title)) > 0) strsplit(tolower(trimws(title)), "\\s+")[[1]] else character(0)
  abstract_words <- if (!is.na(abstract) && nchar(trimws(abstract)) > 0) strsplit(tolower(trimws(abstract)), "\\s+")[[1]] else character(0)
  
  for (cell_type in names(immune_cell_alias_list_processed)) {
    aliases_processed <- immune_cell_alias_list_processed[[cell_type]]
    for (alias_words in aliases_processed) {
      title_match <- contains_exact_phrase_preprocessed(title_words, alias_words)
      abstract_match <- contains_exact_phrase_preprocessed(abstract_words, alias_words)
      
      current_weight <- 0
      if (title_match) current_weight <- current_weight + 2
      if (abstract_match) current_weight <- current_weight + 1
      
      if (current_weight > highest_weight) {
        highest_weight <- current_weight
        best_match <- cell_type
      }
    }
  }
  return(best_match)
}

extract_primary_virus_weighted_base <- function(row, virus_alias_expanded) {
  title <- row["Title"]
  abstract <- row["Abstract"]
  best_match <- "Non-descript"
  highest_weight <- 0
  
  title_words <- if (!is.na(title) && nchar(trimws(title)) > 0) strsplit(tolower(trimws(title)), "\\s+")[[1]] else character(0)
  abstract_words <- if (!is.na(abstract) && nchar(trimws(abstract)) > 0) strsplit(tolower(trimws(abstract)), "\\s+")[[1]] else character(0)
  
  for (virus in names(virus_alias_expanded_processed)) {
    aliases_processed <- virus_alias_expanded_processed[[virus]]
    for (alias_words in aliases_processed) {
      title_match <- contains_exact_phrase_preprocessed(title_words, alias_words)
      abstract_match <- contains_exact_phrase_preprocessed(abstract_words, alias_words)
      
      current_weight <- 0
      if (title_match) current_weight <- current_weight + 2
      if (abstract_match) current_weight <- current_weight + 1
      
      if (current_weight > highest_weight) {
        highest_weight <- current_weight
        best_match <- virus
      }
    }
  }
  return(best_match)
}

contains_exact_phrase_preprocessed <- function(text_words, phrase_words) {
  n_phrase <- length(phrase_words)
  n_text <- length(text_words)
  if (n_phrase == 0) return(TRUE)
  if (n_text == 0) return(FALSE)
  for (i in 1:(n_text - n_phrase + 1)) {
    if (all(text_words[i:(i + n_phrase - 1)] == phrase_words)) {
      return(TRUE)
    }
  }
  return(FALSE)
}

# ========================================================================
# 2. DATA PREPARATION
# ========================================================================

# pathogen_col: which category column forms the plot's pathogen axis
# ("primary_virus" by default, "primary_bacteria" in bacteria mode, and any
# future pool). It is copied to primary_pathogen so the plot code is generic.
prepare_plot_data <- function(article_df, pathogen_col = "primary_virus") {
  if (!pathogen_col %in% names(article_df)) pathogen_col <- "primary_virus"
  article_df$primary_pathogen <- article_df[[pathogen_col]]
  cols_to_keep <- c("Title", "primary_cell", "primary_pathogen", "Authors", "URL", "SortDate", "DOI")
  if ("is_bioinformatics" %in% names(article_df)) {
    cols_to_keep <- c(cols_to_keep, "is_bioinformatics")
  }
  
  plot_df <- article_df %>%
    dplyr::select(all_of(cols_to_keep)) %>%
    dplyr::mutate(
      linked_title = paste0("<a href='", URL, "' target='_blank'>", Title, "</a>")
    )
  
  return(plot_df)
}

# ========================================================================
# 3. GENERATE PLOT (BEESWARM EDITION - "EVERYTHING" ENABLED)
# ========================================================================


# generate_plot.R

# pathogen_label: what the pathogen axis is called in the title and tooltips
# ("Virus", "Bacteria", ...).
generate_interactive_plot <- function(data_filtered, selected_viruses, selected_cell_types,
                                      n_cols_max = 8, pathogen_label = "Virus") {
  
  
  
  # --- A. Palette Definition ---
  narwhal_palette <- c(
    "#00bcd4", "#e5e4e2", "#98ddff", "#f4c2c2", "#73c2fb", "#fffdd0",
    "#dacff9", "#8fafff", "#fcebe2", "#c2eeeb", "#A52A2A", "#FFD700",
    "#006994", "#008080", "#191970", "#2E8B57", "#4682B4", "#708090", 
    "#F7931A", "#FF7F50", "#D8BFD8", "#98FF98", "#DC143C", "#800080", "#B0C4DE"
  )
  
  # --- B. Smart Filtering Logic ---
  plot_data_step1 <- data_filtered
  
  if (!("All" %in% selected_viruses)) {
    plot_data_step1 <- plot_data_step1 %>% filter(primary_pathogen %in% selected_viruses)
  }
  
  if (!("All" %in% selected_cell_types)) {
    plot_data_step1 <- plot_data_step1 %>% filter(primary_cell %in% selected_cell_types)
  }
  
  # --- C. Factor Level Handling ---
  # Determine actual levels present in the filtered data to prevent empty legend keys
  actual_virus_levels <- unique(plot_data_step1$primary_pathogen)
  actual_virus_levels <- actual_virus_levels[!is.na(actual_virus_levels) & actual_virus_levels != ""]
  
  actual_cell_levels <- unique(plot_data_step1$primary_cell)
  actual_cell_levels <- actual_cell_levels[!is.na(actual_cell_levels) & actual_cell_levels != ""]
  
  # --- D. Data Transformation ---
  # 1. Parse Dates
  # 2. Factor reordering (Virus by frequency, Cell by alphabet)
  # 3. Create Hover Text
  plot_data_final <- plot_data_step1 %>%
    mutate(
      PlotDate = case_when(
        grepl("Start:", SortDate) ~ as.Date(str_extract(SortDate, "\\d{4}-\\d{2}-\\d{2}")),
        grepl("^\\d{4}-\\d{2}-\\d{2}$", trimws(SortDate)) ~ as.Date(trimws(SortDate)),
        grepl("^\\d{4}-\\d{2}$", trimws(SortDate)) ~ as.Date(paste0(trimws(SortDate), "-01")),
        grepl("^\\d{4}$", trimws(SortDate)) ~ as.Date(paste0(trimws(SortDate), "-01-01")),
        TRUE ~ as.Date(NA)
      )
    ) %>%
    filter(!is.na(PlotDate)) %>%
    mutate(
      primary_pathogen = factor(primary_pathogen, levels = actual_virus_levels) %>% fct_infreq() %>% fct_rev(),
      primary_cell = factor(primary_cell, levels = actual_cell_levels),
      
      hover_text = paste0(
        "<b>Title:</b> ", str_trunc(Title, 60), "<br>",
        "<b>Date:</b> ", format(PlotDate, "%b %Y"), "<br>",
        "<b>", pathogen_label, ":</b> ", primary_pathogen, "<br>",
        "<b>Cell:</b> ", primary_cell, "<br>",
        "<b>DOI:</b> ", DOI
      )
    ) 
  
  # Diagnostic Check
  if (nrow(plot_data_final) == 0) return(NULL)
  
  # --- E. Calculate Separators ---
  # This adds the horizontal grid lines between Virus groups
  n_viruses_plotted <- length(unique(plot_data_final$primary_pathogen))
  if (n_viruses_plotted > 1) {
    separators <- seq(1.5, n_viruses_plotted - 0.5, 1)
  } else {
    separators <- numeric(0)
  }
  
  # --- F. Dark Mode Theme Colors ---
  bg_dark <- "#262626"
  bg_darker <- "#1a1a1a"
  text_light <- "#e0e0e0"
  grid_line <- "#404040"
  
  # --- G. GGPLOT Construction ---
  p <- ggplot(plot_data_final, aes(
    x = primary_pathogen,      
    y = PlotDate,           
    fill = primary_cell,
    text = hover_text
  )) +
    
    geom_vline(xintercept = separators, color = grid_line, linewidth = 0.5) +
    
    # --- CHANGE IS HERE ---
    # Switch key from DOI to URL
    geom_point(
      aes(key = URL), 
      position = ggbeeswarm::position_quasirandom(width = 0.4, varwidth = TRUE),
      shape = 21, 
      color = "black", 
      stroke = 0.35, 
      size = 4, 
      alpha = 0.9
    ) +
    
    coord_flip() +
    
    scale_fill_manual(values = narwhal_palette) +
    scale_y_date(date_labels = "%b %Y", expand = expansion(mult = c(0.05, 0.05))) +
    
    labs(
      title = paste0(pathogen_label, "-Immune Timeline (n = ", nrow(plot_data_final), ")"), 
      x = NULL, 
      y = NULL, 
      fill = "Primary Cell Type"
    ) +
    
    theme_minimal(base_size = 14) +
    theme(
      panel.background = element_rect(fill = bg_dark, color = NA),
      plot.background = element_rect(fill = bg_darker, color = NA),
      text = element_text(color = text_light),
      axis.text.y = element_text(face = "bold", color = text_light, size = 11),
      axis.text.x = element_text(color = text_light),
      panel.grid.major.y = element_blank(), 
      panel.grid.major.x = element_line(color = grid_line, linetype = "dotted"),
      panel.grid.minor = element_blank(),
      legend.background = element_rect(fill = bg_darker, color = NA),
      legend.text = element_text(color = text_light),
      legend.position = "right"
    )
  
  # --- H. Conversion & Layout ---
  
  # Convert to Plotly
  # 'tooltip = "text"' ensures only our custom hover_text is shown
  # 'source' allows app.R to listen for clicks
  gg <- ggplotly(p, tooltip = "text", source = "article_plot_click")
  
  # Apply Final Layout
  gg %>%
    layout(
      plot_bgcolor = bg_dark,
      paper_bgcolor = bg_darker,
      font = list(color = text_light),
      hoverlabel = list(bgcolor = "white", font = list(size = 12, color = "black")),
      legend = list(orientation = "v", x = 1.02, y = 0.5)
    ) %>%
    event_register("plotly_click")
}

