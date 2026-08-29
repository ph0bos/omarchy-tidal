import QtQuick
import qs.Ui
import qs.Commons
import "components"

// Tidal now-playing for the Omarchy bar.
//
// Interactions follow the conventions the stock widgets already teach:
//   left = play/pause · middle = next · scroll = prev/next · right = search
//
// All state is read from the plugin's service singleton, which is bound to
// Mopidy over MPRIS -- so this widget never polls and never talks HTTP itself.

BarWidget {
  id: root
  moduleName: "quickshell.tidal"

  readonly property var svc: bar?.shell?.serviceFor("quickshell.tidal") ?? null

  readonly property bool hasTrack: svc ? svc.hasTrack : false
  readonly property bool playing: svc ? svc.playing : false
  readonly property string title: svc ? svc.title : ""
  readonly property string artist: svc ? svc.artist : ""
  readonly property string artUrl: svc ? svc.artUrl : ""
  readonly property string qualityLabel: svc ? svc.qualityLabel : ""
  readonly property bool isHiRes: svc ? svc.isHiRes : false
  readonly property bool favorite: svc ? svc.favorite : false

  readonly property bool showQuality: setting("showQualityBadge", true) && qualityLabel !== ""
  readonly property real maxLabelWidth: setting("maxLabelWidth", 220)

  readonly property string label: {
    if (!title) return ""
    return artist ? (title + "  ·  " + artist) : title
  }

  // Stay out of the bar entirely when nothing is playing, exactly like the
  // stock media widget -- an empty Tidal slot is just noise.
  visible: hasTrack
  implicitWidth: !hasTrack ? 0 : (vertical ? barSize : content.implicitWidth + Style.space(14))
  implicitHeight: vertical ? content.implicitHeight + Style.space(10) : barSize

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(6)

    // Album art. Hidden on vertical bars where there is no room for it.
    RoundedImage {
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Style.space(16) : 0
      height: width
      radius: Style.space(2)
      visible: !root.vertical && root.artUrl !== ""
      source: root.artUrl
    }

    TideMark {
      anchors.verticalCenter: parent.verticalCenter
      gridSize: Style.font.body * 1.5
      color: root.playing
        ? (root.bar ? root.bar.barForeground : Color.bar.text)
        : Qt.darker(root.bar ? root.bar.barForeground : Color.bar.text, 1.6)
    }

    // Track label. Elided rather than scrolled: at bar sizes a marquee is more
    // distracting than informative, and the full text is in the tooltip.
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.vertical && root.label !== ""
      width: Math.min(implicitWidth, root.maxLabelWidth)
      text: root.label
      elide: Text.ElideRight
      color: root.bar ? root.bar.barForeground : Color.bar.text
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    // Heart, only when the track is actually favorited.
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.favorite && !root.vertical
      text: "󰋑"
      color: Color.accent
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // Quality badge -- the point of this whole plugin, so it gets the accent
    // color when the stream really is hi-res.
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

    onClicked: function(mouse) {
      if (!root.svc) return
      if (mouse.button === Qt.LeftButton) root.svc.playPause()
      else if (mouse.button === Qt.MiddleButton) root.svc.next()
      else if (mouse.button === Qt.RightButton) root.svc.openView("search")
    }

    onWheel: function(wheel) {
      if (!root.svc) return
      if (wheel.angleDelta.y > 0) root.svc.previous()
      else if (wheel.angleDelta.y < 0) root.svc.next()
    }
  }
}
