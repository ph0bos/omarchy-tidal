import QtQuick
import Quickshell
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
  // Stopped counts as nothing playing, whatever the metadata still says.
  //
  // MPRIS keeps the last track's title and artist after a stop, so testing the
  // metadata alone meant `hasTrack` stayed true for the rest of the session and
  // the bar widget never took itself out of the bar. The player's own state is
  // the honest answer to "is there anything here".
  readonly property bool stopped:
    player ? player.playbackState === MprisPlaybackState.Stopped : true
  readonly property bool hasTrack:
    connected && !stopped && (title !== "" || artist !== "")

  // Mopidy publishes the backend URI (e.g. "tidal:track:12345") as xesam:url.
  // Favorites, lyrics, and radio all key off this.
  readonly property string trackUri: {
    if (!player || !player.metadata) return ""
    var m = player.metadata
    return String(m["xesam:url"] || "")
  }
  readonly property bool isTidalTrack: trackUri.indexOf("tidal:") === 0

  // mopidy-tidal's long uri form is tidal:track:<artist>:<album>:<id>, so the
  // record and the performer behind the current track are already in hand --
  // no lookup needed to make the transport bar click through to their pages.
  // The short form carries only the track id, and these stay empty.
  readonly property var _uriParts: trackUri.split(":")
  readonly property string albumUri: root.isTidalTrack && _uriParts.length >= 5
    ? "tidal:album:" + _uriParts[3] : ""
  readonly property string artistUri: root.isTidalTrack && _uriParts.length >= 5
    ? "tidal:artist:" + _uriParts[2] : ""

  // ---- backend health ------------------------------------------------------

  // Drives the setup wizard. "unknown" until the first probe answers so the
  // bar widget does not flash a "not set up" state on shell start.
  property string backendState: "unknown"   // unknown | down | up
  // True once a probe has run all the way through -- ping, then the
  // companion's health -- so callers can tell "not set up" apart from "not
  // asked yet". Without it the overlay opens on the setup wizard every time
  // the shell restarts, because nothing has answered yet at that instant.
  property bool probed: false
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
        root.probed = true
      }, function() {
        if (!root.alive) return
        root.companionAvailable = false
        root.signedIn = false
        root.probed = true
      })
    }, function(err) {
      if (!root.alive) return
      root.backendState = "down"
      root.companionAvailable = false
      root.signedIn = false
      root.probed = true
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
  // Mopidy's consume: a track is dropped from the queue once it has played.
  // Not "pause after this track", which is what this used to claim in the menu
  // and in the OSD -- a different setting entirely, and now a real one below.
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
      // Nothing to write here, but a second request on behalf of an object
      // that no longer exists is still worth not sending.
      if (!root.alive) return
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
      root.osd(next ? "Played tracks will be removed"
                    : "Played tracks will be kept", "media")
    })
    return true
  }

  // ---- sleep timer ---------------------------------------------------------
  //
  // Two shapes, because both are things people mean by "stop soon": a number of
  // minutes, and "when this track finishes". The countdown runs off a wall
  // clock rather than a tick count, for the same reason the playback position
  // does -- timers fire late under load and the error accumulates.
  property double sleepEndsAt: 0     // epoch ms, 0 when no timer is set
  property bool sleepAfterTrack: false

  readonly property bool sleeping: sleepEndsAt > 0 || sleepAfterTrack
  readonly property int sleepMinutesLeft: sleepEndsAt > 0
    ? Math.max(0, Math.ceil((sleepEndsAt - now) / 60000)) : 0

  // Ticks once a second only while a timer is set, so an idle plugin costs
  // nothing.
  property double now: 0

  Timer {
    running: root.sleepEndsAt > 0
    interval: 1000
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!root.alive) return
      root.now = Date.now()
      if (root.now >= root.sleepEndsAt) root.sleepNow()
    }
  }

  function sleepNow() {
    root.cancelSleep()
    if (root.player && root.player.canTogglePlaying && root.playing) root.player.togglePlaying()
    else Rpc.pause()
    root.osd("Sleep timer: stopped", "media")
  }

  function cancelSleep() {
    root.sleepEndsAt = 0
    root.sleepAfterTrack = false
  }

  // Put the app away.
  //
  // There was no way to do this from inside it. The panel closed with Escape,
  // but the bar widget stayed -- Mopidy keeps the last track loaded after a
  // pause, so the widget had something to display all day and only left when
  // the queue was emptied, which is not a thing anyone thinks to do in order to
  // quit. So: stop, empty the queue, close the panel. The widget has nothing
  // left to show and takes itself out of the bar.
  //
  // Deliberately not `omarchy plugin disable`. That unloads the plugin, needs a
  // shell restart, and cannot be undone from a surface that no longer exists --
  // a quit button you cannot come back from is a trap. `SUPER+M`, the Apps
  // entry, or the bar widget bring it straight back.
  function quit() {
    Rpc.stop(function() {
      if (!root.alive) return
      Rpc.clear(function() {
        if (!root.alive) return
        root.closeSurfaces()
      }, function() { if (root.alive) root.closeSurfaces() })
    }, function() {
      if (!root.alive) return
      Rpc.clear(null, null)
      root.closeSurfaces()
    })
    return true
  }

  // Off -> 15 -> 30 -> 45 -> 60 -> end of track -> off. One entry in the menu
  // rather than a submenu, the way repeat already cycles.
  function cycleSleep() {
    if (root.sleepAfterTrack) { root.cancelSleep(); root.osd("Sleep timer off", "media"); return true }
    var minutes = root.sleepEndsAt > 0 ? root.sleepMinutesLeft : 0
    var next = minutes >= 60 ? -1 : (minutes >= 45 ? 60 : (minutes >= 30 ? 45 : (minutes >= 15 ? 30 : 15)))
    if (next === -1) {
      root.sleepEndsAt = 0
      root.sleepAfterTrack = true
      root.osd("Sleep after this track", "media")
      return true
    }
    root.now = Date.now()
    root.sleepEndsAt = root.now + next * 60000
    root.sleepAfterTrack = false
    root.osd("Sleep in " + next + " minutes", "media")
    return true
  }

  readonly property string sleepLabel: {
    if (root.sleepAfterTrack) return "end of track"
    if (root.sleepEndsAt > 0) return root.sleepMinutesLeft + " min"
    return "off"
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
    Qt.callLater(root.refreshPalette)
  }

  onTrackUriChanged: {
    // The queue moving on is how a "sleep after this track" timer arrives.
    if (root.sleepAfterTrack) root.sleepNow()

    // Announce it, but not the track that happens to be loaded when the shell
    // starts -- that is not a change anyone made.
    if (root.seenATrack) Qt.callLater(root.announceTrack)
    if (root.trackUri !== "") root.seenATrack = true
    root.anchorPosition(0)
    Qt.callLater(root.syncPosition)
    root.favorite = false
    root.format = null
    root.lyrics = null
    root.artPalette = null
    root.refreshTrackDetail()
  }

  // A shell restart or plugin reload lands mid-playback: the track never
  // "changes", so onTrackUriChanged never fires and the quality badge would
  // stay blank for the rest of the track. Re-fetch once the companion answers.
  onCompanionAvailableChanged: {
    if (root.companionAvailable && root.trackUri !== "") root.refreshTrackDetail()
  }

  // ---- artwork palette -----------------------------------------------------
  //
  // What the sleeve looks like, so surfaces drawn over or beside it can react:
  // text needs a heavier wash under it when the cover is white, and a spectrum
  // analyser beside a record may as well be the colour of that record.
  property var artPalette: null

  function refreshPalette() {
    if (!companionAvailable || !isTidalTrack) { root.artPalette = null; return }
    var forUri = trackUri
    Tidal.palette(forUri, function(p) {
      if (!root.alive || forUri !== root.trackUri) return
      root.artPalette = p
    }, function() {
      if (!root.alive || forUri !== root.trackUri) return
      root.artPalette = null
    })
  }

  // 0 (black sleeve) to 1 (white sleeve).
  readonly property real artLuma: artPalette ? Number(artPalette.luma) || 0 : 0
  readonly property bool artIsLight: artPalette ? artPalette.isLight === true : false

  // The sleeve's own colour, or "" for a cover that has none -- black and white
  // artwork reports nothing rather than a washed-out grey.
  //
  // Reported raw, not vetted. This object is headless and holds no opinion
  // about the theme; whether the colour is readable depends on the surface it
  // lands on, and the mini player's background is not the overlay's. Each view
  // decides with Design.readableOr().
  readonly property string artColor: artPalette && artPalette.color
    ? String(artPalette.color) : ""

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

  // ---- settings ------------------------------------------------------------
  //
  // The plugin's own options, kept beside the shell's config rather than in the
  // bar widget's schema: a notification preference is not a bar concern, and
  // the widget entry disappears if someone removes the widget.
  readonly property string settingsPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
    + "/omarchy-tidal/settings.json"

  // Announce each track as it starts. On by default: someone who installs a
  // music player generally wants to be told what is playing.
  property bool notifyOnTrackChange: true

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onFileChanged: reload()
    onLoaded: {
      if (!root.alive) return
      try {
        var saved = JSON.parse(text() || "{}")
        if (saved && saved.notifyOnTrackChange !== undefined) {
          root.notifyOnTrackChange = !!saved.notifyOnTrackChange
        }
      } catch (e) { /* a corrupt file is a file we overwrite, not a crash */ }
    }
  }

  function saveSettings() {
    settingsFile.setText(JSON.stringify({
      notifyOnTrackChange: root.notifyOnTrackChange
    }, null, 2) + "\n")
  }

  function setNotify(on) {
    root.notifyOnTrackChange = !!on
    root.saveSettings()
    root.osd(root.notifyOnTrackChange ? "Track notifications on"
                                      : "Track notifications off", "media")
    return true
  }

  // ---- track notifications -------------------------------------------------
  //
  // Fetches the sleeve's path first, because a notification daemon wants a file
  // rather than a url, and the bytes are already cached for anything that has
  // been on screen.
  property bool seenATrack: false

  function announceTrack() {
    if (!root.notifyOnTrackChange || !root.hasTrack) return
    if (!root.companionAvailable || !root.isTidalTrack) { root.sendNotification(""); return }
    var forUri = root.trackUri
    Tidal.artFile(forUri, function(info) {
      if (!root.alive || forUri !== root.trackUri) return
      root.sendNotification(info && info.path ? String(info.path) : "")
    }, function() {
      if (!root.alive || forUri !== root.trackUri) return
      root.sendNotification("")
    })
  }

  function sendNotification(iconPath) {
    var body = root.artist
    if (root.album !== "") body = body === "" ? root.album : body + "  \u00b7  " + root.album

    var args = ["notify-send", "--app-name=TIDAL", "--expire-time=5000",
                // Replace the last one rather than stacking a card per track.
                "--hint=string:x-canonical-private-synchronous:omarchy-tidal"]
    if (iconPath !== "") args.push("--icon=" + iconPath)
    args.push(root.plainMessage(root.title))
    args.push(root.plainMessage(body))
    Quickshell.execDetached(args)
  }

  // ---- surfaces ------------------------------------------------------------

  // `face` is only meaningful for the now-playing view, which can be summoned
  // straight onto its lyrics or its credits. The keybinding advertised as
  // "lyrics" should land on lyrics rather than on artwork with a click to go.
  function openView(view, face) {
    if (!shell) return false
    var payload = { view: view }
    if (face) payload.face = String(face)
    return shell.summon(pluginId, JSON.stringify(payload)) === true
  }

  // Summon the player straight onto an artist or album page. The overlay
  // resolves its Loader asynchronously, so the uri travels in the payload
  // rather than as a call into a view that may not exist yet.
  // ---- mini player -------------------------------------------------------
  //
  // The bar widget registers itself here so a keybinding can open its popup.
  // The shell's own summon path cannot: it routes a bar-widget panel only for
  // plugins that are bar widgets and nothing else, and this one also owns an
  // overlay.
  property var miniPlayers: []

  function registerMiniPlayer(widget) {
    var next = root.miniPlayers.slice()
    next.push(widget)
    root.miniPlayers = next
  }

  function unregisterMiniPlayer(widget) {
    var next = []
    for (var i = 0; i < root.miniPlayers.length; i++) {
      if (root.miniPlayers[i] !== widget) next.push(root.miniPlayers[i])
    }
    root.miniPlayers = next
  }

  // Every surface this plugin can have open, shut.
  function closeSurfaces() {
    for (var i = 0; i < root.miniPlayers.length; i++) {
      // A widget destroyed by a hot reload can still be sitting in the list;
      // reading it throws rather than returning null.
      try {
        var widget = root.miniPlayers[i]
        if (widget && typeof widget.close === "function") widget.close()
      } catch (e) { /* gone with its bar */ }
    }
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggleMini() {
    for (var i = 0; i < root.miniPlayers.length; i++) {
      // A widget destroyed by a hot reload can still be sitting in the list;
      // reading it throws rather than returning null.
      try {
        var widget = root.miniPlayers[i]
        if (widget && typeof widget.toggleIfFocused === "function"
            && widget.toggleIfFocused()) return true
      } catch (e) { /* gone with its bar */ }
    }
    return false
  }

  function openDetail(uri, title) {
    if (!shell || !uri) return false
    return shell.summon(pluginId, JSON.stringify({
      view: "search", uri: String(uri), title: String(title || "")
    })) === true
  }

  // Messages go to another plugin's surface, which renders them with its own
  // rules. Ours carry catalogue strings -- a playlist name, an error from
  // TIDAL -- so the angle brackets come out here, at the boundary, rather than
  // trusting whatever is on the other side not to treat them as markup.
  function plainMessage(message) {
    return String(message || "").replace(/[<>]/g, "")
  }

  function osd(message, icon) {
    if (!shell) return
    shell.summon("omarchy.osd", JSON.stringify({
      icon: icon || "media",
      message: root.plainMessage(message)
    }))
  }

  function statusJson() {
    return JSON.stringify({
      connected: root.connected,
      backend: root.backendState,
      companion: root.companionAvailable,
      probed: root.probed,
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
      sleep: root.sleepLabel,
      notify: root.notifyOnTrackChange,
      lyricsSource: root.lyrics && root.lyrics.source ? root.lyrics.source : "",
      lyricsSynced: root.lyrics && root.lyrics.synced ? root.lyrics.synced.length : 0,
      lyricsPlain: root.lyrics && root.lyrics.plain ? root.lyrics.plain.length : 0,
      hiRes: root.isHiRes,
      artColor: root.artColor,
      artLuma: root.artLuma,
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
    function mini(): string { return root.toggleMini() ? "ok" : "unhandled" }
    function lyrics(): string { return root.openView("nowPlaying", "lyrics") ? "ok" : "unhandled" }
    function info(): string { return root.openView("nowPlaying", "info") ? "ok" : "unhandled" }
    function setup(): string { return root.openView("setup") ? "ok" : "unhandled" }
    function settings(): string { return root.openView("setup") ? "ok" : "unhandled" }
    function favorite(): string { return root.toggleFavorite() ? "ok" : "unhandled" }
    function radio(): string { return root.startRadio() ? "ok" : "unhandled" }
    function shuffle(): string { return root.toggleShuffle() ? "ok" : "unhandled" }
    function repeat(): string { return root.cycleRepeat() ? "ok" : "unhandled" }
    function consume(): string { return root.toggleConsume() ? "ok" : "unhandled" }
    function sleep(): string { return root.cycleSleep() ? "ok" : "unhandled" }
    function sleepOff(): string { root.cancelSleep(); return "ok" }
    function notifications(): string { return root.setNotify(!root.notifyOnTrackChange) ? "ok" : "unhandled" }
    function announce(): string { root.announceTrack(); return "ok" }
    function quit(): string { return root.quit() ? "ok" : "unhandled" }
    function playPause(): string { return root.playPause() ? "ok" : "unhandled" }
    function next(): string { return root.next() ? "ok" : "unhandled" }
    function previous(): string { return root.previous() ? "ok" : "unhandled" }
    function ping(): string { return "ok" }
  }
}
