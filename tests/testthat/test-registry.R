# The program registry's read side (R/registry.R). alias_key() must agree with
# tracker/registry.py, so both are tested against tracker/tests/alias_keys.tsv.

source(file.path(repo_root, "R", "registry.R"))

test_that("alias_key passes every shared case in tracker/tests/alias_keys.tsv", {
  # Read verbatim: no quoting, no NA strings, no whitespace stripping, so a
  # case like " (LN-144) " reaches alias_key exactly as written.
  cases <- utils::read.delim(file.path(repo_root, "tracker", "tests", "alias_keys.tsv"),
                             quote = "", comment.char = "", encoding = "UTF-8",
                             colClasses = "character", na.strings = character(0),
                             strip.white = FALSE)
  expect_gt(nrow(cases), 10)
  got <- alias_key(cases$name)
  for (i in seq_len(nrow(cases))) {
    expect_identical(enc2utf8(got[i]), enc2utf8(cases$key[i]), info = cases$note[i])
  }
})

test_that("alias_key is vectorised and safe on missing values", {
  expect_identical(alias_key(c("MRTX-1133", NA, "---")), c("MRTX1133", "", ""))
  expect_identical(alias_key(character(0)), character(0))
})

test_that("a missing registry database is a 503, not an error", {
  out <- registry_program(file.path(tempdir(), "no-such-registry.sqlite"), "T-VEC")
  expect_equal(out$status, 503L)
  expect_match(out$body$error, "not been built")
})

