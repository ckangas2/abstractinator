# app.R -- The Abstractinator's Shiny app.
#
# Setup lives here; the page and its behaviour live in app/:
#   app/ui.R          the page layout
#   app/dt_options.R  the results table's options
#   app/server/*.R    the server, in parts (see SERVER_PARTS below)
# R/ holds helpers that Shiny loads automatically; the search engine is
# loaded from R/engine.R.

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

plan(multisession, workers = 8)

# Display safety + export helpers (sanitize_html, sanitize_results, make_item_key, ...)
source("R/display_utils.R")

# Fallback for a NULL / empty value (shiny provides one, but be explicit)
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# --------------------------------------------------------------------------
# PATHOGEN POOLS (Plotinator modes)
# --------------------------------------------------------------------------
# Each pool swaps the plot's pathogen axis for a different category list from
# aliases.R. To add a mode (fungi, drug classes, a lab's own vocabulary):
# define the alias list in aliases.R, tag it in orchestrate_extraction.R, and
# add one entry here.
PATHOGEN_POOLS <- list(
  "Viruses"  = list(column = "primary_virus",    aliases = "virus_alias_expanded",
                    label = "Virus",    icon = "virus",     known_label = "\U0001F9A0 Viruses Only"),
  "Bacteria" = list(column = "primary_bacteria", aliases = "bacteria_alias_expanded",
                    label = "Bacteria", icon = "bacterium", known_label = "\U0001F9A0 Bacteria Only")
)

# --- SEARCH ENGINE ---
source("R/engine.R")
load_engine()
source("generate_plot.R")

# Where the app lives, so the server parts are found whatever the working
# directory is when a session starts.
APP_DIR <- getwd()

source(file.path(APP_DIR, "app", "dt_options.R"))
ui <- source(file.path(APP_DIR, "app", "ui.R"), local = TRUE)$value

# The server, split into parts by area. Each part is sourced INSIDE server()
# with local = TRUE, so it runs exactly as if written inline: the parts share
# input, output, session and each other's variables, in this order.
SERVER_PARTS <- c("state", "landing", "search", "settings", "help_feedback",
                  "plot", "reading_list")

server <- function(input, output, session) {
  for (part in SERVER_PARTS) {
    source(file.path(APP_DIR, "app", "server", paste0(part, ".R")), local = TRUE)
  }
}

shinyApp(ui = ui, server = server)
