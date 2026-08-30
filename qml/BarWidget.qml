import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "lib/TidalApi.js" as Tidal
import "components"

// TIDAL now-playing for the Omarchy bar.
//
//   left = mini player · right = now playing · middle = play/pause
//   scroll = previous / next
//
// A left click opens the mini player under the widget, the way every other
// panel in this bar behaves. Skipping a track should not dim the desktop and
// take over the screen, which is what the full overlay does -- and the mini
// player has a way through to it for the things that need the room.
//
// State is read from the plugin's service, which is bound to Mopidy over MPRIS,
// so this never polls and never speaks HTTP itself.
BarWidget {
  id: root
  moduleName: "quickshell.tidal"

  readonly property var svc: bar?.shell?.serviceFor("quickshell.tidal") ?? null

  readonly property bool hasTrack: svc ? svc.hasTrack : false
  readonly property bool playing: svc ? svc.playing : false
  readonly property string title: svc ? svc.title : ""
  readonly property string artist: svc ? svc.artist : ""
  readonly property string artUrl: svc ? Tidal.artProxy(svc.artUrl, 80) : ""
  readonly property string qualityLabel: svc ? svc.qualityLabel : ""
  readonly property bool isHiRes: svc ? svc.isHiRes : false
  readonly property bool favorite: svc ? svc.favorite : false

  readonly property bool showQuality: setting("showQualityBadge", false) && qualityLabel !== ""
  readonly property real maxLabelWidth: setting("maxLabelWidth", 260)
  readonly property bool scrollLongLabels: setting("scrollLongLabels", true)
  // Off gives a tray-sized widget -- artwork and state, no text -- for anyone
  // who puts this in the right-hand cluster, where a title that changes width
  // every few minutes would shove the status icons around.
  readonly property bool showLabel: setting("showLabel", true)

  // Album art already identifies the widget; showing the TIDAL mark next to it
  // is two logos for one thing. The mark stands in only when there is no art.
  readonly property bool showMark: !hasArt || root.vertical || !showLabel
  readonly property bool hasArt: artUrl !== ""

  // Panel lifecycle, in the shape the bar looks for: it drives these when a
  // hotkey or an IPC call targets a bar widget's panel.
  property bool popupOpen: false
  readonly property bool opened: popupOpen
  function open() { root.popupOpen = true }
  function close() { root.popupOpen = false }
  function toggle() { root.popupOpen = !root.popupOpen }

  // A bar surface exists per monitor, so a keybinding that says "mini player"
  // has several of these to choose from. The one on the focused screen answers
  // and the rest decline, which is the same rule the bar's own panels use.
  readonly property string screenName: {
    var window = root.QsWindow.window
    return window && window.screen ? String(window.screen.name) : ""
  }

  function toggleIfFocused() {
    // Hidden when nothing is playing, and a popup anchored to a zero-size item
    // lands nowhere useful.
    if (!root.visible) return false
    if (root.bar && typeof root.bar.focusedScreenName === "function") {
      var focused = String(root.bar.focusedScreenName() || "")
      if (focused !== "" && focused !== root.screenName) return false
    }
    root.toggle()
    return true
  }

  // The service holds the registry: it is the one object with an IPC handler,
  // and the shell will not route a summon to a bar widget belonging to a
  // plugin that also owns an overlay.
  //
  // Registration is not a one-shot at completion: `svc` is read through the
  // bar and the shell, and on a cold start this widget exists before either
  // does, so the first read is null.
  property var registeredWith: null

  function syncRegistration() {
    if (root.registeredWith === root.svc) return
    if (root.registeredWith) root.registeredWith.unregisterMiniPlayer(root)
    root.registeredWith = root.svc
    if (root.svc) root.svc.registerMiniPlayer(root)
  }

  onSvcChanged: root.syncRegistration()
  Component.onCompleted: root.syncRegistration()
  Component.onDestruction: if (root.registeredWith) root.registeredWith.unregisterMiniPlayer(root)

  readonly property string label: {
    if (!title) return ""
    return artist ? (title + "  ·  " + artist) : title
  }

  visible: hasTrack
  implicitWidth: !hasTrack ? 0 : (vertical ? barSize : content.implicitWidth + Style.space(14))
  implicitHeight: vertical ? content.implicitHeight + Style.space(10) : barSize

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(7)

    RoundedImage {
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Math.round(root.barSize * 0.58) : 0
      height: width
      radius: Style.space(2)
      decodeSize: 64
      visible: !root.vertical && root.hasArt
      source: root.artUrl
    }

    TideMark {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showMark
      gridSize: Style.font.body * 1.5
      color: root.playing
        ? (root.bar ? root.bar.barForeground : Color.bar.text)
        : Qt.darker(root.bar ? root.bar.barForeground : Color.bar.text, 1.6)
    }

    // The label's natural width, measured off-screen.
    //
    // Sizing the clip to labelText.implicitWidth looked right and was not: an
    // elided Text reports the width of the *elided* string, so the clip fed a
    // narrower width back into the Text, which elided harder, and the loop
    // settled on a title cut to a third of the space it had. TextMetrics
    // measures the string itself and depends on nothing downstream.
    TextMetrics {
      id: labelMetrics
      font: labelText.font
      text: root.label
    }

    // Track label. Elided by default; long titles scroll instead of truncating
    // so the whole thing is readable without a tooltip.
    Item {
      id: labelClip
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showLabel && !root.vertical && root.label !== ""
      width: visible ? Math.min(labelMetrics.width, root.maxLabelWidth) : 0
      height: labelText.implicitHeight
      clip: true

      readonly property bool overflowing: labelMetrics.width > width + 1
      readonly property bool scrolling: overflowing && root.scrollLongLabels

      Text {
        textFormat: Text.PlainText
        id: labelText
        text: root.label
        color: root.bar ? root.bar.barForeground : Color.bar.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        // Only elide when not scrolling, otherwise the ellipsis scrolls too.
        elide: labelClip.scrolling ? Text.ElideNone : Text.ElideRight
        width: labelClip.scrolling ? labelMetrics.width : labelClip.width

        // Pause at each end so the start and end are both readable.
        SequentialAnimation on x {
          running: labelClip.scrolling && root.hasTrack
          loops: Animation.Infinite
          PauseAnimation { duration: 2000 }
          NumberAnimation {
            to: -(labelMetrics.width - labelClip.width)
            duration: Math.max(1200, (labelMetrics.width - labelClip.width) * 26)
            easing.type: Easing.InOutQuad
          }
          PauseAnimation { duration: 1600 }
          NumberAnimation { to: 0; duration: 600; easing.type: Easing.InOutQuad }
        }

        // Reset when the animation stops so a short title is not left offset.
        onTextChanged: x = 0
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.favorite && !root.vertical
      text: "\uf004"
      color: Color.accent
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }

    // Quality badge -- the point of this whole plugin, so it takes the accent
    // when the stream really is hi-res and stays muted when it is not.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showQuality && !root.vertical
      width: qualityText.implicitWidth + Style.space(8)
      height: qualityText.implicitHeight + Style.space(2)
      radius: Style.space(3)
      color: root.isHiRes
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.14)

      Text {
        textFormat: Text.PlainText
        id: qualityText
        anchors.centerIn: parent
        text: root.qualityLabel
        color: root.isHiRes ? Color.accent : Color.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onClicked: function(mouse) {
      if (!root.svc) return
      if (mouse.button === Qt.LeftButton) root.toggle()
      else if (mouse.button === Qt.RightButton) root.svc.openView("nowPlaying")
      else if (mouse.button === Qt.MiddleButton) root.svc.playPause()
    }

    onWheel: function(wheel) {
      if (!root.svc) return
      if (wheel.angleDelta.y > 0) root.svc.previous()
      else if (wheel.angleDelta.y < 0) root.svc.next()
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(mini.implicitHeight)

    MiniPlayer {
      id: mini
      anchors.fill: parent
      svc: root.svc
      foreground: Color.popups.text
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.menuFamily

      // Handing off to the overlay closes the popup: leaving it open behind a
      // full-screen surface would be two players on screen at once.
      onOpenPlayer: { root.close(); if (root.svc) root.svc.openView("search") }
      onOpenNowPlaying: { root.close(); if (root.svc) root.svc.openView("nowPlaying") }
      onOpenUri: function(uri, title) {
        root.close()
        if (root.svc) root.svc.openDetail(uri, title)
      }
    }
  }
}
