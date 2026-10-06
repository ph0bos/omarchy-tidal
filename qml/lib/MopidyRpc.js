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
function stop(onOk, onErr)       { _playSerial++; call("core.playback.stop", null, onOk, onErr) }
function seek(ms, onOk, onErr)   { call("core.playback.seek", { time_position: Math.round(ms) }, onOk, onErr) }
function getState(onOk, onErr)   { call("core.playback.get_state", null, onOk, onErr) }
function currentTrack(onOk, onErr) { call("core.playback.get_current_track", null, onOk, onErr) }

// ---- tracklist ------------------------------------------------------------

function _clear(onOk, onErr)     { call("core.tracklist.clear", null, onOk, onErr) }
// Emptying the queue, like stopping, ends any playNow still filling it.
function clear(onOk, onErr)      { _playSerial++; _clear(onOk, onErr) }
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
// Move one entry within the queue, by position.
//
// core.tracklist.move(start, end, to_position) behaves exactly like a splice:
// the slice is lifted out and re-inserted at to_position in the list that is
// left. Verified against a live tracklist, because "to_position" could equally
// have meant a position in the original list, and the two differ when moving
// downwards.
function moveTrack(fromIndex, toIndex, onOk, onErr) {
  call("core.tracklist.move", { start: fromIndex, end: fromIndex + 1, to_position: toIndex },
       onOk, onErr)
}

function setConsume(on, onOk, onErr) { call("core.tracklist.set_consume", { value: !!on }, onOk, onErr) }
function setRandom(on, onOk, onErr)  { call("core.tracklist.set_random", { value: !!on }, onOk, onErr) }
function setRepeat(on, onOk, onErr)  { call("core.tracklist.set_repeat", { value: !!on }, onOk, onErr) }

// Replace the queue with `uris` and start playing immediately.
//
// In one piece this was `add(everything)` then `play()`, and on a cold cache
// mopidy-tidal spends up to three Tidal round trips per uri inside that one
// add -- forty tracks outlived TIMEOUT_MS, so play() was never sent and "play
// all" did nothing. The first few tracks go in, playback starts, and the rest
// follow in chunks small enough that each fits inside its own timeout. The
// backend also primes these lookups so the chunks are normally instant; the
// chunking is what keeps this working when it has not.
//
// Not with shuffle on. Mopidy picks the opening track from what is in the
// queue when play() arrives, so starting on three meant a shuffled playlist
// always opened on one of its first three songs -- and each later add
// reshuffled the list with that song back in it, so it came round twice.
// There everything goes in first, still in chunks, and play() is last.
var ADD_FIRST = 3
var ADD_CHUNK = 10

// A second playNow while the first is still at work would otherwise get the
// first one's tracks added to its queue: pick the fifth song of a long
// playlist, then the ninth, and the queue held both runs. Each playNow takes a
// number and does nothing further once a later one has been issued, or once
// clear() or stop() has been called. The count lives in this script, and QML
// gives each component that imports it a copy of its own, so it guards a view
// against itself -- which is where two quick clicks come from.
//
// One view against another, or against another Mopidy client, is `anchor`'s
// job: the tlids the opening chunk was given. Before each later chunk goes in,
// Mopidy is asked whether any of them is still queued. If none is, the queue
// has been emptied since and the rest is not wanted in what replaced it. It is
// the opening chunk and not the latest one on purpose: a clear() that lands
// while an add is in flight leaves that add's tracks in the new queue, and a
// tail that checked for those would carry straight on.
var _playSerial = 0

function _tlids(added) {
  var out = []
  if (!Array.isArray(added)) return out
  for (var i = 0; i < added.length; i++) {
    if (added[i] && typeof added[i].tlid === "number") out.push(added[i].tlid)
  }
  return out
}

function _appendChunks(uris, at, onDone, onErr, guard) {
  if (guard && !guard.current()) return
  if (at >= uris.length) { if (onDone) onDone(); return }
  function add() {
    if (guard && !guard.current()) return
    var next = uris.slice(at, at + ADD_CHUNK)
    addUris(next, function(added) {
      var ids = _tlids(added)
      if (guard && ids.length && !guard.anchor.length) {
        guard.anchor = ids
        guard.first = ids[0]
      }
      _appendChunks(uris, at + next.length, onDone, onErr, guard)
    }, onErr)
  }
  if (!guard || !guard.anchor || !guard.anchor.length) { add(); return }
  call("core.tracklist.filter", { criteria: { tlid: guard.anchor } }, function(left) {
    // An answer that is not a list is no answer; only an empty one says the
    // queue has moved on.
    if (Array.isArray(left) && left.length === 0) return
    add()
  }, function() { add() })
}

// `picked` says the first uri is a track someone chose, rather than the top of
// a list they asked to hear: with shuffle on, that one opens and the rest are
// shuffled behind it.
function playNow(uris, onOk, onErr, picked) {
  var all = uris || []
  var serial = ++_playSerial
  var guard = { current: function() { return serial === _playSerial }, anchor: [], first: undefined }

  function begin(shuffled) {
    if (!guard.current()) return
    // By tlid where there is one. With shuffle on, a bare play() opens on
    // whatever Mopidy draws, which is right for "play all" and wrong for a
    // row that was clicked.
    if (guard.first !== undefined && (!shuffled || picked === true)) playTlid(guard.first, onOk, onErr)
    else play(onOk, onErr)
  }

  function start(shuffled) {
    if (!guard.current()) return
    _clear(function() {
      if (!guard.current()) return
      if (shuffled) {
        _appendChunks(all, 0, function() { begin(true) }, onErr, guard)
        return
      }
      opening(0)
    }, onErr)
  }

  // The first few go in on their own so playback can start. If Mopidy says
  // none of them resolved to anything, the next few are tried rather than
  // sending play() at an empty queue, which answers ok and plays nothing.
  function opening(at) {
    var first = all.slice(at, at + ADD_FIRST)
    addUris(first, function(added) {
      if (!guard.current()) return
      var ids = _tlids(added)
      var after = at + first.length
      if (Array.isArray(added) && ids.length === 0) {
        if (after < all.length) { opening(after); return }
        if (onErr) onErr("None of these tracks can be played.")
        return
      }
      if (ids.length) { guard.anchor = ids; guard.first = ids[0] }
      // The rest arrives while the first track is already playing. onOk
      // fires now rather than after the last chunk: the button asked for
      // playback, and playback has started.
      function tail() {
        if (onOk) onOk()
        _appendChunks(all, after, null, onErr, guard)
      }
      if (guard.first !== undefined) playTlid(guard.first, tail, onErr)
      else play(tail, onErr)
    }, onErr)
  }

  // Asked each time rather than passed in: shuffle can be switched from the
  // bar, a keybinding or another client, and this is the one moment it matters.
  // If the question cannot be answered, the play still goes ahead.
  call("core.tracklist.get_random", null,
       function(on) { start(on === true) }, function() { start(false) })
}

// Append without disturbing what is currently playing.
function queue(uris, onOk, onErr) {
  _appendChunks(uris || [], 0, onOk, onErr)
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