test_that("/program and /changes resolve IDs, names and merges", {
  skip_if_not_installed("RSQLite")
  skip_if_not_installed("DBI")
  path <- tempfile(fileext = ".sqlite")
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  DBI::dbWriteTable(con, "meta", data.frame(
    key = c("schema_version", "registry_release", "latest_snapshot"),
    value = c("3", "2026-11-11+abc", "2026-11-09")))
  DBI::dbWriteTable(con, "virus", data.frame(
    axp_id = "AXP000001", role = "oncolytic", virus_family = "Orthoherpesviridae",
    virus = "herpes simplex virus 1", ncbi_taxon = "10298", strain = "JS1",
    replication = "conditionally_replicating", modifications = "ICP34.5 and ICP47 deleted",
    transgenes = "CSF2", route = "intratumoral", carrier = "", evidence_url = "https://example.org"))
  DBI::dbWriteTable(con, "approval", data.frame(
    axp_id = c("AXP000001", "AXP000001"), agency = c("FDA", "EMA"), region = c("US", "EU"),
    date = c("2015-10-27", "2015-12-16"), status = "approved", brand = "Imlygic",
    indication = "melanoma", evidence_url = "https://example.org"))
  DBI::dbWriteTable(con, "program", data.frame(
    axp_id = c("AXP000001", "AXP000002", "AXP000003"),
    status = c("active", "merged", "active"),
    replaced_by = c("", "AXP000001", ""),
    preferred_name = c("talimogene laherparepvec", "OncoVEX", "other"),
    modality = c("Oncolytic virus", "Oncolytic virus", "CAR-T cell therapy"),
    platform = "", targets = c("CSF2; TNF", "", ""), originator = "", sponsor = "",
    ncit = "", wikidata = "", unii = "", entry_version = 1L,
    created = "", updated = "", notes = ""))
  DBI::dbWriteTable(con, "alias", data.frame(
    axp_id = c("AXP000001", "AXP000001", "AXP000001", "AXP000003"),
    alias = c("talimogene laherparepvec", "T-VEC", "Shared", "shared"),
    alias_key = c("TALIMOGENELAHERPAREPVEC", "TVEC", "SHARED", "SHARED"),
    alias_type = c("preferred", "code", "code", "code"),
    source = "", source_record = "", licence = "", evidence_url = "",
    ambiguous = c(0L, 0L, 1L, 1L)))
  DBI::dbWriteTable(con, "trial", data.frame(
    nct_id = "NCT00000001", snapshot_date = "2026-11-09", brief_title = "A trial",
    overall_status = "COMPLETED", why_stopped = "", study_type = "INTERVENTIONAL",
    lead_sponsor = "Amgen", phases = "PHASE3", start_date = "2009-04",
    primary_completion_date = "2012-01", completion_date = "2014-01",
    enrollment_count = NA_integer_, has_results = 1L, last_update_post_date = "",
    first_seen = "2026-11-02", conditions = '["Melanoma"]'))
  # Paper 1004 is linked but its details were never fetched (no paper row).
  DBI::dbWriteTable(con, "paper", data.frame(
    pmid = c("1001", "1002", "1003"), title = c("Old trial", "New case", "Maybe"), journal = "J Clin Oncol",
    year = c(2009L, 2021L, 2023L), kind = c("clinical_trial", "case_report", "clinical_other"),
    doi = NA_character_, pmcid = NA_character_))
  DBI::dbWriteTable(con, "paper_link", data.frame(
    axp_id = "AXP000001", pmid = c("1001", "1002", "1003", "1004"),
    method = c("trial_reference", "title", "abstract", "title"),
    matched = c("NCT00000001", "T-VEC", "T-VEC", "Imlygic"),
    nct_id = c("NCT00000001", NA, NA, NA), confidence = c(0.9, 0.85, 0.6, 0.85),
    status = c("auto", "auto", "candidate", "auto")))
  DBI::dbWriteTable(con, "grant_award", data.frame(
    core_project_num = c("R01CA000001", "R21CA000002"), title = c("Older grant", "Newer grant"),
    org = "Univ", pi = "SMITH, JANE", first_fy = c(2010L, 2019L), last_fy = c(2014L, 2022L),
    url = c("https://reporter.nih.gov/project-details/1", "https://reporter.nih.gov/project-details/2")))
  DBI::dbWriteTable(con, "grant_link", data.frame(
    axp_id = "AXP000001", core_project_num = c("R01CA000001", "R21CA000002", "R01CA000003"),
    method = c("title", "terms", "abstract"), matched = "T-VEC", confidence = c(0.85, 0.6, 0.6),
    status = c("auto", "candidate", "candidate")))
  DBI::dbWriteTable(con, "trial_link", data.frame(
    nct_id = "NCT00000001", axp_id = "AXP000001", method = "intervention_name",
    matched = "T-VEC", confidence = 0.95, status = "auto"))
  DBI::dbWriteTable(con, "change_event", data.frame(
    event_id = c("AXE-2026-11-09-NCT00000001-trial.status_changed",
                 "AXE-2026-11-09-NCT00000001-trial.sponsor_changed"),
    snapshot_date = "2026-11-09", previous_date = "2026-11-02",
    nct_id = "NCT00000001",
    type = c("trial.status_changed", "trial.sponsor_changed"),
    significance = c("major", "minor"),
    field = c("overall_status", "lead_sponsor"), before = c("ACTIVE_NOT_RECRUITING", "BioVex"),
    after = c("COMPLETED", "Amgen"), axp_ids = '["AXP000001"]'))
  DBI::dbDisconnect(con)

  by_name <- registry_program(path, "t vec")
  expect_equal(by_name$status, 200L)
  expect_equal(by_name$body$program$axp_id, "AXP000001")
  expect_equal(as.character(by_name$body$program$targets), c("CSF2", "TNF"))
  expect_true(is.na(by_name$body$merged_from))
  expect_equal(by_name$body$trials$link_method, "intervention_name")
  expect_equal(by_name$body$virus$virus, "herpes simplex virus 1")
  expect_equal(as.character(by_name$body$virus$transgenes), "CSF2")
  expect_s3_class(by_name$body$virus$route, "AsIs")
  expect_equal(by_name$body$approvals$agency, c("FDA", "EMA"))
  other <- registry_program(path, "AXP000003")
  expect_true(is.na(other$body$virus))
  expect_equal(nrow(other$body$approvals), 0L)

  # Papers: auto links first, then newest; a link without details has nulls.
  papers <- by_name$body$papers
  expect_equal(papers$pmid, c("1002", "1001", "1004", "1003"))
  expect_equal(papers$link_status, c("auto", "auto", "auto", "candidate"))
  expect_equal(papers$link_method[2], "trial_reference")
  expect_equal(papers$nct_id[2], "NCT00000001")
  expect_true(is.na(papers$nct_id[1]))
  expect_true(is.na(papers$title[3]))
  expect_equal(papers$kind[1], "case_report")
  expect_equal(papers$year[1:2], c(2021L, 2009L))
  expect_named(papers, c("pmid", "title", "journal", "year", "kind", "link_method",
                         "link_confidence", "link_status", "nct_id"))
  # Grants: newest first; a link without details goes last, with nulls.
  grants <- by_name$body$grants
  expect_equal(grants$core_project_num, c("R21CA000002", "R01CA000001", "R01CA000003"))
  expect_equal(grants$first_fy[1:2], c(2019L, 2010L))
  expect_true(is.na(grants$title[3]))
  expect_named(grants, c("core_project_num", "title", "org", "pi", "first_fy", "last_fy", "url",
                         "link_method", "link_confidence", "link_status"))
  expect_equal(nrow(other$body$papers), 0L)
  expect_equal(nrow(other$body$grants), 0L)
  # As the API serialises them (unboxedJSON, na = "null"): null, and [] when none.
  json <- as.character(jsonlite::toJSON(by_name$body, auto_unbox = TRUE, na = "null"))
  expect_match(json, '"pmid":"1004","title":null', fixed = TRUE)
  other_json <- as.character(jsonlite::toJSON(other$body, auto_unbox = TRUE, na = "null"))
  expect_match(other_json, '"papers":[]', fixed = TRUE)
  expect_match(other_json, '"grants":[]', fixed = TRUE)
  expect_true(by_name$body$trials$has_results)
  expect_length(by_name$body$recent_changes, 2)
  expect_equal(by_name$body$recent_changes[[1]]$significance, "major")
  expect_equal(by_name$body$recent_changes[[1]]$programs[[1]]$preferred_name,
               "talimogene laherparepvec")

  merged <- registry_program(path, "axp000002")
  expect_equal(merged$body$program$axp_id, "AXP000001")
  expect_equal(merged$body$merged_from, "AXP000002")

  ambiguous <- registry_program(path, "SHARED")
  expect_equal(ambiguous$status, 200L)
  expect_true(is.na(ambiguous$body$program))
  expect_setequal(ambiguous$body$candidates$axp_id, c("AXP000001", "AXP000003"))

  expect_equal(registry_program(path, "nothing like it")$status, 404L)

  everything <- registry_changes(path, since = "2026-11-01")
  expect_equal(everything$status, 200L)
  expect_equal(everything$body$count, 2L)
  expect_equal(everything$body$latest_snapshot, "2026-11-09")
  major <- registry_changes(path, since = "2026-11-01", significance = "major")
  expect_equal(major$body$count, 1L)
  expect_equal(registry_changes(path, since = "2026-11-10")$body$count, 0L)
  expect_equal(registry_changes(path, since = "2026-11-01", program = "T-VEC")$body$count, 2L)
  expect_equal(registry_changes(path, since = "2026-11-01", program = "AXP000003")$body$count, 0L)
  expect_equal(registry_changes(path, since = "2026-11-01", program = "nothing like it")$status, 404L)
  expect_equal(registry_changes(path, since = "2026-11-01", modality = "CAR-T cell therapy")$body$count, 0L)
  expect_equal(registry_changes(path, since = "2026-11-01", modality = "Oncolytic virus")$body$count, 2L)
  expect_equal(registry_changes(path, since = "2026-11-01", program = "shared")$status, 400L)
})

