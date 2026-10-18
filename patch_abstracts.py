#!/usr/bin/env python3
"""Chunk 1: handle abstract-less records, and fix two dedup bugs.

  deduplication.R
    - cross-fill Abstract/PMCID/IsOpenAccess across duplicates before choosing
      a winner, so a record is only abstract-less if NO source had one
    - prefer abstract-bearing records when source priority ties
    - fix clean_title: "[[:punct:]]$ " (space after the end anchor) never matched
    - drop the stray DOI_clean column from the no-DOI branch
  EPMC extractor
    - keep pmcid and isOpenAccess, which resultType=core already returns
  app.R
    - carry PMCID / IsOpenAccess / HasAbstract as appended columns (23,24,25),
      leaving every existing JS index alone
    - abstract-less rows sort below abstract-bearing ones, newest first within
      each group, and the cell names the source instead of sitting blank

Run from the repo root.  --check reports without writing.
"""
import re
import subprocess
import sys
from pathlib import Path

CHECK = "--check" in sys.argv
edits = []     # (path, label, old, new)


def find_file(pattern, *candidates):
    for c in candidates:
        p = Path(c)
        if p.exists() and pattern in p.read_text(encoding="utf-8"):
            return p
    out = subprocess.run(["grep", "-rl", pattern, "R/", "."],
                         capture_output=True, text=True).stdout.split()
    for f in out:
        if f.endswith(".R"):
            return Path(f)
    return None


# --------------------------------------------------------------------------- #
# deduplication.R
# --------------------------------------------------------------------------- #
dedup = Path("deduplication.R")

DED_TITLE_OLD = '''      # Clean Title
      clean_title = trimws(tolower(Title)) %>% gsub("[[:punct:]]$ ", "", .),'''
DED_TITLE_NEW = '''      # Clean Title. The previous pattern was "[[:punct:]]$ " - a space AFTER the
      # end-of-string anchor, which can never match. Trailing punctuation was
      # therefore never stripped, so "Some Title." and "Some Title" were treated
      # as two different papers.
      clean_title = trimws(tolower(Title)) %>% gsub("[[:punct:]]+$", "", .),'''

DED_FILL_ANCHOR = '''  # 2. Deduplicate with DOI (Using the new Master_DOI)
  with_doi <- df %>% filter(!is.na(DOI_clean) & DOI_clean != "")'''
DED_FILL_NEW = '''  # 1b. CROSS-FILL BEFORE CHOOSING A WINNER
  # Sources carry different fields for the same paper: EPMC may have an abstract
  # where OpenAlex has none, and only EPMC knows the PMCID. Picking one winner
  # discards whatever only the losing copies had, which is how records ended up
  # in the table with an empty abstract even though a sibling record had one.
  # Fill the gaps across each duplicate group first; for the abstract, take the
  # longest available, since sources truncate to different lengths.
  blank_to_na <- function(x) {
    x <- as.character(x)
    x[trimws(x) %in% c("", "NA", "NULL", "No abstract available")] <- NA_character_
    x
  }

  fill_within <- function(d, key, cols) {
    cols <- intersect(cols, names(d))
    if (!length(cols) || !key %in% names(d) || !nrow(d)) return(d)
    for (cl in cols) d[[cl]] <- blank_to_na(d[[cl]])
    d %>%
      group_by(across(all_of(key))) %>%
      mutate(across(all_of(cols), function(v) {
        present <- v[!is.na(v)]
        if (!length(present)) v else present[which.max(nchar(present))]
      })) %>%
      ungroup()
  }

  fill_cols <- c("Abstract", "PMCID", "IsOpenAccess")
  is_doi <- !is.na(df$DOI_clean) & df$DOI_clean != ""
  if (any(is_doi))  df[is_doi, ]  <- fill_within(df[is_doi, ],  "DOI_clean",   fill_cols)
  if (any(!is_doi)) df[!is_doi, ] <- fill_within(df[!is_doi, ], "clean_title", fill_cols)

''' + DED_FILL_ANCHOR

DED_DOI_OLD = '''  dedup_doi <- with_doi %>%
    mutate(
      # Robust factor matching (handles variations in Source names)
      Priority_Level = match(Source, priority_order, nomatch = 100)
    ) %>%
    arrange(Priority_Level) %>%
    filter(!duplicated(DOI_clean)) %>%
    select(-Priority_Level, -DOI_clean, -clean_title, -Master_DOI)'''
DED_DOI_NEW = '''  dedup_doi <- with_doi %>%
    mutate(
      # Robust factor matching (handles variations in Source names)
      Priority_Level = match(Source, priority_order, nomatch = 100),
      # OpenAlex, NIH and NSF all score 100, so ties were previously broken by
      # whichever future happened to return first - sometimes handing the row to
      # a copy with no abstract. Break the tie on content instead.
      Abstract_Rank = ifelse(is.na(blank_to_na(Abstract)), 1L, 0L)
    ) %>%
    arrange(Priority_Level, Abstract_Rank) %>%
    filter(!duplicated(DOI_clean)) %>%
    select(-Priority_Level, -Abstract_Rank, -DOI_clean, -clean_title, -Master_DOI)'''

