import QtQuick
import qs.Ui
import qs.Commons
import "lib/TidalApi.js" as Tidal
import "components"

// TIDAL now-playing for the Omarchy bar.
//
//   left = open the player · right = now playing · middle = play/pause
//   scroll = previous / next
//
// Clicking the widget opens the app. The stock media widget toggles playback on
// a left click, but this is a full application and the obvious result of
// clicking its icon is that the application opens.
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

  // Album art already identifies the widget; showing the TIDAL mark next to it
  // is two logos for one thing. The mark stands in only when there is no art.
  readonly property bool showMark: !hasArt || root.vertical
  readonly property bool hasArt: artUrl !== ""

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

    // Track label. Elided by default; long titles scroll instead of truncating
    // so the whole thing is readable without a tooltip.
    Item {
      id: labelClip
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.vertical && root.label !== ""
      width: Math.min(labelText.implicitWidth, root.maxLabelWidth)
      height: labelText.implicitHeight
      clip: true

      readonly property bool overflowing: labelText.implicitWidth > width + 1
      readonly property bool scrolling: overflowing && root.scrollLongLabels

      Text {
        id: labelText
        text: root.label
        color: root.bar ? root.bar.barForeground : Color.bar.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        // Only elide when not scrolling, otherwise the ellipsis scrolls too.
        elide: labelClip.scrolling ? Text.ElideNone : Text.ElideRight
        width: labelClip.scrolling ? implicitWidth : labelClip.width

        // Pause at each end so the start and end are both readable.
        SequentialAnimation on x {
          running: labelClip.scrolling && root.hasTrack
          loops: Animation.Infinite
          PauseAnimation { duration: 2000 }
          NumberAnimation {
            to: -(labelText.implicitWidth - labelClip.width)
            duration: Math.max(1200, (labelText.implicitWidth - labelClip.width) * 26)
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
      anchors.verticalCenter: parent.verticalCenter
      visible: root.favorite && !root.vertical
      text: ""
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
      if (mouse.button === Qt.LeftButton) root.svc.openView("search")
      else if (mouse.button === Qt.RightButton) root.svc.openView("nowPlaying")
      else if (mouse.button === Qt.MiddleButton) root.svc.playPause()
    }

    onWheel: function(wheel) {
      if (!root.svc) return
      if (wheel.angleDelta.y > 0) root.svc.previous()
      else if (wheel.angleDelta.y < 0) root.svc.next()
    }
  }
}
