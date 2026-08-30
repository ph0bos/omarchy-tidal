import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "components"
import "views"

// The plugin's single summoned surface.
//
// A plugin only ever gets ONE panel-kind entry point loaded -- shell.qml's
// computePanelEntries() picks "panel" over "overlay" over "menu" and loads just
// that one -- so the player, the lyrics view, and first-run setup cannot be
// separate plugin surfaces. They are views here instead, chosen by the summon
// payload:
//
//   omarchy-shell shell summon quickshell.tidal '{"view":"search"}'
//
// keepLoaded is set in the manifest, so this window and its state survive
// between summons: reopening the player lands you back where you were.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string currentView: "setup"

  readonly property var svc: shell ? shell.serviceFor("quickshell.tidal") : null

  // PluginRegistry stamps the resolved plugin directory onto the manifest, which
  // is how the wizard locates bin/omarchy-tidal-auth without a hardcoded path.
  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property string fontFamily: Style.font.menuFamily

  readonly property bool backendReady: svc ? svc.backendState === "up" && svc.connected : false
  readonly property bool ready: backendReady && (svc ? svc.signedIn : false)

  // Setup is shown when we KNOW the backend is unusable, never merely because
  // nothing has answered yet. Probing is asynchronous and the first summon
  // after a shell restart beats it, so testing `ready` alone opened the wizard
  // on a perfectly healthy install every single time.
  readonly property bool decided: svc ? svc.probed : false
  readonly property bool blocked: decided && !ready

  // The view the summon actually asked for, remembered so that finishing
  // setup drops you where you were headed instead of leaving you in the
  // wizard.
  property string requestedView: "search"

  onBlockedChanged: {
    if (!root.opened) return
    if (root.blocked && root.currentView !== "setup") root.currentView = "setup"
    else if (!root.blocked && root.currentView === "setup" && root.requestedView !== "setup")
      root.currentView = root.requestedView
  }


  // The player needs room; setup is a small card. Sizing off the view keeps
  // both honest instead of forcing one compromise size on each.
  readonly property bool wide: currentView === "search" || currentView === "nowPlaying"

  function open(payloadJson) {
    var args = {}
    if (payloadJson) {
      try { args = JSON.parse(payloadJson) || {} } catch (e) { args = {} }
    }
    // Fall back to setup only once a probe has come back saying the backend is
    // unusable -- dropping someone into an empty player when they have not
    // signed in hides the real problem, but so does opening the wizard on an
    // install that is simply still answering.
    var requested = String(args.view || "search")
    root.requestedView = requested
    root.currentView = requested === "setup" || root.blocked ? "setup" : requested
    root.menuOpen = false
    root.targetScreen = root.pickScreen()
    root.opened = true
    if (root.currentView === "search") root.playerLoaded = true
    else if (root.currentView === "nowPlaying") {
      root.nowPlayingLoaded = true
      root.applyFace(String(args.face || ""))
    }
    if (root.svc) root.svc.probeBackend()

    // Deep link: summon straight to an artist or album page. Stored rather than
    // pushed, because the Loader resolves asynchronously -- calling into
    // item directly here either misses it or loses the race with onLoaded.
    root.pendingUri = args.uri ? String(args.uri) : ""
    root.pendingTitle = args.title ? String(args.title) : ""
    root.deepLinkSerial = root.deepLinkSerial + 1
    Qt.callLater(root.focusView)
  }

  // Whichever view is showing gets the keyboard.
  //
  // This used to hand focus to the key catcher unconditionally, which quietly
  // broke the player's entire keyboard model: the catcher is an ancestor of
  // the player view, so it took the keys and the view's own handler -- search,
  // arrows, Enter, Tab -- never ran. Keys the view does not accept still
  // bubble up to the catcher, so Escape keeps working from anywhere.
  function focusView() {
    if (root.currentView === "search" && playerLoader.item) {
      playerLoader.item.forceActiveFocus()
      return
    }
    keyCatcher.forceActiveFocus()
  }

  function close() { root.menuOpen = false; root.opened = false }

  // Which screen to open on, decided at open time rather than left to whatever
  // the window was created against.
  //
  // `keepLoaded` keeps this window alive between summons, so it can outlive the
  // monitor it was first created on. Unplug a display -- or let one come back
  // after a fallback output -- and the surface holds a screen that no longer
  // exists: Quickshell logs "Layershell screen does not correspond to a real
  // screen" and the overlay never maps again until the shell is restarted.
  // Re-picking on every open also means the player opens on the screen you are
  // actually looking at.
  property var targetScreen: null

  function pickScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === name) return screens[i]
    }
    // No match: let the compositor choose, which is the old behaviour.
    return null
  }

  // Which face of the now-playing view a summon asked for. Deferred rather
  // than assigned straight away: the Loader may only be activating on this
  // very call, and its item does not exist until it has.
  function applyFace(face) {
    if (face === "") return
    Qt.callLater(function() {
      if (nowPlayingLoader.item) nowPlayingLoader.item.face = face
    })
  }

  property bool menuOpen: false

  // The keyboard map, raised over whatever surface asked for it.
  property bool shortcutsOpen: false

  function toggleShortcuts() {
    root.menuOpen = false
    root.shortcutsOpen = !root.shortcutsOpen
    Qt.callLater(root.shortcutsOpen ? shortcutSheet.forceActiveFocus : root.focusView)
  }

  // "Add to playlist", raised over whatever surface asked for it.
  property bool pickerOpen: false
  property string pickerUri: ""
  property string pickerTitle: ""

  function addToPlaylist(uri, title) {
    if (!uri || String(uri).indexOf("tidal:track:") !== 0) {
      if (root.svc) root.svc.osd("No TIDAL track to add", "media")
      return
    }
    root.menuOpen = false
    root.pickerUri = String(uri)
    root.pickerTitle = String(title || "")
    root.pickerOpen = true
  }

  // Views stay loaded once visited. Destroying and rebuilding them on every
  // switch threw away scroll position and search results, and tore down the
  // analyser's audio capture along with it.
  property bool playerLoaded: false
  property bool nowPlayingLoaded: false

  onCurrentViewChanged: {
    if (root.currentView === "search") root.playerLoaded = true
    else if (root.currentView === "nowPlaying") root.nowPlayingLoaded = true
    if (root.opened) Qt.callLater(root.focusView)
  }

  readonly property bool canGoBack: currentView === "search" && playerLoader.item
    && playerLoader.item.history !== undefined && playerLoader.item.history.length > 0

  function goBack() {
    if (playerLoader.item && typeof playerLoader.item.goBack === "function") {
      playerLoader.item.goBack()
    }
  }

  // Deep-link into the player's detail page from anywhere in the overlay.
  // Stored rather than pushed for the same reason open() stores it: the Loader
  // resolves asynchronously and a direct call into item races it.
  function showDetail(uri, title) {
    if (!uri) return
    root.pendingUri = String(uri)
    root.pendingTitle = String(title || "")
    root.deepLinkSerial = root.deepLinkSerial + 1
    root.currentView = "search"
  }

  function runMenuAction(action) {
    root.menuOpen = false
    if (!root.svc) return
    switch (action) {
      case "player":   root.currentView = "search"; break
      case "lyrics":   root.currentView = "nowPlaying"; break
      case "favorite": root.svc.toggleFavorite(); break
      case "radio":    root.svc.startRadio(); break
      case "shuffle":  root.svc.toggleShuffle(); break
      case "repeat":   root.svc.cycleRepeat(); break
      case "consume":  root.svc.toggleConsume(); break
      case "sleep":    root.svc.cycleSleep(); break
      case "playlist": root.addToPlaylist(root.svc.trackUri, root.svc.title); break
      case "keys":     root.toggleShortcuts(); break
    }
  }

  property string pendingUri: ""
  property string pendingTitle: ""

  // Bumped on every summon so PlayerView reacts even when the same uri is
  // requested twice in a row.
  property int deepLinkSerial: 0

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-tidal"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: root.opened
      Keys.onEscapePressed: root.close()

      // Now playing has no list to drive, so the keys that would otherwise go
      // unused switch its faces. The player view keeps its own handler and
      // takes focus while it is showing, so these never fight over a key.
      Keys.onPressed: function(event) {
        if (root.currentView !== "nowPlaying") return
        if (event.key === Qt.Key_Space) {
          if (root.svc) root.svc.playPause()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_M) {
          root.menuOpen = !root.menuOpen
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Question) {
          root.toggleShortcuts()
          event.accepted = true
          return
        }
        var face = event.key === Qt.Key_A ? "artwork"
                 : (event.key === Qt.Key_L ? "lyrics"
                 : (event.key === Qt.Key_I ? "info" : ""))
        if (face === "") return
        if (nowPlayingLoader.item) nowPlayingLoader.item.face = face
        event.accepted = true
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: root.wide
          ? Math.min(Style.space(1020), parent.width - Style.gapsOut * 4)
          : Math.min(Style.space(560), parent.width - Style.gapsOut * 4)
        height: root.wide
          ? Math.min(Style.space(760), parent.height - Style.gapsOut * 4)
          : Math.min(Style.space(120) + setupLoader.height,
                     parent.height - Style.gapsOut * 4)
        radius: Style.cornerRadius
        color: root.background
        border.width: Math.max(1, Style.space(1))
        border.color: root.borderColor

        // Swallow clicks so they do not fall through to the dismiss scrim.
        MouseArea { anchors.fill: parent }

        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: Style.space(18)
          height: Style.space(30)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            // Mark and wordmark sit on one baseline, and the mark is drawn to
            // the height of the capitals rather than to the text's full line
            // box, which includes ascent and descent the letters never fill.
            // Centring the two boxes against each other is what left the mark
            // looking like it was floating above the word.
            TideMark {
              anchors.baseline: wordmark.baseline
              markHeight: Math.round(Style.font.heading * 0.86)
              color: Color.accent
            }

            Text {
              id: wordmark
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "TIDAL"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.weight: Font.DemiBold
              font.letterSpacing: 0.6
            }

          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            // Back. Mirrors Left/Backspace so the mouse has the same way out
            // of a drill-down that the keyboard does.
            HeaderButton {
              // Nothing to go back to during setup, and nothing to steer:
              // these appear once there is a player behind them.
              glyph: "\uf053"
              tooltip: "Back"
              visible: root.currentView !== "setup"
              interactive: root.canGoBack
              fontFamily: root.fontFamily
              foreground: root.foreground
              onActivated: root.goBack()
            }

            HeaderButton {
              glyph: "\uf001"
              tooltip: "Player"
              visible: root.currentView !== "setup"
              active: root.currentView === "search"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onActivated: root.currentView = "search"
            }

            HeaderButton {
              glyph: "\uf0f6"
              tooltip: "Now playing"
              visible: root.currentView !== "setup"
              active: root.currentView === "nowPlaying"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onActivated: root.currentView = "nowPlaying"
            }

            HeaderButton {
              id: menuButton
              glyph: "\uf142"
              tooltip: "Menu"
              visible: root.currentView !== "setup"
              active: root.menuOpen
              fontFamily: root.fontFamily
              foreground: root.foreground
              onActivated: root.menuOpen = !root.menuOpen
            }
          }
        }

        Rectangle {
          id: headerRule
          anchors.top: header.bottom
          anchors.topMargin: Style.space(12)
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(1, Style.space(1))
          color: root.borderColor
          opacity: 0.5
        }

        Loader {
          id: setupLoader
          anchors.top: headerRule.bottom
          anchors.topMargin: Style.space(18)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(18)
          anchors.rightMargin: Style.space(18)
          active: root.currentView === "setup"
          visible: active
          height: item ? item.implicitHeight : 0

          sourceComponent: SetupWizard {
            svc: root.svc
            pluginDir: root.pluginDir
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
        }

        Loader {
          id: playerLoader
          anchors.top: headerRule.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: transportBar.top
          anchors.margins: Style.space(10)
          anchors.topMargin: Style.space(6)
          active: root.playerLoaded || root.currentView === "search"
          // Cross-faded rather than cut. Both views stay loaded, so the swap
          // is a change of attention, not a page load, and it should look
          // like one.
          opacity: root.currentView === "search" ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

          sourceComponent: PlayerView {
            svc: root.svc
            foreground: root.foreground
            fontFamily: root.fontFamily
            focus: root.currentView === "search" && root.opened
            deepLinkUri: root.pendingUri
            deepLinkTitle: root.pendingTitle
            deepLinkSerial: root.deepLinkSerial
            onAddToPlaylist: function(uri, title) { root.addToPlaylist(uri, title) }
            onMenuRequested: root.menuOpen = !root.menuOpen
            onShortcutsRequested: root.toggleShortcuts()
          }
        }

        Loader {
          id: nowPlayingLoader
          anchors.top: headerRule.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: transportBar.top
          anchors.margins: Style.space(4)
          active: root.nowPlayingLoaded || root.currentView === "nowPlaying"
          opacity: root.currentView === "nowPlaying" ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

          sourceComponent: NowPlayingView {
            svc: root.svc
            pluginDir: root.pluginDir
            foreground: root.foreground
            fontFamily: root.fontFamily
            onContract: root.currentView = "search"
            // Clicking the album or artist on the info face lands on their
            // page, through the same deep-link path a summon uses.
            onOpenUri: function(uri, title) { root.showDetail(uri, title) }
          }
        }

        // One transport strip shared by every view: the controls should not
        // disappear just because you switched to lyrics.
        PlayerBar {
          id: transportBar
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          visible: root.wide
          svc: root.svc
          foreground: root.foreground
          fontFamily: root.fontFamily
          expanded: root.currentView === "nowPlaying"
          onArtClicked: root.currentView =
            root.currentView === "nowPlaying" ? "search" : "nowPlaying"
          onOpenUri: function(uri, title) { root.showDetail(uri, title) }
        }

        MouseArea {
          anchors.fill: parent
          visible: root.menuOpen
          z: 90
          onClicked: root.menuOpen = false
        }

        ShortcutSheet {
          id: shortcutSheet
          anchors.fill: parent
          z: 210
          visible: root.shortcutsOpen
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClosed: {
            root.shortcutsOpen = false
            Qt.callLater(root.focusView)
          }
        }

        // Above the card's own content, and focused while it is up.
        PlaylistPicker {
          id: playlistPicker
          anchors.fill: parent
          z: 200
          visible: root.pickerOpen
          svc: root.svc
          foreground: root.foreground
          fontFamily: root.fontFamily
          trackUri: root.pickerUri
          trackTitle: root.pickerTitle
          onClosed: {
            root.pickerOpen = false
            Qt.callLater(root.focusView)
          }
        }

        QuickMenu {
          id: quickMenu
          visible: root.menuOpen
          z: 100
          anchors.top: header.bottom
          anchors.right: parent.right
          anchors.topMargin: Style.space(6)
          anchors.rightMargin: Style.space(14)
          svc: root.svc
          foreground: root.foreground
          fontFamily: root.fontFamily
          onRequested: function(action) { root.runMenuAction(action) }
        }
      }
    }
  }
}
