# agent/run_api.R  -- start the REST API. Run from the repo root:
#   /usr/bin/Rscript agent/run_api.R
options(abstractinator.root = getwd())
pr <- plumber::pr("agent/api.R")
setwd(getOption("abstractinator.root"))  # make sure request handling also runs from the root
# Each API process gets its own port from systemd (8100, 8101, ...).
port <- suppressWarnings(as.integer(Sys.getenv("ABSTRACTINATOR_API_PORT", "8100")))
if (is.na(port)) port <- 8100L
plumber::pr_run(pr, host = "127.0.0.1", port = port, docs = FALSE)
