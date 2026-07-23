# -----------------------------------------------------------------------------
# Script: batch_rename_icons.R
# Purpose: Normalize file names for 'dino' and 'frog' assets in www/
# Author: Senior Bioinformatician (Gemini)
# -----------------------------------------------------------------------------

library(fs)
library(stringr)
library(dplyr)
library(tibble)

# 1. Setup & Defensive Checks
target_dir <- "www"
if (!dir_exists(target_dir)) stop("Directory 'www' not found in working directory.")

# 2. Identify Files (Regex for robustness)
# Matches files starting with 'noun', containing 'dinosaur' or 'frog', ending in .png
raw_files <- dir_ls(target_dir, glob = "*.png") %>% 
  path_file() %>% 
  str_subset("^noun-(dinosaur|frog)")

if (length(raw_files) == 0) stop("No matching files found to rename.")

# 3. Construct Mapping Table (Corrected)
rename_map <- tibble(old_name = raw_files) %>%
  # Step 1: Create the classification columns
  mutate(
    type = str_extract(old_name, "(dinosaur|frog)"),
    clean_type = ifelse(type == "dinosaur", "dino", type)
  ) %>%
  # Step 2: Group by the new column to generate indices
  group_by(clean_type) %>%
  mutate(
    group_idx = row_number(),
    new_name = sprintf("%s_%02d.png", clean_type, group_idx)
  ) %>%
  ungroup() # Always ungroup after group_by to prevent downstream errors

# -----------------------------------------------------------------------------
# BLOCK A: DRY RUN
# -----------------------------------------------------------------------------
print("--- PREVIEW OF CHANGES ---")
print(rename_map %>% select(old_name, new_name))

# -----------------------------------------------------------------------------
# BLOCK B: EXECUTE
# -----------------------------------------------------------------------------
file_move(path(target_dir, rename_map$old_name), path(target_dir, rename_map$new_name))
 print("Renaming complete.")
 