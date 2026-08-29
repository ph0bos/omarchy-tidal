import QtQuick
import qs.Commons
import "../lib/Design.js" as Design

// A slim scroll position indicator that appears while you are moving and fades
// out once you stop.
//
// Omarchy's panels have no scrollbars, and for a list of a dozen rows that is
// the right call. A library view is a different thing: "My Albums" is twelve
// hundred rows deep, and with no indicator there is nothing on screen that says
// how far in you are or how much is left. So this shows only while the content
// is actually moving -- present when it is useful, gone when it is not.
Item {
  id: root

  property Flickable target: null
  property int thickness: Style.space(3)
  property int minLength: Style.space(28)

  readonly property real span: target ? target.contentHeight - target.height : 0
  readonly property bool scrollable: span > 1

  // Held visible for a moment after the movement stops, so the fade reads as
  // settling rather than as a flicker.
  property bool showing: false

  visible: scrollable
  width: thickness
  // Above the content it describes, wherever it is declared.
  z: 5

  Connections {
    target: root.target
    enabled: root.target !== null
    function onContentYChanged() {
      if (!root.scrollable) return
      root.showing = true
      hide.restart()
    }
  }

  Timer {
    id: hide
    interval: 900
    onTriggered: root.showing = false
  }

  Rectangle {
    id: bar
    width: root.thickness
    radius: width / 2
    color: Color.muted
    opacity: root.showing || (root.target && root.target.moving) ? 0.45 : 0

    height: root.scrollable
      ? Math.max(root.minLength, root.height * (root.target.height / root.target.contentHeight))
      : 0
    y: root.scrollable
      ? (root.height - height) * Math.max(0, Math.min(1, root.target.contentY / root.span))
      : 0

    Behavior on opacity { NumberAnimation { duration: Design.slow } }
  }
}
