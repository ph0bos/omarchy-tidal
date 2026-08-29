import QtQuick
import qs.Commons

// A small icon button for the overlay header. Quiet until hovered, accented
// while its view is the active one -- the same restraint the bar's own chips
// use, so the header reads as part of Omarchy rather than bolted on.
Item {
  id: root

  property string glyph: ""
  property string tooltip: ""
  property bool active: false
  property bool interactive: true
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  signal activated()

  implicitWidth: Style.space(26)
  implicitHeight: Style.space(24)
  width: implicitWidth
  height: implicitHeight
  opacity: root.interactive ? 1.0 : 0.3

  Rectangle {
    anchors.fill: parent
    radius: Style.space(3)
    color: root.active
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
      : (hover.containsMouse && root.interactive ? Color.menu.selectedBackground : "transparent")

    Behavior on color { ColorAnimation { duration: 110 } }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: root.glyph
    color: root.active ? Color.accent
                       : (hover.containsMouse && root.interactive ? root.foreground : Color.muted)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.interactive
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  // Label on hover, matching the bar's tooltip weight.
  Rectangle {
    visible: hover.containsMouse && root.tooltip !== ""
    anchors.top: parent.bottom
    anchors.topMargin: Style.space(4)
    anchors.horizontalCenter: parent.horizontalCenter
    width: tip.implicitWidth + Style.space(12)
    height: tip.implicitHeight + Style.space(6)
    radius: Style.space(3)
    color: Color.tooltip.background
    border.width: 1
    border.color: Color.tooltip.border
    z: 200

    Text {
      textFormat: Text.PlainText
      id: tip
      anchors.centerIn: parent
      text: root.tooltip
      color: Color.tooltip.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
