/* ==========================================================================
   gotham.js -- the "Welcome to Gotham" look and its seasonal decorations.

   Gotham is OPT-IN. A first-time visitor sees the Classic look, where the
   mascot (narwhal, dino, frog) sets the colours. Settings -> Appearance ->
   Look switches to Gotham, where the season sets the colours and the mascot
   rides the moon. The choice is remembered in the visitor's browser
   (localStorage) and applied here, in <head>, before the page is painted.

   What it does (and nothing else):
     1. If the visitor chose Gotham, puts class "gotham" on <html>, which
        switches on www/gotham.css. Otherwise leaves the page Classic.
     2. Puts data-season="..." on <html>, which picks the palette and which
        decorations the skyline shows: none, halloween, thanksgiving or
        christmas. "Auto" (the default) picks by date.
     3. Keeps the moon's silhouette in step with the mascot theme (narwhal,
        dino, frog) by copying the src that script.js already sets on
        #completionIconLeft.

   It is loaded in <head>, before the page body exists, so the season is set
   before the first paint and the page never flashes the old look.

   Previewing without changing the saved choice: ?look=gotham or ?look=classic,
   and ?season=christmas (or none, halloween, thanksgiving; implies Gotham).
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

  // --- The visitor's choice ------------------------------------------------
  var LOOK_KEY = "abstractinator.look";      // "classic" (default) or "gotham"
  var SEASON_KEY = "abstractinator.season";  // "auto" (default) or a season

  // Storage can be missing or throw (private windows, blocked site data);
  // the page then simply stays Classic.
  function load(key) { try { return window.localStorage.getItem(key); } catch (e) { return null; } }
  function save(key, value) { try { window.localStorage.setItem(key, value); } catch (e) { /* ignore */ } }

  function urlParam(name) {
    var match = new RegExp("[?&]" + name + "=([a-z]+)").exec(window.location.search);
    return match ? match[1] : null;
  }

  var state = {
    look: load(LOOK_KEY) === "gotham" ? "gotham" : "classic",
    season: SEASONS.indexOf(load(SEASON_KEY)) !== -1 ? load(SEASON_KEY) : "auto"
  };
  // URL previews win for this page view only; they are not saved.
  var urlLook = urlParam("look"), urlSeason = urlParam("season");
  if (urlLook === "gotham" || urlLook === "classic") state.look = urlLook;
  if (urlSeason && SEASONS.indexOf(urlSeason) !== -1) { state.look = "gotham"; state.season = urlSeason; }

  var root = document.documentElement;

  function apply() {
    if (state.look === "gotham") {
      root.classList.add("gotham");
      root.setAttribute("data-season",
        state.season === "auto" ? seasonForDate(new Date()) : state.season);
    } else {
      root.classList.remove("gotham");
      root.removeAttribute("data-season");
    }
  }
  apply();

  // Settings -> Appearance calls this (via the "set_look" message below).
  // Saves the choice and applies it at once; no reload needed.
  window.abstractinatorSetLook = function (look, season) {
    if (look === "gotham" || look === "classic") { state.look = look; save(LOOK_KEY, look); }
    if (season === "auto" || SEASONS.indexOf(season) !== -1) { state.season = season; save(SEASON_KEY, season); }
    apply();
    return { look: state.look, season: state.season };
  };
  // Kept for previews from the browser console.
  window.gothamSetSeason = function (season) {
    if (SEASONS.indexOf(season) === -1) return false;
    window.abstractinatorSetLook("gotham", season);
    return true;
  };

  // Tell the server the current choice (so the settings menu opens with it
  // selected), and accept changes from the settings menu.
  // Attached once the page has loaded: this file runs in <head>, possibly
  // before jQuery and Shiny are available. Shiny connects after that.
  document.addEventListener("DOMContentLoaded", function () {
    if (!window.jQuery) return;
    window.jQuery(document).on("shiny:connected", function () {
      window.Shiny.setInputValue("client_look", { look: state.look, season: state.season });
      window.Shiny.addCustomMessageHandler("set_look", function (msg) {
        var now = window.abstractinatorSetLook(msg.look, msg.season);
        window.Shiny.setInputValue("client_look", now);
      });
    });
  });

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
