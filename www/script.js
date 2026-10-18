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
  const STEP_SPEED = 1500;          // 6 steps ~= 9s, about a median search
  const DOT_ANIMATION_SPEED = 450;
  
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
  var loadingMessages = [
    "Diving deep...",
    "...Deeper",
    "...Abstractinating",
    "...Almost there",
    "...is this thing working???",
    "...Only one way to know"
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
  // Both the frame and the line come from `step`. Clamped rather than wrapped,
  // so a search longer than the arc rests on the last frame and the punchline.
  function renderStep() {
    if (loadingIcons.length) {
      $("#loadingIcon").attr("src",
        loadingIcons[Math.min(step, loadingIcons.length - 1)]);
    }
    currentLoadingText = loadingMessages[Math.min(step, loadingMessages.length - 1)];
    $("#loadingText").text(currentLoadingText);
    $("#loadingDots").text(".".repeat(dotCount));
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
    renderStep();

    // 3. ONE STEP = ONE FRAME + ONE LINE
    // The messages are a narrative - dive, deeper, abstractinating, almost
    // there, is this thing working, only one way to know - so once the arc
    // reaches the end it HOLDS. Looping back to "Diving deep..." on a long
    // search restarts the story and makes it read as filler.
    loadingInterval = setInterval(function() {
      var last = Math.max(loadingIcons.length, loadingMessages.length) - 1;
      if (step >= last) return;                     // arc finished; hold here
      step += 1;
      renderStep();
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
    
    messageInterval = null; 
    // We do NOT reset initialShowLoading here if we want the messages to 
    // continue where they left off next time, but resetting is usually safer:
    initialShowLoading = true; 
  });

  // ------------------------------------------------------------------------
  // HANDLER: UPDATE LOADING MESSAGE (Specific Override)
  // ------------------------------------------------------------------------
  Shiny.addCustomMessageHandler("update_loading_message", function(message) {
    if (message) {
      currentLoadingText = message; // Update the base text
      $("#loadingText").text(currentLoadingText);
      $("#loadingDots").text("...");
      dotCount = 3;
    }
  });

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