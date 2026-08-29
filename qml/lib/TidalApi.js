// Client for the mopidy-omarchy-tidal companion extension.
//
// Mopidy's core API has no concept of lyrics, Tidal's personalized home,
// radio seeds, favorites, or the negotiated stream format. Our extension adds
// those as plain HTTP endpoints, running in-process with mopidy-tidal so it can
// reuse the already-authenticated tidalapi session rather than logging in twice.
//
// Every call degrades gracefully: if the extension is not installed yet the
// caller gets onErr() and the UI hides the affected feature rather than
// breaking. This is what lets the bar widget work before Phase 2 lands.

var BASE = "http://127.0.0.1:6680/omarchy-tidal"
var TIMEOUT_MS = 15000

function _request(method, path, body, onOk, onErr) {
  var xhr = new XMLHttpRequest()
  var settled = false

  function fail(msg) {
    if (settled) return
    settled = true
    if (onErr) onErr(msg)
  }

  xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE || settled) return
    if (xhr.status === 404 || xhr.status === 0) {
      fail("companion extension unavailable")
      return
    }
    if (xhr.status < 200 || xhr.status >= 300) {
      fail("HTTP " + xhr.status)
      return
    }
    var payload
    try {
      payload = JSON.parse(xhr.responseText)
    } catch (e) {
      fail("malformed JSON from companion extension")
      return
    }
    settled = true
    if (onOk) onOk(payload)
  }

  try {
    xhr.open(method, BASE + path)
    if (body) xhr.setRequestHeader("Content-Type", "application/json")
    xhr.timeout = TIMEOUT_MS
    xhr.ontimeout = function() { fail("companion request timed out") }
    xhr.send(body ? JSON.stringify(body) : null)
  } catch (e) {
    fail(String(e))
  }
}

function _q(params) {
  var parts = []
  for (var k in params) {
    if (params[k] === undefined || params[k] === null || params[k] === "") continue
    parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(params[k]))
  }
  return parts.length ? "?" + parts.join("&") : ""
}

// Is the companion extension loaded at all?
function health(onOk, onErr) { _request("GET", "/health", null, onOk, onErr) }

// Auth state for the setup wizard: { logged_in, login_url, quality }
function authStatus(onOk, onErr) { _request("GET", "/auth/status", null, onOk, onErr) }

// Synced lyrics. Resolves Tidal first, then falls back to LRCLIB.
// -> { synced: [{ time_ms, text }], plain: "...", source: "tidal"|"lrclib"|null }
function lyrics(trackUri, onOk, onErr) {
  _request("GET", "/lyrics" + _q({ uri: trackUri }), null, onOk, onErr)
}

// Tidal's personalized home / For You rows.
// -> { rows: [{ title, items: [{ uri, name, artist, image, type }] }] }
function home(onOk, onErr) { _request("GET", "/home", null, onOk, onErr) }

// Favorites: toggle or query the heart state of a track.
function isFavorite(trackUri, onOk, onErr) {
  _request("GET", "/favorite" + _q({ uri: trackUri }), null, onOk, onErr)
}
function setFavorite(trackUri, on, onOk, onErr) {
  _request("POST", "/favorite", { uri: trackUri, favorite: !!on }, onOk, onErr)
}

// Radio seeded from a track or artist -> { uris: [...] }
function radio(seedUri, onOk, onErr) {
  _request("GET", "/radio" + _q({ uri: seedUri }), null, onOk, onErr)
}

// Similar artists / albums for the browse UI.
function similar(uri, onOk, onErr) {
  _request("GET", "/similar" + _q({ uri: uri }), null, onOk, onErr)
}

// Full artist page in one round trip: photo, bio (markup already stripped, with
// the mentions extracted as links), top tracks, discography, similar artists.
function artist(uri, onOk, onErr) {
  _request("GET", "/artist" + _q({ uri: uri }), null, onOk, onErr)
}

// Full album page: art, year, credits, editorial review, and the track list.
function album(uri, onOk, onErr) {
  _request("GET", "/album" + _q({ uri: uri }), null, onOk, onErr)
}

// Negotiated stream format for what is playing right now.
// -> { codec, bit_depth, sample_rate, quality, is_hires }
function streamFormat(onOk, onErr) { _request("GET", "/format", null, onOk, onErr) }
