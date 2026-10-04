# agent/run_api.R  -- start the REST API. Run from the repo root:
#   /usr/bin/Rscript agent/run_api.R
options(abstractinator.root = getwd())
pr <- plumber::pr("agent/api.R")
setwd(getOption("abstractinator.root"))  # make sure request handling also runs from the root
plumber::pr_run(pr, host = "127.0.0.1", port = 8100, docs = FALSE)
