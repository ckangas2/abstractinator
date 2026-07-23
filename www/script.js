// ==========================================================================
// THEME & LOADING MANAGER (Unified)
// ==========================================================================
$(document).ready(function(){
  
  // --- CONFIGURATION ---
  const ICON_CYCLE_SPEED = 3000;    
  const MESSAGE_CYCLE_SPEED = 6000; 
  const DOT_ANIMATION_SPEED = 700;
  
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
  Shiny.addCustomMessageHandler("show_loading", function(message) {
    $(".loading-overlay").show();
    $(".loading-overlay").addClass('show-progress'); 

    // 1. Initialize Icon
    currentIconIndex = 0;
    if(loadingIcons.length > 0) {
        $("#loadingIcon").attr("src", loadingIcons[currentIconIndex]);
    }

    // 2. Initialize Message (Only reset text on first load or if needed)
    if (initialShowLoading) {
      currentMessageIndex = 0;
      currentLoadingText = loadingMessages[0];
      $("#loadingMessage").text(currentLoadingText + "...");
      dotCount = 3;
      initialShowLoading = false;
    }

    // 3. START INTERVAL: Cycle Icons
    loadingInterval = setInterval(function() {
      if(loadingIcons.length === 0) return;
      currentIconIndex = (currentIconIndex + 1) % loadingIcons.length;
      $("#loadingIcon").attr("src", loadingIcons[currentIconIndex]);
    }, ICON_CYCLE_SPEED);

    // 4. START INTERVAL: Animate Dots (...)
    ellipsisInterval = setInterval(function() {
      var dots = ".".repeat(dotCount);
      $("#loadingMessage").text(currentLoadingText + dots);
      dotCount = (dotCount % 3) + 1;
    }, DOT_ANIMATION_SPEED);

    // 5. START INTERVAL: Cycle Messages (RESTORED LOGIC)
    if (!messageInterval) { 
      messageInterval = setInterval(function() {
        // Advance index
        currentMessageIndex = (currentMessageIndex + 1) % loadingMessages.length;
        
        // Update Base Text
        currentLoadingText = loadingMessages[currentMessageIndex];
        
        // Immediate Update (don't wait for dot cycle)
        $("#loadingMessage").text(currentLoadingText + "...");
        dotCount = 3; // Reset dots for new message
        
      }, MESSAGE_CYCLE_SPEED);
    }
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
      $("#loadingMessage").text(currentLoadingText + "...");
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