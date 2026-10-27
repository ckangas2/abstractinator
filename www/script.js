// ==========================================================================
// THEME & LOADING MANAGER (Unified)
// ==========================================================================
$(document).ready(function(){
  
  // --- CONFIGURATION ---
  // One step = one frame AND its message. They used to run on separate timers
  // (3000ms vs 6000ms), so 6 frames looped every 18s against 6 messages every
  // 36s and the pairing was arbitrary - the narwhal was at depth 2 while the
  // text said "Almost there". There is nothing to keep in sync now because
  // both are derived from the same counter.
  // Slow and calm on purpose. One frame every 3s with a 700ms cross-fade
  // reads as breathing; the old 2s hard swap read as flicking through cards.
  const STEP_SPEED = 4200;
  const FADE_MS = 700;              // must match the #loadingIcon transition
  const DOT_ANIMATION_SPEED = 900;  // was 450: a fast dot cycle under a slow
                                    // image cadence is two rhythms fighting.
  
  // 1. ASSET DEFINITIONS
  const THEMES = {
    dino: {
      count: 5, prefix: "dino_", ext: ".png", pad: true, complete: "dino_complete.png"
    },
    frog: {
      count: 7, prefix: "frog_", ext: ".png", pad: true, complete: "frog_complete.png"
    },
    narwhal: {
      count: 6, prefix: "loading", ext: ".png", pad: false, complete: "search_complete.png"
    }
  };

  // --- RESTORED: LOADING MESSAGES ARRAY ---
  // No leading "..." in the strings: the animated dot span supplies the
  // trailing ellipsis, and having both produced "...Deeper .." with dots at
  // each end. Lines ending in ? or ! suppress the dots entirely (see
  // renderStep) so the punchline is not followed by stray periods.
  var loadingMessages = [
    "Diving deep",
    "Deeper",
    "Abstractinating",
    "Almost there",
    "Is this thing working???",
    "Only one way to know"
  ];

  // State Variables
  var currentTheme = "narwhal"; 
  var loadingIcons = [];     
  
  // Animation State
  var step = 0;
  var currentIconIndex = 0;
  var currentMessageIndex = 0;
  var currentLoadingText = loadingMessages[0];
  var dotCount = 0;
  var initialShowLoading = true;

  // Interval IDs (to clear them later)
  var loadingInterval;
  var ellipsisInterval;
  var messageInterval;

  // ------------------------------------------------------------------------
  // HELPER: Update Asset List based on current theme
  // ------------------------------------------------------------------------
  function updateAssetList() {
    var config = THEMES[currentTheme] || THEMES['narwhal'];
    loadingIcons = []; 

    for (var i = 1; i <= config.count; i++) {
      var num = config.pad ? String(i).padStart(2, '0') : String(i);
      loadingIcons.push(config.prefix + num + config.ext);
    }

    // Update static completion images immediately
    $("#completionIconLeft").attr("src", config.complete);
    $("#completionIconRight").attr("src", config.complete);

    // Preload. The icons are swapped by src on a timer, so an image the
    // browser has not fetched yet leaves the slot empty for the length of the
    // request - which is what makes the first cycle stutter. Six small PNGs.
    loadingIcons.forEach(function (src) { var im = new Image(); im.src = src; });
    var doneImg = new Image(); doneImg.src = config.complete;
  }

  // Initialize Default
  updateAssetList();

  // ------------------------------------------------------------------------
  // HANDLER: CHANGE THEME
  // ------------------------------------------------------------------------
  Shiny.addCustomMessageHandler("change_theme", function(message) {
    if (THEMES[message]) {
      currentTheme = message;
      updateAssetList();
      
      // Inject CSS Variables for colors (handled by CSS now, but logic remains if needed)
      // const colors = THEMES[message].colors; ...
      
      console.log("Theme assets updated for:", message);
    }
  });

  // ------------------------------------------------------------------------
  // HANDLER: SHOW LOADING (The Animation Loop)
  // ------------------------------------------------------------------------
  // The image LOOPS and the text HOLDS, which are different jobs.
  //
  // Previously both were clamped with Math.min against
  // Math.max(icons, messages), and the three themes have 5, 6 and 7 frames
  // against 6 messages -- so on the dino set the picture froze four seconds
  // before the end while the text carried on, and on the frog set the text
  // froze while the picture carried on. Either way a deep search (20-60s)
  // sat on a dead frame for most of its duration and looked broken.
  //
  // Both loop. Holding the text on its last line was the first attempt, but
  // a still line under a moving picture reads as half-stuck; the whole thing
  // cycling reads as patient. Frames and messages wrap on their own lengths
  // (5, 6 or 7 against 6), so the pairing rotates over a long search rather
  // than repeating -- which is fine, since no line describes a given frame.
  var fadeTimer = null;

  function setIcon(src) {
    var $i = $("#loadingIcon");
    if (!src || $i.attr("src") === src) return;
    clearTimeout(fadeTimer);
    $i.css("opacity", 0);
    fadeTimer = setTimeout(function () {
      $i.attr("src", src).css("opacity", 1);
    }, FADE_MS);
  }

  function renderStep(immediate) {
    if (loadingIcons.length) {
      var src = loadingIcons[step % loadingIcons.length];
      if (immediate) {
        clearTimeout(fadeTimer);
        $("#loadingIcon").attr("src", src).css("opacity", 1);
      } else {
        setIcon(src);
      }
    }
    currentLoadingText = loadingMessages[step % loadingMessages.length];
    $("#loadingText").text(currentLoadingText);

    // A line that ends in its own punctuation gets no trailing dots, and the
    // reserved width goes away with them so the text stays centred.
    var wantsDots = !/[?!.]$/.test(currentLoadingText);
    $("#loadingMessage").toggleClass("no-dots", !wantsDots);
    $("#loadingDots").text(wantsDots ? ".".repeat(dotCount) : "");
  }

  Shiny.addCustomMessageHandler("show_loading", function(message) {
    // .css() rather than .show(): jQuery's .show() restores a div to
    // display:block, which would undo the flex centring. .hide() is fine.
    $(".loading-overlay").css("display", "flex");
    $(".loading-overlay").addClass('show-progress');

    // show_loading can arrive again before hide_loading has run - a second
    // search, a reconnect, a re-render. Without clearing first, each arrival
    // stacked another icon timer and another dots timer on the ones already
    // running, so the animation sped up and stuttered, and hide_loading could
    // only ever clear the most recent of them. messageInterval was already
    // guarded below; these two were not.
    clearInterval(loadingInterval);
    clearInterval(ellipsisInterval); 

    // Every search starts the story at the beginning.
    step = 0;
    dotCount = 3;
    renderStep(true);   // first frame appears at once, no fade-in

    // 3. ONE STEP = ONE FRAME + ONE LINE, both wrapping. A search that
    // outlasts the narrative starts it over rather than stalling on the
    // punchline, which looked broken on a 20-60s deep search.
    loadingInterval = setInterval(function() {
      step += 1;                   // never stops: renderStep wraps the frame
      renderStep();                // and holds the text at its last line
    }, STEP_SPEED);

    // 4. Dots animate within the step. They live in their own fixed-width
    // span, so adding one does not shift the centred message sideways -
    // which is what made the ellipsis look chunky.
    ellipsisInterval = setInterval(function() {
      dotCount = (dotCount % 3) + 1;
      $("#loadingDots").text(".".repeat(dotCount));
    }, DOT_ANIMATION_SPEED);
  });


  // ------------------------------------------------------------------------
  // HANDLER: HIDE LOADING
  // ------------------------------------------------------------------------
  Shiny.addCustomMessageHandler("hide_loading", function(message) {
    $(".loading-overlay").hide();
    $(".loading-overlay").removeClass('show-progress'); 
    
    // KILL ALL TIMERS
    clearInterval(loadingInterval);
    clearInterval(ellipsisInterval);
    clearInterval(messageInterval);
    clearTimeout(fadeTimer);
    $("#loadingIcon").css("opacity", 1);   // next search starts visible
    
    messageInterval = null; 
    // We do NOT reset initialShowLoading here if we want the messages to 
    // continue where they left off next time, but resetting is usually safer:
    initialShowLoading = true; 
  });

  // ------------------------------------------------------------------------
  // HANDLER: UPDATE LOADING MESSAGE (Specific Override)
  // ------------------------------------------------------------------------

});

