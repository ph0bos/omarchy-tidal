import QtQuick
import qs.Commons
import "../lib/Design.js" as Design

// A frame that leans toward the pointer, with a highlight that follows it.
//
// TIDAL's own client tilts the sleeve under the cursor and runs a sheen across
// it, and on a page whose whole subject is a record it is the one flourish
// worth having: the artwork stops being a picture of an object and starts
// behaving like one.
//
// Kept honest by three constraints:
//
//   - Small angles. Past about eight degrees a square starts to read as a
//     mistake in the layout rather than as a tilt.
//   - It does not listen for the pointer itself. Two overlapping hover areas
//     means only the topmost one hears anything, and every surface that wants
//     a tilt already has a MouseArea for its click. The caller passes what it
//     already knows, and this stays a presentation component.
//   - It returns slowly and leans quickly. Snapping back is what makes these
//     effects feel cheap.
Item {
  id: root

  property real maxAngle: 8
  property real radius: 0
  // The sheen's strength at its brightest. 0 turns it off entirely.
  property real sheen: 0.14
  property bool enabled: true

  // Fed by the caller's own hover area, in this frame's coordinates.
  property bool active: false
  property real pointerX: 0
  property real pointerY: 0

  default property alias content: holder.data

  readonly property bool leaning: root.enabled && root.active

  // Pointer position as -0.5..0.5 from the centre, which is what the angles
  // and the highlight are both expressed in.
  readonly property real offsetX: root.leaning
    ? Math.max(-0.5, Math.min(0.5, root.pointerX / Math.max(1, width) - 0.5)) : 0
  readonly property real offsetY: root.leaning
    ? Math.max(-0.5, Math.min(0.5, root.pointerY / Math.max(1, height) - 0.5)) : 0

  // Lean towards the cursor: pointing at the top of the sleeve tips its top
  // away from you, which is how a real object hinges.
  readonly property real angleX: -root.offsetY * root.maxAngle * 2
  readonly property real angleY: root.offsetX * root.maxAngle * 2

  Item {
    id: holder
    anchors.fill: parent

    // A highlight that tracks the pointer across the artwork. Horizontal
    // rather than diagonal so it can share the frame's corner radius exactly;
    // a rotated sheen would need a second mask to stay inside the rounding.
    Rectangle {
      anchors.fill: parent
      radius: root.radius
      visible: root.sheen > 0
      opacity: root.leaning ? 1 : 0
      z: 10

      readonly property real centre: 0.5 + root.offsetX * 0.6

      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop {
          position: Math.max(0, parent.centre - 0.32)
          color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0)
        }
        GradientStop {
          position: parent.centre
          color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, root.sheen)
        }
        GradientStop {
          position: Math.min(1, parent.centre + 0.32)
          color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0)
        }
      }

      Behavior on opacity { NumberAnimation { duration: Design.base } }
    }
  }

  transform: [
    Rotation {
      origin.x: root.width / 2
      origin.y: root.height / 2
      axis { x: 1; y: 0; z: 0 }
      angle: root.angleX
      Behavior on angle {
        // Quick to lean, slow to settle: a snap back is what makes this kind
        // of effect feel cheap.
        NumberAnimation {
          duration: root.leaning ? Design.fast : Design.slow
          easing.type: Easing.OutCubic
        }
      }
    },
    Rotation {
      origin.x: root.width / 2
      origin.y: root.height / 2
      axis { x: 0; y: 1; z: 0 }
      angle: root.angleY
      Behavior on angle {
        NumberAnimation {
          duration: root.leaning ? Design.fast : Design.slow
          easing.type: Easing.OutCubic
        }
      }
    }
  ]
}