test_that("the API reads the database the Python build writes", {
  # A contract test across the two languages: tracker/build_registry.py
  # builds from the real registry/*.tsv, and R/registry.R must read it.
  skip_if_not_installed("RSQLite")
  py <- Sys.which("python3")
  skip_if(!nzchar(py), "python3 not available")
  out <- tempfile(fileext = ".sqlite")
  status <- system2(py, c(shQuote(file.path(repo_root, "tracker", "build_registry.py")),
                          "--registry", shQuote(file.path(repo_root, "registry")),
                          "--snapshots", shQuote(file.path(tempdir(), "no-snapshots.sqlite")),
                          "--out", shQuote(out), "--page", "''", "--site", "''", "--evidence", "''"),
                    stdout = FALSE, stderr = FALSE)
  expect_equal(status, 0L)
  tvec <- registry_program(out, "T-VEC")
  expect_equal(tvec$status, 200L)
  expect_equal(tvec$body$program$preferred_name, "talimogene laherparepvec")
  expect_true("Imlygic" %in% tvec$body$aliases$alias)
  expect_equal(registry_program(out, "mrtx-1133")$body$program$preferred_name, "MRTX1133")
  expect_true(is.data.frame(tvec$body$papers))
  expect_true(is.data.frame(tvec$body$grants))
  expect_equal(registry_changes(out, since = "2026-01-01")$body$count, 0L)
})
