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
