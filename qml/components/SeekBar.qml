import QtQuick
import qs.Commons
import "../lib/Design.js" as Design

// The playhead: a rail, a filled portion, a grab handle, and optionally the
// two times either side of it.
//
// Scrubbing previews locally and commits one seek on release. Dragging fires on
// every mouse move, and a seek per move floods Mopidy and makes the audio
// stutter under the cursor -- so the service's clock is moved directly while
// the handle is held and the backend is told once, at the end.
//
// Shared by the transport strip and the bar's mini player: one playhead, one
// set of behaviours, rather than two that drift apart.
Item {
  id: root

  property var svc: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property bool showTimes: true
  property int railHeight: Style.space(4)

  readonly property real position: svc ? svc.position : 0
  readonly property real length: svc ? svc.length : 0
  readonly property real progress: length > 0
    ? Math.max(0, Math.min(1, position / length)) : 0

  property bool scrubbing: false

  implicitHeight: Style.space(26)

  function fractionToMs(fraction) {
    return Math.max(0, Math.min(1, fraction)) * root.length * 1000
  }

  function previewFraction(fraction) {
    if (!root.svc || root.length <= 0) return
    root.svc.previewSeek(root.fractionToMs(fraction))
  }

  function commitFraction(fraction) {
    if (!root.svc || root.length <= 0) return
    root.svc.commitSeek(root.fractionToMs(fraction))
  }

  Text {
    textFormat: Text.PlainText
    id: elapsed
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.showTimes ? Style.space(34) : 0
    visible: root.showTimes
    text: Design.clock(root.position)
    color: Color.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
  }

  Text {
    textFormat: Text.PlainText
    id: total
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: root.showTimes ? Style.space(34) : 0
    visible: root.showTimes
    text: Design.clock(root.length)
    color: Color.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Item {
    id: track
    anchors.left: elapsed.right
    anchors.right: total.left
    anchors.leftMargin: root.showTimes ? Style.space(9) : 0
    anchors.rightMargin: root.showTimes ? Style.space(9) : 0
    anchors.verticalCenter: parent.verticalCenter
    height: parent.height

    Rectangle {
      id: rail
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: root.railHeight
      radius: height / 2
      color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.28)

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * root.progress
        radius: parent.radius
        color: Color.accent
      }
    }

    // Grows under the cursor so the bar reads as grabbable.
    Rectangle {
      id: knob
      width: seekMouse.containsMouse || root.scrubbing ? Style.space(11) : Style.space(8)
      height: width
      radius: width / 2
      color: Color.accent
      anchors.verticalCenter: rail.verticalCenter
      x: Math.max(0, Math.min(rail.width, rail.width * root.progress)) - width / 2
      visible: root.length > 0

      Behavior on width { NumberAnimation { duration: Design.fast } }
    }

    MouseArea {
      id: seekMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      preventStealing: true

      onPressed: function(mouse) {
        root.scrubbing = true
        root.previewFraction(mouse.x / width)
      }
      onPositionChanged: function(mouse) {
        if (root.scrubbing) root.previewFraction(mouse.x / width)
      }
      onReleased: function(mouse) {
        if (!root.scrubbing) return
        root.scrubbing = false
        root.commitFraction(mouse.x / width)
      }
      onCanceled: root.scrubbing = false
    }
  }
}
