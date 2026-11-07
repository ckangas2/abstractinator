# app/dt_options.R
#
# Options for the results table (DT). The JavaScript renderers read columns by
# position, so the column order set in app/server/search.R is a contract; see
# the comment there before adding or moving a column.

dt_options <- list(
  pageLength = 25,
  lengthMenu = c(10, 25, 50, 100),
  scrollX = TRUE,
  scrollY = FALSE,
  autoWidth = TRUE,
  
  # 1. Custom DOM Structure
  # <"dt-top-toolbar"lf> = Puts Length (l) and Filter (f) in a custom div class "dt-top-toolbar"
  # r = Processing
  # t = Table
  # i = Info
  # p = Pagination
  dom = '<"dt-top-toolbar"lf>rtip', 
  
  # 2. Custom Labels (Language)
  language = list(
    search = "_INPUT_",            # Removes the "Search:" label (we'll use placeholder)
    searchPlaceholder = "Filter results...", # Adds placeholder text inside the box
    lengthMenu = "Show _MENU_"     # Shortens "Show 10 entries" to just "Show 10"
  ), 
  columnDefs = list(
    list(
      targets = 0, 
      render = JS(
        "function(data, type, row, meta) {
          if (type === 'display') {
            var cleanTitle = data.replace(/<\\/?i>/gi, '');
            var url = row[5]; 
            var doi = row[6]; 
            var source = row[10]; // Source is at index 10
            
            // --- 1. BADGE LOGIC ---
            var badge = '';
            
            // A. Check for Preprint (Orange)
            if (source && (source.toLowerCase().includes('biorxiv') || source.toLowerCase().includes('medrxiv') || source.toLowerCase().includes('preprint'))) {
               badge = ' <span style=\"color: #ffab40; font-weight: bold; font-size: 0.75em; border: 1px solid #ffab40; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">PREPRINT</span>';
            }
            // B. Check for Patent (Red)
            else if (source && (source.toLowerCase().includes('patent') || source.toLowerCase().includes('uspto'))) {
               badge = ' <span style=\"color: #ff5252; font-weight: bold; font-size: 0.75em; border: 1px solid #ff5252; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">PATENT</span>';
            }
            // C. Check for NIH Grant (Blue)
            else if (source && source.toLowerCase().includes('nih')) {
               badge = ' <span style=\"color: #4da6ff; font-weight: bold; font-size: 0.75em; border: 1px solid #4da6ff; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">NIH GRANT</span>';
            }
            // D. Check for NSF Grant (Green)
            else if (source && source.toLowerCase().includes('nsf')) {
               badge = ' <span style=\"color: #4caf50; font-weight: bold; font-size: 0.75em; border: 1px solid #4caf50; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">NSF GRANT</span>';
            }
            
            // E. Open access (teal): tells the reader they can actually read
            // this one. Teal rather than green because #4caf50 is already NSF,
            // and orange - the OA movement's own colour - is already PREPRINT.
            var oa = row[25];
            if (oa === 'Y') {
               badge += ' <span style=\"color: #00bfa5; font-weight: bold; font-size: 0.75em; border: 1px solid #00bfa5; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">OPEN ACCESS</span>';
            }

            // F. Bacteria tag (purple), shown alongside any source badge
            var bacteria = row[17];
            if (bacteria && bacteria !== 'Non-descript') {
               badge += ' <span style=\"color: #b388ff; font-weight: bold; font-size: 0.75em; border: 1px solid #b388ff; border-radius: 4px; padding: 1px 4px; margin-left: 6px; vertical-align: middle; white-space: nowrap;\">' + bacteria.toUpperCase() + '</span>';
            }
            
            // --- 2. CREATE TITLE LINK ---
            var titleHtml = '';
            if (url) {
              titleHtml = '<div class=\"title-container\"><a href=\"' + url + '\" target=\"_blank\">' + cleanTitle + '</a>' + badge + '</div>';
            } else {
              titleHtml = '<div class=\"title-container\">' + cleanTitle + badge + '</div>';
            }
            
            // --- 3. CREATE BUTTON ---
            var btnHtml = '<button class=\"btn btn-xs btn-outline-light add-to-reading-list-inline\" ' +
                          'style=\"margin-top: 5px; font-size: 0.8em; padding: 2px 6px;\" ' +
                          'data-index=\"' + meta.row + '\" ' +
                          'data-key=\"' + row[22] + '\">' +
                          'Add to Reading List</button>';
            
            return titleHtml + btnHtml;
          }
          return data;
        }"
      )
    ),
    list(targets = 1, width = "63%", visible = TRUE),
    list(
      targets = 2,     
      render = JS(
        "function(data, type, row, meta) {
      if (type === 'display' && data) {
        var authors = data.split('; ');
        var affiliationsData = row[3]; 
        var parsed = {};
        try { parsed = JSON.parse(affiliationsData); } catch(e) { }
        return authors.map(function(author, index) {
          var affText = 'No affiliation available';
          var key = (index + 1).toString();
          if (parsed && typeof parsed === 'object') {
            if (parsed[key] && parsed[key].affiliations) {
              affText = parsed[key].affiliations;
            } else if (Array.isArray(parsed) && parsed[index]) {
              affText = parsed[index].affiliations || 'No affiliation available';
            }
          }
          var divId = 'aff-' + meta.row + '-' + index;
          return '<span class=\"author-expand-trigger\" data-affiliation-id=\"' + divId + '\">' + author + '</span>' +
                 '<div id=\"' + divId + '\" class=\"affiliation-details hidden\">' + affText + '</div>';
        }).join('; ');
      }
      return data;
    }"
      )
    ),
    list(targets = 3, visible = FALSE, sName = "AuthorAffiliations"),
    # --- COL 4: DATE (THE LINK) ---
    list(
      targets = 4, 
      width = "100px",
      orderData = 21 # <--- THIS LINKS COL 4 CLICK TO COL 21 (SortDate) DATA
    ),
    list(targets = 5, visible = FALSE),
    list(targets = 6, visible = FALSE), 
    list(targets = 7, visible = FALSE), 
    list(targets = 8, visible = FALSE), 
    list(targets = 9, visible = FALSE), 
    list(targets = 10, visible = FALSE), 
    list(targets = 11, visible = FALSE), 
    list(targets = 12, visible = FALSE), 
    list(targets = 13, visible = FALSE), 
    list(targets = 14, visible = FALSE), 
    list(targets = 15, visible = FALSE), 
    list(targets = 16, visible = FALSE), 
    list(targets = 17, visible = FALSE), 
    list(targets = 18, visible = FALSE),
    list(targets = 19, visible = FALSE),
    list(targets = 20, visible = FALSE),
    list(targets = 21, visible = FALSE),
    list(targets = 22, visible = FALSE)  # ItemKey (stable ID for the reading list)
  ),
  callback = JS(
    "if (!window.readingList) {",
    "  window.readingList = [];",
    "}",
    "",
    "$(document).on('click', '.author-expand-trigger', function() {",
    "  var affiliationId = $(this).data('affiliation-id');",
    "  $('#' + affiliationId).toggleClass('hidden');",
    "});",
    "",
    "$(document).on('click', '.add-to-reading-list-inline', function() {",
    "  var index = $(this).data('index');",
    "  var doi = $(this).attr('data-key');",
    "  var button = $(this);",
    "  var title = $(this).closest('.title-container').find('a').text() || $(this).closest('.title-container').text();",
    "",
    "  var itemIndex = -1;",
    "  for (var i = 0; i < window.readingList.length; i++) {",
    "    if (window.readingList[i].key === doi) {",
    "      itemIndex = i;",
    "      break;",
    "    }",
    "  }",
    "",
    "  if (itemIndex === -1) {",
    "    window.readingList.push({ key: doi, Title: title });",
    "    button.text('Remove from Reading List');",
    "    button.addClass('added-to-reading-list');",
    "    Shiny.setInputValue('add_to_reading_list', doi, { priority: 'event' });", 
    "  } else {",
    "    window.readingList.splice(itemIndex, 1);",
    "    button.text('Add to Reading List');",
    "    button.removeClass('added-to-reading-list');",
    "    Shiny.setInputValue('remove_from_reading_list', doi, { priority: 'event' });", 
    "  }",
    "});"
  )
)
