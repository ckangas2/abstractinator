# The Shiny app is split across app.R, app/ui.R, app/dt_options.R and
# app/server/*.R. These tests make sure the pieces still fit together.

test_that("every app file parses", {
  files <- c(file.path(repo_root, "app.R"),
             list.files(file.path(repo_root, "app"), "\\.R$", recursive = TRUE, full.names = TRUE))
  expect_gt(length(files), 5)
  for (f in files) expect_no_error(parse(f, keep.source = FALSE), message = f)
})

test_that("every server part listed in app.R exists, and every file is listed", {
  # Read SERVER_PARTS the way R does: parse app.R and evaluate that assignment.
  exprs <- as.list(parse(file.path(repo_root, "app.R"), keep.source = FALSE))
  def <- Filter(function(e) is.call(e) && identical(e[[1]], as.name("<-")) &&
                  identical(e[[2]], as.name("SERVER_PARTS")), exprs)
  expect_length(def, 1)
  listed <- eval(def[[1]][[3]], baseenv())
  on_disk <- sub("\\.R$", "", list.files(file.path(repo_root, "app", "server"), "\\.R$"))
  expect_setequal(listed, on_disk)
})

test_that("the server starts and sets up its state", {
  for (p in c("shiny", "shinythemes", "bslib", "shinyjs", "shinyWidgets", "plotly", "DT", "htmlTable", "withr")) {
    skip_if_not_installed(p)
  }
  # app.R sets an environment variable and a future plan; put both back after.
  withr::local_envvar(c(INTEGRATE_NIH_NSF = NA))
  old_plan <- future::plan()
  withr::defer(future::plan(old_plan))
  withr::local_dir(repo_root)

  shiny::testServer(shiny::shinyAppDir(repo_root), {
    session$flushReact()
    expect_true(is.function(request_search))
    expect_equal(source_filter(), "All")
    expect_null(rv$article_df())
    expect_length(rv$reading_list(), 0)
  })
})

test_that("the results every tab reads keep the columns the Therapinator and report need", {
  # The website trims results to one column list (search.R). A column missing
  # from it silently empties whichever tab reads it -- which is how the
  # Therapinator first shipped blank.
  src <- paste(readLines(file.path(repo_root, "app/server/search.R"), warn = FALSE), collapse = "\n")
  sel <- regmatches(src, regexpr("select\\(Title, Abstract, Authors,[^)]*\\)", src))
  expect_length(sel, 1)
  needed <- c("primary_modality", "modality_hits_combined", "Interventions", "Conditions",
              "Phase", "TrialStatus", "TrialStart", "MergedFrom", "NCTId", "Source")
  for (col in needed) expect_match(sel, paste0("\\b", col, "\\b"), info = col)
})

test_that("server code calls shiny::validate, never the bare name", {
  # jsonlite (attached after shiny) exports its own validate(txt), so a bare
  # validate(need(...)) in a render function errors with "is.character(txt)
  # is not TRUE". It broke the Plotinator once and the Therapinator once.
  files <- list.files(file.path(repo_root, "app", "server"), pattern = "[.]R$", full.names = TRUE)
  for (f in files) {
    code <- sub("#.*$", "", readLines(f, warn = FALSE))
    bare <- grep("(^|[^:A-Za-z0-9_.])validate\\(", code)
    expect_length(bare, 0)
  }
})

test_that("the Therapinator, kept out of the tab bar, opens from the settings menu", {
  # SHOW_THERAPINATOR = FALSE hides the tab; the Beta link in the settings
  # menu must still reach it, and its server logic must still run.
  settings  <- paste(readLines(file.path(repo_root, "app/server/settings.R"), warn = FALSE), collapse = "\n")
  landscape <- paste(readLines(file.path(repo_root, "app/server/landscape.R"), warn = FALSE), collapse = "\n")
  expect_match(settings, 'actionLink("open_therapinator", "Therapinator (beta)"', fixed = TRUE)
  expect_match(landscape, "observeEvent(input$open_therapinator", fixed = TRUE)
  expect_match(landscape, 'nav_show("main_app_tabs", target = "Therapinator", select = TRUE', fixed = TRUE)
  # The tab's outputs are defined whatever SHOW_THERAPINATOR says, not in an else branch.
  expect_false(grepl("} else {", landscape, fixed = TRUE))
  expect_match(landscape, "output$landscapeTable", fixed = TRUE)
})

test_that("the settings menu links to the program registry pages", {
  # www/registry/ is written by tracker/site_pages.py; the link is relative so
  # it works under any URL prefix.
  settings <- paste(readLines(file.path(repo_root, "app/server/settings.R"), warn = FALSE), collapse = "\n")
  expect_match(settings, 'tags$a(href = "registry/index.html", target = "_blank"', fixed = TRUE)
  expect_match(settings, '" Registry")', fixed = TRUE)
})
