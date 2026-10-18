#!/usr/bin/env python3
"""Trial phase: carry it through from ClinicalTrials.gov, summarise it.

  clinicaltrials.gov_extraction.R
    - read protocolSection.designModule.phases, which arrives in the SAME
      response as the modules already being read - no extra request
    - normalise PHASE2 -> "Phase 2", EARLY_PHASE1 -> "Early Phase 1",
      PHASE1/PHASE2 -> "Phase 1/Phase 2"
  app.R
    - a line under the Deduplicatinator table saying what the trials in this
      result set actually are

Phase deliberately does NOT enter the results-table schema: the summary reads
from rv$initial_extracted_data, which keeps every column, so no new hidden
column and no index shift for the badge JS.

Run from the repo root.  --check reports without writing.
"""
import re
import sys
from pathlib import Path

CHECK = "--check" in sys.argv


def tol(a):
    return re.compile(r"[ \t]*\n".join(re.escape(l.rstrip()) for l in a.split("\n")) + r"[ \t]*")


ctg = Path("clinicaltrials.gov_extraction.R")
app = Path("app.R")

EDITS = [
# ---------------------------------------------------------------- extractor
(ctg, "read phases",
'''    overall_statuses <- studies_chunk$protocolSection$statusModule$overallStatus''',
'''    overall_statuses <- studies_chunk$protocolSection$statusModule$overallStatus

    # Phase arrives in the same response - designModule sits beside the status
    # and description modules above - so this costs no extra request. It is a
    # list column: a trial can be registered as PHASE1/PHASE2, and observational
    # studies legitimately carry no phase at all.
    phases_list <- studies_chunk$protocolSection$designModule$phases
    if (is.null(phases_list)) phases_list <- vector("list", nrow(studies_chunk))'''),

(ctg, "phase formatter",
'''    # Process Row-by-Row for this batch
    batch_df <- map_dfr(1:nrow(studies_chunk), function(i) {''',
'''    # "PHASE2" -> "Phase 2"; "EARLY_PHASE1" -> "Early Phase 1"; a registration
    # of c("PHASE1","PHASE2") -> "Phase 1/Phase 2". CT.gov also uses the literal
    # string "NA" for studies with no phase, which is not the same as missing
    # and would otherwise read as a phase called NA.
    format_ctgov_phase <- function(x) {
      if (is.null(x) || length(x) == 0) return(NA_character_)
      x <- toupper(trimws(as.character(x)))
      x <- x[nzchar(x) & x != "NA"]
      if (!length(x)) return(NA_character_)
      pretty <- vapply(x, function(v) {
        if (identical(v, "EARLY_PHASE1")) "Early Phase 1"
        else if (grepl("^PHASE[0-9]$", v)) paste("Phase", sub("^PHASE", "", v))
        else gsub("_", " ", v)
      }, character(1), USE.NAMES = FALSE)
      paste(unique(pretty), collapse = "/")
    }

    # Process Row-by-Row for this batch
    batch_df <- map_dfr(1:nrow(studies_chunk), function(i) {'''),

(ctg, "extract phase per row",
'''      stat   <- if (!is.null(overall_statuses[i])) overall_statuses[i] else NA_character_''',
'''      stat   <- if (!is.null(overall_statuses[i])) overall_statuses[i] else NA_character_
      phase_val <- format_ctgov_phase(
        tryCatch(phases_list[[i]], error = function(e) NULL)
      )'''),

(ctg, "phase into the tibble",
'''        NCTId = id_val,''',
'''        NCTId = id_val,
        Phase = phase_val,'''),

# --------------------------------------------------------------------- app.R
(app, "phase summary output",
'''      output$deduplicationSummaryContent <- renderUI({
        tagList(
          h4("Deduplicatinator"),
          DT::dataTableOutput("deduplicationTable"),
          uiOutput("searchTime")
        )
      })''',
'''      # The table above counts duplicates. This says what the trials actually
      # ARE, which is the question someone has when they see "Trials 50" - and
      # it is read from the pre-dedup frame, so Phase never has to enter the
      # results-table column contract.
      output$trialPhaseSummary <- renderUI({
        df <- rv$initial_extracted_data
        if (is.null(df) || !"Source" %in% names(df)) return(NULL)
        tr <- df[!is.na(df$Source) & df$Source == "clinicaltrials.gov", , drop = FALSE]
        if (nrow(tr) == 0) return(NULL)

        ph <- if ("Phase" %in% names(tr)) as.character(tr$Phase) else rep(NA_character_, nrow(tr))
        # Observational studies have no phase by design; say so rather than
        # hiding them, or the counts will not add up to the trial total.
        ph[is.na(ph) | !nzchar(trimws(ph))] <- "Not applicable"

        counts <- table(ph)
        nm <- names(counts)
        counts <- counts[order(nm == "Not applicable", nm)]

        div(
          style = "margin-top: 12px; color: #aaa; font-size: 0.9em;",
          strong(sprintf("Trials by phase (%d): ", nrow(tr))),
          paste(sprintf("%s %d", names(counts), as.integer(counts)),
                collapse = "   \\u00b7   ")
        )
      })

      output$deduplicationSummaryContent <- renderUI({
        tagList(
          h4("Deduplicatinator"),
          DT::dataTableOutput("deduplicationTable"),
          uiOutput("trialPhaseSummary"),
          uiOutput("searchTime")
        )
      })'''),
]

for path, label, old, _ in EDITS:
    if not path.exists():
        print(f"!! {path} missing"); sys.exit(1)

problems = []
for path, label, old, _ in EDITS:
    n = len(tol(old).findall(path.read_text(encoding="utf-8")))
    if n != 1:
        problems.append(f"{path}: '{label}' found {n} times, expected 1")
if problems:
    print("\n".join("  !! " + p for p in problems)); print("\nNothing written."); sys.exit(1)

for path, label, _, _ in EDITS:
    print(f"  ok {path}: {label}")

if CHECK:
    print("\nAll blocks matched (check only, nothing written).")
    sys.exit(0)

for path in {p for p, *_ in EDITS}:
    b = path.with_suffix(path.suffix + ".phasebak")
    if not b.exists():
        b.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")

for path, label, old, new in EDITS:
    s = path.read_text(encoding="utf-8")
    path.write_text(tol(old).sub(lambda _m, _n=new: _n, s, count=1), encoding="utf-8")

print("\nDone.")
