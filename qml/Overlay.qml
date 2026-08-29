import Quickshell
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

  readonly property string viewTitle: {
    if (currentView === "search") return "Player"
    if (currentView === "nowPlaying") return "Now Playing"
    return "Setup"
  }

  // The player needs room; setup is a small card. Sizing off the view keeps
  // both honest instead of forcing one compromise size on each.
  readonly property bool wide: currentView === "search" || currentView === "nowPlaying"

  function open(payloadJson) {
    var args = {}
    if (payloadJson) {
      try { args = JSON.parse(payloadJson) || {} } catch (e) { args = {} }
    }
    // Fall back to setup until the backend is usable -- dropping someone into
    // an empty player when they have not signed in hides the real problem.
    var requested = String(args.view || "search")
    root.currentView = root.ready || requested === "setup" ? requested : "setup"
    root.opened = true
    if (root.svc) root.svc.probeBackend()

    // Deep link: summon straight to an artist or album page. Stored rather than
    // pushed, because the Loader resolves asynchronously -- calling into
    // item directly here either misses it or loses the race with onLoaded.
    root.pendingUri = args.uri ? String(args.uri) : ""
    root.pendingTitle = args.title ? String(args.title) : ""
    root.deepLinkSerial = root.deepLinkSerial + 1
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.menuOpen = false; root.opened = false }

  property bool menuOpen: false

  readonly property bool canGoBack: currentView === "search" && playerLoader.item
    && playerLoader.item.history !== undefined && playerLoader.item.history.length > 0

  function goBack() {
    if (playerLoader.item && typeof playerLoader.item.goBack === "function") {
      playerLoader.item.goBack()
    }
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

            TideMark {
              anchors.verticalCenter: parent.verticalCenter
              gridSize: Style.font.heading * 1.5
              color: Color.accent
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "TIDAL"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.weight: Font.DemiBold
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.viewTitle
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            // Back. Mirrors Left/Backspace so the mouse has the same way out
            // of a drill-down that the keyboard does.
            HeaderButton {
              glyph: "\uf053"
              tooltip: "Back"
              interactive: root.canGoBack
              fontFamily: root.fontFamily
              foreground: root.foreground
              onActivated: root.goBack()
            }

            HeaderButton {
              glyph: "\uf001"
              tooltip: "Player"
              active: root.currentView === "search"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onActivated: root.currentView = "search"
            }

            HeaderButton {
              glyph: "\uf0f6"
              tooltip: "Now playing"
              active: root.currentView === "nowPlaying"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onActivated: root.currentView = "nowPlaying"
            }

            HeaderButton {
              id: menuButton
              glyph: "\uf142"
              tooltip: "Menu"
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
          active: root.currentView === "search"
          visible: active

          sourceComponent: PlayerView {
            svc: root.svc
            foreground: root.foreground
            fontFamily: root.fontFamily
            focus: root.currentView === "search" && root.opened
            deepLinkUri: root.pendingUri
            deepLinkTitle: root.pendingTitle
            deepLinkSerial: root.deepLinkSerial
          }
        }

        Loader {
          id: nowPlayingLoader
          anchors.top: headerRule.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: transportBar.top
          anchors.margins: Style.space(4)
          active: root.currentView === "nowPlaying"
          visible: active

          sourceComponent: NowPlayingView {
            svc: root.svc
            pluginDir: root.pluginDir
            foreground: root.foreground
            fontFamily: root.fontFamily
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
        }

        MouseArea {
          anchors.fill: parent
          visible: root.menuOpen
          z: 90
          onClicked: root.menuOpen = false
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
