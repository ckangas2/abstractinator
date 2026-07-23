library(rsconnect)
library(renv)

# 0. FREEZE THE ENVIRONMENT
# Ensures renv.lock matches your current working packages
renv::init()

renv::snapshot()

# 1. SELECT FILES
# Step A: Capture all visible top-level files (app.R, www, styles.css, renv.lock, etc.)
files_to_deploy <- list.files(recursive = FALSE, all.files = FALSE)

# Step B: EXCLUDE the 'renv' folder
# We want 'renv.lock' (the recipe), but NOT 'renv/' (the cooked meal)
files_to_deploy <- files_to_deploy[files_to_deploy != "renv"]

# Step C: INCLUDE the hidden .Renviron
# This is the VIP guest that usually gets ignored by list.files()
if(file.exists(".Renviron")) {
  files_to_deploy <- c(files_to_deploy, ".Renviron")
} else {
  warning("⚠️ .Renviron file not found! Your keys won't be uploaded.")
}

# 2. VERIFY (Optional but recommended)
message("--- FILES TO BE DEPLOYED ---")
print(files_to_deploy)

# 3. LAUNCH
rsconnect::deployApp(
  appDir = getwd(),
  appName = "Abstractinator",
  forceUpdate = TRUE,
  appFiles = files_to_deploy, # <--- Uses our curated list
  launch.browser = TRUE
)