// ==========================================================================
// PLOTLY CLICK HANDLERS
// ==========================================================================
var clickedAnnotation = null;

$(document).on('plotly_click', '#allArticlesPlotOutput', function(eventdata) {
  if (eventdata && eventdata.points && eventdata.points.length > 0) {
    var pt = eventdata.points[0];
    var x = pt.xaxis.d2l(pt.x); 
    var y = pt.yaxis.d2l(pt.y);
    var text = pt.text;
    var pointNumber = pt.pointNumber;
    var curveNumber = pt.curveNumber;

    if (clickedAnnotation && clickedAnnotation.pointNumber === pointNumber && clickedAnnotation.curveNumber === curveNumber) {
      Plotly.relayout('allArticlesPlotOutput', { annotations: [] });
      clickedAnnotation = null;
    } else {
      var annotation = {
        x: x, y: y, xref: 'x', yref: 'y',
        text: text, showarrow: true, arrowhead: 2,
        ax: 20, ay: -30, bgcolor: 'rgba(0,0,0,0.8)',
        font: { color: '#eee' },
        pointNumber: pointNumber, curveNumber: curveNumber
      };
      Plotly.relayout('allArticlesPlotOutput', { annotations: [annotation] });
      clickedAnnotation = annotation;
    }
  } else {
    Plotly.relayout('allArticlesPlotOutput', { annotations: [] });
    clickedAnnotation = null;
  }
});