DED_NA_OLD = '''  dedup_na <- na_doi %>%
    mutate(Priority_Level = match(Source, priority_order, nomatch = 100)) %>%
    arrange(Priority_Level) %>%
    filter(!duplicated(clean_title)) %>%
    select(-Priority_Level, -clean_title, -Master_DOI)'''
DED_NA_NEW = '''  dedup_na <- na_doi %>%
    mutate(
      Priority_Level = match(Source, priority_order, nomatch = 100),
      Abstract_Rank  = ifelse(is.na(blank_to_na(Abstract)), 1L, 0L)
    ) %>%
    arrange(Priority_Level, Abstract_Rank) %>%
    filter(!duplicated(clean_title)) %>%
    # DOI_clean was previously left in on this branch only, so bind_rows() below
    # produced a phantom DOI_clean column that was NA for every DOI-matched row.
    select(-Priority_Level, -Abstract_Rank, -DOI_clean, -clean_title, -Master_DOI)'''

edits += [
    (dedup, "clean_title regex", DED_TITLE_OLD, DED_TITLE_NEW),
    (dedup, "cross-fill block", DED_FILL_ANCHOR, DED_FILL_NEW),
    (dedup, "DOI dedup tie-break", DED_DOI_OLD, DED_DOI_NEW),
    (dedup, "title dedup tie-break", DED_NA_OLD, DED_NA_NEW),
]

# --------------------------------------------------------------------------- #
# EPMC extractor: keep pmcid + isOpenAccess
# --------------------------------------------------------------------------- #
epmc = find_file("get_epmc_data <- function", "R/extraction_utils.R", "R/data_extraction.R")

EPMC_VARS_OLD = '''      pub_date <- results_df$firstPublicationDate[i] %||% NA_character_'''
EPMC_VARS_NEW = '''      pub_date <- results_df$firstPublicationDate[i] %||% NA_character_

      # resultType="core" already returns these; they were being discarded.
      # PMCID makes open-access full text a single call instead of a lookup
      # plus a fetch, and isOpenAccess lets the UI say so.
      pmcid    <- results_df$pmcid[i] %||% NA_character_
      is_oa    <- results_df$isOpenAccess[i] %||% NA_character_'''

EPMC_ROW_OLD = '''        EPMC_ID = epmc_id,
        DOI = doi,
        Title = title,
        Abstract = abstract,'''
EPMC_ROW_NEW = '''        EPMC_ID = epmc_id,
        PMCID = pmcid,
        IsOpenAccess = is_oa,
        DOI = doi,
        Title = title,
        Abstract = abstract,'''

if epmc is not None:
    edits += [
        (epmc, "EPMC field extraction", EPMC_VARS_OLD, EPMC_VARS_NEW),
        (epmc, "EPMC row build", EPMC_ROW_OLD, EPMC_ROW_NEW),
    ]

# --------------------------------------------------------------------------- #
# app.R
# --------------------------------------------------------------------------- #
app = Path("app.R")

APP_SCHEMA_OLD = '''            primary_bacteria     = if ("primary_bacteria" %in% names(.)) primary_bacteria else NA_character_,'''
APP_SCHEMA_NEW = '''            primary_bacteria     = if ("primary_bacteria" %in% names(.)) primary_bacteria else NA_character_,
            # Only EPMC supplies these, so every other source needs them filled in
            PMCID                = if ("PMCID" %in% names(.)) PMCID else NA_character_,
            IsOpenAccess         = if ("IsOpenAccess" %in% names(.)) IsOpenAccess else NA_character_,'''

APP_ITEMKEY_OLD = '''            ItemKey = make_item_key(DOI, URL, Title)
          ) %>% # <--- CLOSE MUTATE AND PIPE'''
APP_ITEMKEY_NEW = '''            ItemKey = make_item_key(DOI, URL, Title),

            # Abstract-less records are kept, not dropped: a grant or a trial
            # with no abstract is still a real hit, and dropping them would make
            # the per-source counts dishonest. They are sorted below records that
            # do have one, and the cell says which source came up empty rather
            # than leaving a blank that reads like a bug.
            HasAbstract = !is.na(Abstract) &
                          !trimws(as.character(Abstract)) %in% c("", "NA", "NULL"),
            Abstract = ifelse(
              HasAbstract,
              as.character(Abstract),
              paste0("<span style=\\"opacity:0.45; font-style:italic;\\">",
                     "No abstract provided by ", Source, "</span>")
            )
          ) %>% # <--- CLOSE MUTATE AND PIPE'''

