// JSON-RPC 2.0 client for Mopidy's HTTP API.
//
// Quickshell ships no WebSocket module and qt6-websockets is not a dependency
// we want, so commands go out over plain HTTP POST to /mopidy/rpc using QML's
// built-in XMLHttpRequest. Reactive playback state does NOT come from here --
// it arrives over MPRIS (see Service.qml), which is push-based and free.

var DEFAULT_ENDPOINT = "http://127.0.0.1:6680/mopidy/rpc"
var TIMEOUT_MS = 15000

var _nextId = 1

// call(method, params, onOk, onErr, endpoint)
//   onOk(result), onErr(messageString)
function call(method, params, onOk, onErr, endpoint) {
  var url = endpoint || DEFAULT_ENDPOINT
  var id = _nextId++
  var body = { jsonrpc: "2.0", id: id, method: method }
  if (params !== undefined && params !== null) body.params = params

  var xhr = new XMLHttpRequest()
  var settled = false

  function fail(msg) {
    if (settled) return
    settled = true
    if (onErr) onErr(msg)
  }

  xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE || settled) return
    if (xhr.status !== 200) {
      fail("HTTP " + xhr.status + (xhr.status === 0 ? " (mopidy unreachable)" : ""))
      return
    }
    var payload
    try {
      payload = JSON.parse(xhr.responseText)
    } catch (e) {
      fail("malformed JSON from mopidy")
      return
    }
    if (payload.error) {
      fail(payload.error.message || JSON.stringify(payload.error))
      return
    }
    settled = true
    if (onOk) onOk(payload.result)
  }

  try {
    xhr.open("POST", url)
    xhr.setRequestHeader("Content-Type", "application/json")
    xhr.timeout = TIMEOUT_MS
    xhr.ontimeout = function() { fail("mopidy request timed out") }
    xhr.send(JSON.stringify(body))
  } catch (e) {
    fail(String(e))
  }
}

// ---- playback -------------------------------------------------------------

function play(onOk, onErr)       { call("core.playback.play", null, onOk, onErr) }
function pause(onOk, onErr)      { call("core.playback.pause", null, onOk, onErr) }
function resume(onOk, onErr)     { call("core.playback.resume", null, onOk, onErr) }
function next(onOk, onErr)       { call("core.playback.next", null, onOk, onErr) }
function previous(onOk, onErr)   { call("core.playback.previous", null, onOk, onErr) }
function stop(onOk, onErr)       { call("core.playback.stop", null, onOk, onErr) }
function seek(ms, onOk, onErr)   { call("core.playback.seek", { time_position: Math.round(ms) }, onOk, onErr) }
function getState(onOk, onErr)   { call("core.playback.get_state", null, onOk, onErr) }
function currentTrack(onOk, onErr) { call("core.playback.get_current_track", null, onOk, onErr) }

// ---- tracklist ------------------------------------------------------------

function clear(onOk, onErr)      { call("core.tracklist.clear", null, onOk, onErr) }
function addUris(uris, onOk, onErr) { call("core.tracklist.add", { uris: uris }, onOk, onErr) }
function getTracklist(onOk, onErr)  { call("core.tracklist.get_tl_tracks", null, onOk, onErr) }
// Queue entries are addressed by tlid, not by uri: the same track can sit in
// the tracklist more than once, and "remove this one" has to mean this one.
function playTlid(tlid, onOk, onErr) {
  call("core.playback.play", { tlid: tlid }, onOk, onErr)
}
function removeTlid(tlid, onOk, onErr) {
  call("core.tracklist.remove", { criteria: { tlid: [tlid] } }, onOk, onErr)
}
function moveTlid(fromIndex, toIndex, onOk, onErr) {
  call("core.tracklist.move", { start: fromIndex, end: fromIndex + 1, to_position: toIndex },
       onOk, onErr)
}

function setConsume(on, onOk, onErr) { call("core.tracklist.set_consume", { value: !!on }, onOk, onErr) }
function setRandom(on, onOk, onErr)  { call("core.tracklist.set_random", { value: !!on }, onOk, onErr) }
function setRepeat(on, onOk, onErr)  { call("core.tracklist.set_repeat", { value: !!on }, onOk, onErr) }

// Replace the queue with `uris` and start playing immediately.
function playNow(uris, onOk, onErr) {
  clear(function() {
    addUris(uris, function() {
      play(onOk, onErr)
    }, onErr)
  }, onErr)
}

// Append without disturbing what is currently playing.
function queue(uris, onOk, onErr) {
  addUris(uris, onOk, onErr)
}

// ---- library --------------------------------------------------------------

function search(query, uris, onOk, onErr) {
  var params = { query: query }
  if (uris) params.uris = uris
  call("core.library.search", params, onOk, onErr)
}

function browse(uri, onOk, onErr) { call("core.library.browse", { uri: uri }, onOk, onErr) }
function lookup(uris, onOk, onErr) { call("core.library.lookup", { uris: uris }, onOk, onErr) }
function getImages(uris, onOk, onErr) { call("core.library.get_images", { uris: uris }, onOk, onErr) }

// ---- mixer ----------------------------------------------------------------

function getVolume(onOk, onErr) { call("core.mixer.get_volume", null, onOk, onErr) }
function setVolume(v, onOk, onErr) {
  call("core.mixer.set_volume", { volume: Math.max(0, Math.min(100, Math.round(v))) }, onOk, onErr)
}

// ---- health ---------------------------------------------------------------

// Cheap reachability probe used to drive the setup wizard's state machine.
function ping(onOk, onErr) { call("core.get_version", null, onOk, onErr) }
