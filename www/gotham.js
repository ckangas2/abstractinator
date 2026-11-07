/* ==========================================================================
   gotham.js -- the "Welcome to Gotham" look and its seasonal decorations.

   What it does (and nothing else):
     1. Puts class "gotham" on <html>, which switches on www/gotham.css.
     2. Puts data-season="..." on <html>, which picks the palette and which
        decorations the skyline shows: none, halloween, thanksgiving or
        christmas.
     3. Keeps the moon's silhouette in step with the mascot theme (narwhal,
        dino, frog) by copying the src that script.js already sets on
        #completionIconLeft.

   It is loaded in <head>, before the page body exists, so the season is set
   before the first paint and the page never flashes the old look.

   Previewing a season: add ?season=christmas (or none, halloween,
   thanksgiving) to the URL. From the browser console: gothamSetSeason("x").
   ========================================================================== */
(function () {
  "use strict";

  // Season windows, inclusive, in the visitor's local date.
  // [month, day] with months 1-12. Outside every window the season is "none":
  // the Gotham city with no decorations. Edit the dates here and nowhere else.
  var SEASON_WINDOWS = [
    { season: "halloween",    from: [10, 1],  to: [11, 1]  },
    { season: "thanksgiving", from: [11, 2],  to: [11, 30] },
    { season: "christmas",    from: [12, 1],  to: [12, 31] },
    { season: "christmas",    from: [1, 1],   to: [1, 1]   }  // New Year's Day
  ];
  var SEASONS = ["none", "halloween", "thanksgiving", "christmas"];

  // Month and day packed into one comparable number: Oct 31 -> 1031.
  function monthDay(m, d) { return m * 100 + d; }

  function seasonForDate(date) {
    var today = monthDay(date.getMonth() + 1, date.getDate());
    for (var i = 0; i < SEASON_WINDOWS.length; i++) {
      var w = SEASON_WINDOWS[i];
      if (today >= monthDay(w.from[0], w.from[1]) &&
          today <= monthDay(w.to[0], w.to[1])) {
        return w.season;
      }
    }
    return "none";
  }

  // A valid ?season= in the URL wins over the calendar.
  function chosenSeason() {
    var match = /[?&]season=([a-z]+)/.exec(window.location.search);
    if (match && SEASONS.indexOf(match[1]) !== -1) return match[1];
    return seasonForDate(new Date());
  }

  var root = document.documentElement;
  root.classList.add("gotham");
  root.setAttribute("data-season", chosenSeason());

  // For previews and for a future settings switch.
  window.gothamSetSeason = function (season) {
    if (SEASONS.indexOf(season) === -1) return false;
    root.setAttribute("data-season", season);
    return true;
  };

  // --- Moon silhouette follows the mascot theme ---------------------------
  // script.js swaps #completionIconLeft's src whenever the theme changes
  // (search_complete.png, dino_complete.png, frog_complete.png). Mirroring
  // that attribute means the theme list lives in one place, script.js.
  function syncMoonMascot() {
    var mascot = document.getElementById("completionIconLeft");
    var moon = document.getElementById("gothamMoonMascot");
    if (mascot && moon && mascot.getAttribute("src")) {
      moon.setAttribute("href", mascot.getAttribute("src"));
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    syncMoonMascot();
    var mascot = document.getElementById("completionIconLeft");
    if (mascot && window.MutationObserver) {
      new MutationObserver(syncMoonMascot)
        .observe(mascot, { attributes: true, attributeFilter: ["src"] });
    }
  });
})();