APP_SELECT_OLD = '''          select(Title, Abstract, Authors, AuthorAffiliations, PublicationDate, URL, DOI,
                 EPMC_ID, CORE_ID, NCTId, Source, Affiliations, AdverseEvents,
                 SeriousAdverseEvents, is_bioinformatics, primary_cell,
                 primary_virus, primary_bacteria, immune_cell_hits_combined, virus_hits_combined,
                 bacteria_hits_combined, SortDate, ItemKey)'''
APP_SELECT_NEW = '''          # Column order is a contract: the table's JS reads row[5] URL, row[6] DOI,
          # row[10] Source, row[17] primary_bacteria and row[22] ItemKey. New
          # columns are APPENDED (23, 24, 25) so none of those indices move.
          select(Title, Abstract, Authors, AuthorAffiliations, PublicationDate, URL, DOI,
                 EPMC_ID, CORE_ID, NCTId, Source, Affiliations, AdverseEvents,
                 SeriousAdverseEvents, is_bioinformatics, primary_cell,
                 primary_virus, primary_bacteria, immune_cell_hits_combined, virus_hits_combined,
                 bacteria_hits_combined, SortDate, ItemKey,
                 HasAbstract, PMCID, IsOpenAccess)'''

APP_OPTS_OLD = '''      options = dt_options,
      fillContainer = FALSE,'''
APP_OPTS_NEW = '''      # modifyList rather than editing dt_options, so the shared definition keeps
      # serving the other tables untouched. Sort abstract-bearing rows first,
      # then newest-first WITHIN each group - ordering by abstract alone would
      # bury recent grants at the bottom of the table.
      options = modifyList(dt_options, list(
        order = list(list(23, "desc"), list(21, "desc")),
        columnDefs = c(
          if (is.null(dt_options$columnDefs)) list() else dt_options$columnDefs,
          list(list(targets = c(23, 24, 25), visible = FALSE))
        )
      )),
      fillContainer = FALSE,'''

APP_COLNAMES_OLD = '''                   "Bacteria Hits", "SortDate", "ItemKey"),'''
APP_COLNAMES_NEW = '''                   "Bacteria Hits", "SortDate", "ItemKey",
                   "HasAbstract", "PMCID", "IsOpenAccess"),'''

edits += [
    (app, "defensive schema", APP_SCHEMA_OLD, APP_SCHEMA_NEW),
    (app, "ItemKey mutate", APP_ITEMKEY_OLD, APP_ITEMKEY_NEW),
    (app, "results select", APP_SELECT_OLD, APP_SELECT_NEW),
    (app, "DT options", APP_OPTS_OLD, APP_OPTS_NEW),
    (app, "DT colnames", APP_COLNAMES_OLD, APP_COLNAMES_NEW),
]

# --------------------------------------------------------------------------- #
# apply
# --------------------------------------------------------------------------- #
if not Path("app.R").exists():
    print("!! run from the repo root"); sys.exit(1)
if epmc is None:
    print("!! could not locate the file defining get_epmc_data"); sys.exit(1)
print(f"EPMC extractor: {epmc}")

by_file = {}
for path, label, old, new in edits:
    by_file.setdefault(path, []).append((label, old, new))

def tolerant(anchor):
    """Regex for `anchor` that ignores trailing whitespace at line ends.

    app.R carries trailing spaces on many lines ("DOI, " before the newline),
    so byte-exact anchors miss. Matching tolerantly is safer than stripping
    whitespace from the files, which would also reach inside app.R's
    multi-line JS string literals.
    """
    import re as _re
    return _re.compile(
        r"[ \t]*\n".join(_re.escape(l.rstrip()) for l in anchor.split("\n")) + r"[ \t]*"
    )


problems = []
for path, group in by_file.items():
    if not path.exists():
        problems.append(f"{path}: missing"); continue
    src = path.read_text(encoding="utf-8")
    for label, old, _ in group:
        n = len(tolerant(old).findall(src))
        if n != 1:
            problems.append(f"{path}: '{label}' found {n} times, expected 1")

if problems:
    print("\n".join("  !! " + p for p in problems))
    print("\nNothing written.")
    sys.exit(1)

for path, group in by_file.items():
    print(f"  ok {path}: {len(group)} block(s) matched")

if CHECK:
    print("\nAll blocks matched (check only, nothing written).")
    sys.exit(0)

for path, group in by_file.items():
    src = path.read_text(encoding="utf-8")
    bak = path.with_suffix(path.suffix + ".absbak")
    if not bak.exists():
        bak.write_text(src, encoding="utf-8")
    for label, old, new in group:
        src = tolerant(old).sub(lambda _m, _n=new: _n, src, count=1)
    path.write_text(src, encoding="utf-8")
    print(f"  wrote {path}")

print("\nDone.")
