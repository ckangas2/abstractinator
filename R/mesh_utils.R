# R/mesh_utils.R
# Classify MeSH descriptors by position in the MeSH tree, so "is this a virus"
# is answered by taxonomy rather than a hand-maintained alias list.
#
#   B03*          -> bacterium
#   B04*          -> virus (bacteriophages included, correctly)
#   A11* AND A15* -> immune cell. A11 alone is every cell type (epithelial
#                    cells are A11.436); also requiring A15 (Hemic and Immune
#                    Systems) narrows it to immune lineages.
#
# NLM retired the bulk mtrees files, so tree numbers and entry terms come from
# the per-descriptor endpoints and are cached on disk. Only descriptors we
# actually encounter get looked up, and MeSH does not change within a year, so
# the cache goes cold quickly and then works offline.

MESH_UA <- "Abstractinator/2.0 (+https://abstractinator.me)"

mesh_cache_dir <- function() {
  base <- if (exists("CACHE_DIR", envir = globalenv())) {
    get("CACHE_DIR", envir = globalenv())
  } else {
    file.path(".cache", "s3_mimic")
  }
  file.path(base, "mesh")
}

# Hashed filename: descriptor labels contain slashes, commas and quotes, none
# of which belong in a path.
.mesh_path <- function(label) {
  file.path(mesh_cache_dir(),
            paste0(digest::digest(tolower(trimws(label)), algo = "md5"), ".rds"))
}

# One cached record per descriptor: tree numbers plus entry terms (synonyms).
# Negative results are cached too, so a descriptor outside our axes is not
# re-fetched on every search.
# Process-lifetime memo in front of the disk cache. Descriptors repeat heavily
# across a result set -- "Animals" and "Mice" appear in hundreds of records --
# and a readRDS per row per descriptor is thousands of file reads per search.
.mesh_mem <- new.env(parent = emptyenv())

mesh_lookup <- function(label, use_cache = TRUE) {
  label <- trimws(as.character(label))
  if (length(label) != 1 || is.na(label) || !nzchar(label)) {
    return(list(trees = character(0), terms = character(0)))
  }
  key <- tolower(label)
  if (use_cache && exists(key, envir = .mesh_mem, inherits = FALSE)) {
    return(get(key, envir = .mesh_mem, inherits = FALSE))
  }
  if (use_cache) {
    p <- .mesh_path(label)
    if (file.exists(p)) {
      hit <- tryCatch(readRDS(p), error = function(e) NULL)
      if (!is.null(hit)) {
        assign(key, hit, envir = .mesh_mem)
        return(hit)
      }
    }
  }

  rec <- tryCatch({
    r <- httr::GET("https://id.nlm.nih.gov/mesh/lookup/descriptor",
                   query = list(label = label, match = "exact", limit = 1),
                   httr::user_agent(MESH_UA), httr::timeout(15))
    if (httr::http_error(r)) stop("lookup failed")
    hits <- jsonlite::fromJSON(httr::content(r, "text", encoding = "UTF-8"))
    if (length(hits) == 0 || is.null(hits$resource)) stop("no descriptor")
    did <- sub("^.*/", "", hits$resource[1])

    r2 <- httr::GET(sprintf("https://id.nlm.nih.gov/mesh/%s.json", did),
                    httr::user_agent(MESH_UA), httr::timeout(15))
    trees <- if (httr::http_error(r2)) character(0) else {
      j <- jsonlite::fromJSON(httr::content(r2, "text", encoding = "UTF-8"),
                              simplifyVector = FALSE)
      if (is.null(j$treeNumber)) character(0) else sub("^.*/", "", unlist(j$treeNumber, use.names = FALSE))
    }

    r3 <- httr::GET("https://id.nlm.nih.gov/mesh/lookup/details",
                    query = list(descriptor = did),
                    httr::user_agent(MESH_UA), httr::timeout(15))
    terms <- if (httr::http_error(r3)) character(0) else {
      j3 <- jsonlite::fromJSON(httr::content(r3, "text", encoding = "UTF-8"),
                               simplifyVector = FALSE)
      tl <- vapply(j3$terms %||% list(), function(t) t$label %||% NA_character_, character(1))
      tl[!is.na(tl) & nzchar(tl)]
    }

    list(trees = trees, terms = unique(c(label, terms)), fetched = Sys.Date())
  }, error = function(e) list(trees = character(0), terms = label, fetched = Sys.Date()))

  d <- mesh_cache_dir()
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  tryCatch(saveRDS(rec, .mesh_path(label)), error = function(e) invisible(NULL))
  assign(key, rec, envir = .mesh_mem)
  Sys.sleep(0.1)
  rec
}

# Is this descriptor already cached? Used to bound how much network work a
# single search will do.
mesh_is_cached <- function(label) {
  exists(tolower(trimws(label)), envir = .mesh_mem, inherits = FALSE) ||
    file.exists(.mesh_path(label))
}

mesh_axis <- function(label, rec = NULL) {
  if (is.null(rec)) rec <- mesh_lookup(label)
  tn <- rec$trees
  if (length(tn) == 0) return(NA_character_)
  if (any(startsWith(tn, "B04"))) return("virus")
  if (any(startsWith(tn, "B03"))) return("bacteria")
  if (any(startsWith(tn, "A11")) && any(startsWith(tn, "A15"))) return("cell")
  NA_character_
}

# Map a MeSH descriptor onto the project's own category names, so the display
# vocabulary stays curated ("Listeria", "T cell") while MeSH decides what the
# organism actually is. Entry terms are tried as well as the preferred label,
# which is what resolves MeSH's "Herpesvirus 1, Human" to an existing
# "Herpes Simplex Virus" category via its synonym "HSV-1" -- without that,
# the same virus would occupy two separate buckets.
#
# Falls back to the MeSH descriptor itself when nothing matches, so coverage
# grows automatically instead of silently failing (how norovirus went untagged).
mesh_to_category <- function(descriptor, regex_list, rec = NULL) {
  descriptor <- as.character(descriptor)
  if (length(descriptor) != 1 || is.na(descriptor) || !nzchar(trimws(descriptor))) {
    return(NA_character_)
  }
  if (is.null(rec)) rec <- mesh_lookup(descriptor)
  cands <- unique(c(descriptor, rec$terms))
  cands <- gsub("[-/]+", " ", tolower(trimws(cands)))

  # Most specific match wins, not the first found: iteration order would
  # otherwise decide between "T cell" and "CD8+ T cell". Matched-alias length
  # is a reasonable proxy for specificity.
  best <- NA_character_; best_len <- -1L
  for (nm in names(regex_list)) {
    for (cd in cands) {
      m <- regmatches(cd, regexpr(regex_list[[nm]], cd, perl = TRUE))
      if (length(m) && nzchar(m[1]) && nchar(m[1]) > best_len) {
        best <- nm; best_len <- nchar(m[1])
      }
    }
  }
  if (!is.na(best)) return(best)
  descriptor
}
