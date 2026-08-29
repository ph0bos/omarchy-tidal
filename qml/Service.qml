import QtQuick
import Quickshell.Io
import Quickshell.Services.Mpris
import "lib/MopidyRpc.js" as Rpc
import "lib/TidalApi.js" as Tidal

// Headless singleton for the Tidal plugin.
//
// This is the single source of truth every other surface reads from. It does
// two things the rest of the plugin depends on:
//
//   1. Binds to Mopidy's MPRIS interface for reactive playback state. MPRIS is
//      push-based over D-Bus, so track/art/play-state updates cost nothing and
//      arrive instantly -- no polling, no WebSocket dependency.
//   2. Exposes an IpcHandler on target "tidal" so keybindings and menu entries
//      are just `omarchy-shell tidal <action>`.
//
// Commands that MPRIS cannot express (search, queue manipulation, browsing) go
// out over Mopidy's HTTP JSON-RPC via MopidyRpc.js. Tidal-specific extras
// (lyrics, favorites, radio, stream format) go to our companion extension via
// TidalApi.js and degrade quietly when it is not installed.

Item {
  id: root

  // Injected by the shell host.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: "quickshell.tidal"

  // Saving any file under ~/.config/omarchy/plugins/ hot-reloads plugin code,
  // which destroys this object while HTTP callbacks and the poll timer may
  // still be in flight. A callback that then writes a property is a
  // use-after-free, and Quickshell turns that into a fatal abort -- taking the
  // whole shell down with it. Everything async below bails out once this flips.
  property bool alive: true

  Component.onDestruction: {
    root.alive = false
    probeTimer.running = false
    positionTimer.running = false
  }

  // ---- MPRIS binding -------------------------------------------------------

  readonly property var players: Mpris.players ? Mpris.players.values : []

  // Always track Mopidy specifically. Taking whatever player happens to be
  // "active" would make the widget flip to Firefox or mpv mid-song.
  readonly property var player: {
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      var bus = String(p.dbusName || "")
      var id = String(p.identity || "")
      if (bus.indexOf("mopidy") !== -1 || id.toLowerCase() === "mopidy") return p
    }
    return null
  }

  readonly property bool connected: player !== null
  readonly property bool playing: player ? !!player.isPlaying : false
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string album: player ? (player.trackAlbum || "") : ""
  readonly property string artUrl: player ? (player.trackArtUrl || "") : ""
  // MPRIS only emits a position change on an explicit seek -- it never ticks,
  // and reading player.position costs a D-Bus round trip. So the timeline runs
  // off a wall-clock anchor rather than an accumulating counter:
  //
  //   position = anchorPos + (now - anchorAt)
  //
  // Incrementing a counter on a 500ms timer drifts, because timers fire late
  // under load and the error accumulates for the whole track. Deriving from
  // Date.now() cannot drift; the timer only decides how often the UI repaints.
  property real position: 0
  property real anchorPos: 0
  property real anchorAt: 0

  function anchorPosition(seconds) {
    root.anchorPos = Math.max(0, seconds)
    root.anchorAt = Date.now()
    root.position = root.anchorPos
  }

  function syncPosition() {
    if (player && player.positionSupported) root.anchorPosition(player.position)
  }

  Timer {
    id: positionTimer
    running: root.playing && root.hasTrack
    interval: 100
    repeat: true
    onTriggered: {
      if (!root.alive) return
      var next = root.anchorPos + (Date.now() - root.anchorAt) / 1000
      root.position = root.length > 0 ? Math.min(next, root.length) : next
    }
  }

  // Re-anchor against the player periodically so an outside seek, a pause, or
  // buffering cannot leave the bar telling a different story than the audio.
  Timer {
    running: root.playing && root.hasTrack
    interval: 5000
    repeat: true
    onTriggered: if (root.alive) root.syncPosition()
  }

  onPlayingChanged: {
    if (!root.alive) return
    // Freeze the clock where it is on pause, then re-anchor from the player.
    root.anchorPosition(root.position)
    Qt.callLater(root.syncPosition)
  }
  readonly property real length: player && player.lengthSupported ? player.length : 0
  readonly property bool hasTrack: connected && (title !== "" || artist !== "")

  // Mopidy publishes the backend URI (e.g. "tidal:track:12345") as xesam:url.
  // Favorites, lyrics, and radio all key off this.
  readonly property string trackUri: {
    if (!player || !player.metadata) return ""
    var m = player.metadata
    return String(m["xesam:url"] || "")
  }
  readonly property bool isTidalTrack: trackUri.indexOf("tidal:") === 0

  // ---- backend health ------------------------------------------------------

  // Drives the setup wizard. "unknown" until the first probe answers so the
  // bar widget does not flash a "not set up" state on shell start.
  property string backendState: "unknown"   // unknown | down | up
  property bool companionAvailable: false
  // Distinct from companionAvailable: the extension can be loaded and running
  // while no Tidal session exists yet. The wizard needs to tell those apart.
  property bool signedIn: false
  property string lastError: ""

  function probeBackend() {
    Rpc.ping(function() {
      if (!root.alive) return
      root.backendState = "up"
      root.refreshModes()
      Tidal.health(function(info) {
        if (!root.alive) return
        root.companionAvailable = true
        root.signedIn = !!(info && info.logged_in)
      }, function() {
        if (!root.alive) return
        root.companionAvailable = false
        root.signedIn = false
      })
    }, function(err) {
      if (!root.alive) return
      root.backendState = "down"
      root.companionAvailable = false
      root.signedIn = false
      root.lastError = err
    })
  }

  // Slow heartbeat only. Real playback state comes from MPRIS, so this exists
  // purely to notice mopidy starting or dying.
  Timer {
    id: probeTimer
    interval: root.backendState === "up" ? 30000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { if (root.alive) root.probeBackend() }
  }

  // ---- playback modes ------------------------------------------------------
  //
  // Mopidy models repeat as two independent flags (repeat + single), which is
  // awkward to present. They are folded into one three-state value here:
  //   off -> all -> single -> off
  property bool shuffle: false
  property string repeatMode: "off"   // off | all | single
  property bool consume: false

  function refreshModes() {
    Rpc.call("core.tracklist.get_random", null, function(v) {
      if (root.alive) root.shuffle = !!v
    })
    Rpc.call("core.tracklist.get_repeat", null, function(rep) {
      if (!root.alive) return
      Rpc.call("core.tracklist.get_single", null, function(single) {
        if (!root.alive) return
        root.repeatMode = !rep ? "off" : (single ? "single" : "all")
      })
    })
    Rpc.call("core.tracklist.get_consume", null, function(v) {
      if (root.alive) root.consume = !!v
    })
  }

  function toggleShuffle() {
    var next = !root.shuffle
    Rpc.setRandom(next, function() {
      if (!root.alive) return
      root.shuffle = next
      root.osd(next ? "Shuffle on" : "Shuffle off", "media")
    })
    return true
  }

  function cycleRepeat() {
    var next = root.repeatMode === "off" ? "all" : (root.repeatMode === "all" ? "single" : "off")
    var rep = next !== "off"
    var single = next === "single"
    Rpc.setRepeat(rep, function() {
      Rpc.call("core.tracklist.set_single", { value: single }, function() {
        if (!root.alive) return
        root.repeatMode = next
        root.osd(next === "off" ? "Repeat off"
               : (next === "all" ? "Repeat all" : "Repeat track"), "media")
      })
    })
    return true
  }

  function toggleConsume() {
    var next = !root.consume
    Rpc.setConsume(next, function() {
      if (!root.alive) return
      root.consume = next
      root.osd(next ? "Pause after track" : "Continue playing", "media")
    })
    return true
  }

  // ---- stream quality ------------------------------------------------------

  property var format: null           // { codec, bit_depth, sample_rate, is_hires }
  readonly property string qualityLabel: {
    if (!format) return ""
    var bits = format.bit_depth
    var rate = format.sample_rate
    if (!bits || !rate) return String(format.codec || "").toUpperCase()
    var khz = (rate / 1000)
    khz = (khz % 1 === 0) ? khz.toFixed(0) : khz.toFixed(1)
    return String(format.codec || "FLAC").toUpperCase() + " " + bits + "/" + khz
  }
  readonly property bool isHiRes: format ? !!format.is_hires : false

  function refreshFormat() {
    if (!companionAvailable) { root.format = null; return }
    Tidal.streamFormat(function(f) { if (root.alive) root.format = f },
                       function() { if (root.alive) root.format = null })
  }

  // Everything Tidal-specific about the current track: format, heart state,
  // lyrics. Called on a track change and again whenever the companion becomes
  // reachable.
  function refreshTrackDetail() {
    Qt.callLater(root.refreshFormat)
    Qt.callLater(root.refreshFavorite)
    Qt.callLater(root.refreshLyrics)
  }

  onTrackUriChanged: {
    root.anchorPosition(0)
    Qt.callLater(root.syncPosition)
    root.favorite = false
    root.format = null
    root.lyrics = null
    root.refreshTrackDetail()
  }

  // A shell restart or plugin reload lands mid-playback: the track never
  // "changes", so onTrackUriChanged never fires and the quality badge would
  // stay blank for the rest of the track. Re-fetch once the companion answers.
  onCompanionAvailableChanged: {
    if (root.companionAvailable && root.trackUri !== "") root.refreshTrackDetail()
  }

  // ---- favorites -----------------------------------------------------------

  property bool favorite: false

  function refreshFavorite() {
    if (!companionAvailable || !isTidalTrack) return
    Tidal.isFavorite(trackUri, function(r) { if (root.alive) root.favorite = !!(r && r.favorite) },
                     function() {})
  }

  function toggleFavorite() {
    if (!isTidalTrack) { osd("No TIDAL track playing", "media"); return false }
    if (!companionAvailable) { osd("TIDAL companion not installed", "media"); return false }
    var next = !favorite
    Tidal.setFavorite(trackUri, next, function() {
      if (!root.alive) return
      root.favorite = next
      root.osd(next ? "Added to favorites" : "Removed from favorites",
               next ? "heart" : "heart-outline")
    }, function(err) {
      if (!root.alive) return
      root.osd("Could not update favorites", "media")
      root.lastError = err
    })
    return true
  }

  // ---- lyrics --------------------------------------------------------------

  property var lyrics: null           // { synced: [{time_ms, text}], plain, source }

  function refreshLyrics() {
    if (!companionAvailable || !isTidalTrack) return
    var forUri = trackUri
    Tidal.lyrics(forUri, function(l) {
      // Drop late responses for a track we have already moved past.
      if (!root.alive || forUri !== root.trackUri) return
      root.lyrics = l
    }, function() {
      if (!root.alive || forUri !== root.trackUri) return
      root.lyrics = null
    })
  }

  // ---- radio ---------------------------------------------------------------

  function startRadio() {
    if (!isTidalTrack) { osd("No TIDAL track playing", "media"); return false }
    if (!companionAvailable) { osd("TIDAL companion not installed", "media"); return false }
    Tidal.radio(trackUri, function(r) {
      if (!root.alive) return
      var uris = (r && r.uris) || []
      if (!uris.length) { root.osd("No radio available", "media"); return }
      Rpc.playNow(uris, function() { if (root.alive) root.osd("Radio started", "media-play") },
                  function(err) { if (root.alive) root.lastError = err })
    }, function(err) {
      if (!root.alive) return
      root.osd("Could not start radio", "media")
      root.lastError = err
    })
    return true
  }

  // ---- transport -----------------------------------------------------------
  //
  // Prefer MPRIS: it is already connected and avoids an HTTP round trip.
  // Fall back to JSON-RPC when the player is not exported yet.

  function playPause() {
    if (player && player.canTogglePlaying) { player.togglePlaying(); return true }
    Rpc.getState(function(state) {
      if (!root.alive) return
      if (state === "playing") Rpc.pause(); else Rpc.play()
    }, function(err) { if (root.alive) root.lastError = err })
    return true
  }

  function next() {
    if (player && player.canGoNext) { player.next(); return true }
    Rpc.next(null, function(err) { if (root.alive) root.lastError = err })
    return true
  }

  function previous() {
    if (player && player.canGoPrevious) { player.previous(); return true }
    Rpc.previous(null, function(err) { if (root.alive) root.lastError = err })
    return true
  }

  // Seeking is split in two so scrubbing stays smooth.
  //
  // previewSeek moves only the local clock: dragging the playhead fires on
  // every mouse move, and issuing a seek RPC per move floods Mopidy and makes
  // the audio stutter. commitSeek is the one call that actually moves playback.
  function previewSeek(ms) {
    root.anchorPosition(ms / 1000)
  }

  function commitSeek(ms) {
    root.anchorPosition(ms / 1000)
    Rpc.seek(ms, function() {
      // Re-anchor once the backend confirms, so a rejected or clamped seek
      // corrects itself rather than leaving the bar lying.
      if (root.alive) Qt.callLater(root.syncPosition)
    }, function(err) { if (root.alive) root.lastError = err })
  }

  function seekTo(ms) { root.commitSeek(ms) }

  // ---- surfaces ------------------------------------------------------------

  function openView(view) {
    if (!shell) return false
    return shell.summon(pluginId, JSON.stringify({ view: view })) === true
  }

  function osd(message, icon) {
    if (!shell) return
    shell.summon("omarchy.osd", JSON.stringify({
      icon: icon || "media",
      message: message
    }))
  }

  function statusJson() {
    return JSON.stringify({
      connected: root.connected,
      backend: root.backendState,
      companion: root.companionAvailable,
      signedIn: root.signedIn,
      playing: root.playing,
      title: root.title,
      artist: root.artist,
      album: root.album,
      uri: root.trackUri,
      favorite: root.favorite,
      quality: root.qualityLabel,
      shuffle: root.shuffle,
      repeat: root.repeatMode,
      consume: root.consume,
      lyricsSource: root.lyrics && root.lyrics.source ? root.lyrics.source : "",
      lyricsSynced: root.lyrics && root.lyrics.synced ? root.lyrics.synced.length : 0,
      lyricsPlain: root.lyrics && root.lyrics.plain ? root.lyrics.plain.length : 0,
      hiRes: root.isHiRes,
      position: root.position,
      length: root.length
    })
  }

  // ---- IPC -----------------------------------------------------------------
  //
  // Every keybinding and menu entry routes through here:
  //   omarchy-shell tidal overlay | nowPlaying | favorite | radio | ...

  IpcHandler {
    target: "tidal"

    function status(): string { return root.statusJson() }
    function overlay(): string { return root.openView("search") ? "ok" : "unhandled" }
    function search(): string { return root.openView("search") ? "ok" : "unhandled" }
    function nowPlaying(): string { return root.openView("nowPlaying") ? "ok" : "unhandled" }
    function setup(): string { return root.openView("setup") ? "ok" : "unhandled" }
    function favorite(): string { return root.toggleFavorite() ? "ok" : "unhandled" }
    function radio(): string { return root.startRadio() ? "ok" : "unhandled" }
    function shuffle(): string { return root.toggleShuffle() ? "ok" : "unhandled" }
    function repeat(): string { return root.cycleRepeat() ? "ok" : "unhandled" }
    function consume(): string { return root.toggleConsume() ? "ok" : "unhandled" }
    function playPause(): string { return root.playPause() ? "ok" : "unhandled" }
    function next(): string { return root.next() ? "ok" : "unhandled" }
    function previous(): string { return root.previous() ? "ok" : "unhandled" }
    function ping(): string { return "ok" }
  }
}
