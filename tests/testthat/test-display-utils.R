# Display safety: text from external databases must never inject markup,
# while harmless formatting (italics, superscripts, line breaks) survives.

test_that("scripts are removed entirely, including their contents", {
  expect_equal(sanitize_html('Nice<script>alert("x")</script> paper'), "Nice paper")
  expect_equal(sanitize_html("&lt;script&gt;alert(1)&lt;/script&gt;"), "")
})

test_that("dangerous tags and attributes are stripped", {
  expect_equal(sanitize_html("<img src=x onerror=alert(1)>text"), "text")
  expect_equal(sanitize_html('<i onmouseover="alert(1)">hover</i>'), "<i>hover</i>")
})

test_that("basic formatting survives", {
  expect_equal(sanitize_html("CD8<sup>+</sup> T cells"), "CD8<sup>+</sup> T cells")
  expect_equal(sanitize_html("Role of <i>HSV</i>"), "Role of <i>HSV</i>")
  expect_equal(sanitize_html("Affil<br/>two"), "Affil<br>two")
})

test_that("publisher XML and pre-escaped markup are handled", {
  expect_equal(
    sanitize_html("<jats:title>Abstract</jats:title><jats:p>Background: <jats:italic>HSV</jats:italic> works</jats:p>"),
    "Abstract Background: <i>HSV</i> works"
  )
  expect_equal(sanitize_html("&lt;i&gt;Escaped&lt;/i&gt; italics"), "<i>Escaped</i> italics")
  expect_equal(sanitize_html("<p>Para one</p><p>Para two</p>"), "Para one Para two")
})

test_that("stray symbols become text, not markup", {
  expect_equal(sanitize_html("p < 0.05 and q > 3, A & B"), "p &lt; 0.05 and q &gt; 3, A &amp; B")
})

test_that("sanitizing is idempotent and keeps NA", {
  inputs <- c("Role of <i>HSV</i>", "A & B &#8211; dash", "<p>x</p>", NA)
  once <- sanitize_html(inputs)
  expect_identical(sanitize_html(once), once)
  expect_true(is.na(once[4]))
})

test_that("only plain http(s) links survive", {
  expect_equal(sanitize_url("https://doi.org/10.1/abc"), "https://doi.org/10.1/abc")
  expect_true(is.na(sanitize_url("javascript:alert(1)")))
  expect_true(is.na(sanitize_url('https://x.org/"onmouseover')))
})

test_that("exports get plain text", {
  expect_equal(html_to_text("A &amp; <i>B</i><br>C"), "A & B; C")
})

test_that("item keys are stable and distinguish DOI-less records", {
  k1 <- make_item_key(NA, NA, "Grant A")
  expect_identical(k1, make_item_key(NA, NA, "Grant A"))
  expect_false(identical(k1, make_item_key(NA, NA, "Grant B")))
  expect_length(make_item_key(c("10.1/a", "10.1/b"), c(NA, NA), c("x", "y")), 2)
})

# --- Markdown export ----------------------------------------------------------

test_that("the Markdown export lists each item with its metadata, tags and abstract", {
  items <- list(
    list(Title = "Tim-3 marks exhausted NK cells", Authors = "Smith J; Doe A",
         PublicationDate = "2025-03-14", Source = "Europe PMC",
         DOI = "10.1016/S0140-6736(20)30183-5", URL = "https://doi.org/10.1016/S0140-6736(20)30183-5",
         Abstract = "NK cells in chronic HBV.\nSecond paragraph.",
         primary_cell = "Natural killer cell", primary_virus = "Hepatitis B Virus",
         primary_bacteria = "Non-descript"),
    list(Title = "A trial", URL = "https://clinicaltrials.gov/study/NCT1", DOI = NA,
         Abstract = NA)
  )
  md <- reading_list_markdown(items, exported = as.Date("2026-11-07"))
  txt <- paste(md, collapse = "\n")

  expect_match(txt, "Exported 2026-11-07 from https://abstractinator.me · 2 items", fixed = TRUE)
  expect_match(txt, "copyright remains with the authors and publishers", fixed = TRUE)
  expect_match(txt, "## 1. Tim-3 marks exhausted NK cells", fixed = TRUE)
  # parentheses in the DOI are encoded so the link survives
  expect_match(txt, "(https://doi.org/10.1016/S0140-6736%2820%2930183-5)", fixed = TRUE)
  expect_match(txt, "**Cell:** Natural killer cell · **Virus:** Hepatitis B Virus", fixed = TRUE)
  expect_false(grepl("Non-descript", txt, fixed = TRUE))
  expect_true(all(c("> NK cells in chronic HBV.", "> Second paragraph.") %in% md))
  # the DOI link already covers item 1's URL; item 2 has no DOI, so its page is linked
  expect_equal(sum(grepl("[Source page]", md, fixed = TRUE)), 1)
  expect_match(txt, "## 2. A trial", fixed = TRUE)
})

test_that("the Markdown export treats third-party text as text", {
  md <- reading_list_markdown(list(list(
    Title = "<img src=x onerror=alert(1)> *bold* [link](javascript:x)",
    URL = "javascript:alert(1)")))
  txt <- paste(md, collapse = "\n")
  expect_match(txt, "\\<img src=x onerror=alert(1)\\> \\*bold\\* \\[link\\](javascript:x)", fixed = TRUE)
  expect_false(grepl("[Source page]", txt, fixed = TRUE))   # non-http URL dropped
})

test_that("the Markdown export records where each item came from", {
  md <- reading_list_markdown(list(list(
    Title = "Interferon and CD8 T cells", FoundBy = "interferon CD8",
    RetrievedAt = "2026-11-07 20:15 UTC", MergedFrom = "OpenAlex: 10.1/x; CORE: 10.1/x")),
    exported = as.Date("2026-11-07"), versions = c(app = "2.2.0", aliases = "abc123def0"))
  txt <- paste(md, collapse = "\n")
  expect_match(txt, "Abstractinator 2.2.0 · tag vocabulary abc123def0", fixed = TRUE)
  expect_match(txt, "Found by the search \u201cinterferon CD8\u201d, databases queried 2026-11-07 20:15 UTC.", fixed = TRUE)
  expect_match(txt, "*Also found as:* OpenAlex: 10.1/x; CORE: 10.1/x", fixed = TRUE)
})

test_that("an empty reading list exports a note, not an error", {
  expect_match(paste(reading_list_markdown(list()), collapse = "\n"), "empty", fixed = TRUE)
})

test_that("the website's trial date label is rebuilt from the separate fields", {
  expect_equal(
    trial_date_label(start  = c("2024-01-12", "2019-03", NA,         "2022-05-01"),
                     end    = c("2027-06-30", "2021-11", "2025-01",  NA),
                     status = c("RECRUITING", "COMPLETED", "WITHDRAWN", NA)),
    c("Start: 2024-01-12 | End: Ongoing | Status: RECRUITING",
      "Start: 2019-03 | End: 2021-11 | Status: COMPLETED",
      "End: 2025-01 | Status: WITHDRAWN",
      "Start: 2022-05-01"))
})
