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
