import QtQuick
import QtQuick.Shapes
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
  // Light and shade, as a pair. A highlight on its own reads as a sticker over
  // the artwork; it only reads as a lit object once the far side falls away.
  property real sheen: 0.34
  property real shade: 0.38
  // How much the frame rises out of the page under the pointer.
  property real lift: 0.02
  // Named `leanEnabled`, not `enabled`: a property called `enabled` shadows
  // QQuickItem's, which silently changes whether children take input.
  property bool leanEnabled: true

  // Fed by the caller's own hover area, in this frame's coordinates.
  property bool active: false
  property real pointerX: 0
  property real pointerY: 0

  default property alias content: holder.data

  readonly property bool leaning: root.leanEnabled && root.active

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

    // Light and shade, drawn as one object.
    //
    // Both were Rectangle gradients to begin with, and both banded: a
    // Rectangle takes a linear gradient only along an axis, so the shading ran
    // horizontally whatever direction the light came from, and the highlight
    // was a stripe rather than a pool. Shapes gives a gradient a real vector
    // and a real centre, and the curve renderer antialiases the rounded edge
    // without a mask, so the light lands on the sleeve and stops there.
    Shape {
      id: lighting
      anchors.fill: parent
      z: 9
      preferredRendererType: Shape.CurveRenderer
      opacity: root.leaning ? 1 : 0
      visible: opacity > 0

      // How far from centre the pointer is, 0..1. Light arriving straight on
      // casts no shadow, so the effect fades out as the pointer crosses the
      // middle rather than flipping sides through a hard edge.
      readonly property real throw_: Math.min(1,
        Math.sqrt(root.offsetX * root.offsetX + root.offsetY * root.offsetY) / 0.5)

      // The far side falls away. Black, not the theme background: a shadow is
      // the absence of light on both a dark theme and a light one.
      ShapePath {
        strokeWidth: -1
        fillGradient: LinearGradient {
          // Lit end towards the pointer, dark end directly opposite. Running
          // the vector past the edges keeps the falloff gentle across the
          // face instead of ending inside it.
          x1: lighting.width * (0.5 + root.offsetX * 1.6)
          y1: lighting.height * (0.5 + root.offsetY * 1.6)
          x2: lighting.width * (0.5 - root.offsetX * 1.6)
          y2: lighting.height * (0.5 - root.offsetY * 1.6)
          GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
          GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0) }
          GradientStop {
            position: 1
            color: Qt.rgba(0, 0, 0, root.shade * lighting.throw_)
          }
        }
        PathRectangle {
          width: lighting.width
          height: lighting.height
          radius: root.radius
        }
      }

      // The highlight: a pool of light under the pointer, not a sheen bar.
      ShapePath {
        strokeWidth: -1
        fillGradient: RadialGradient {
          centerX: lighting.width * (0.5 + root.offsetX)
          centerY: lighting.height * (0.5 + root.offsetY)
          centerRadius: Math.max(lighting.width, lighting.height) * 0.62
          focalX: centerX
          focalY: centerY
          GradientStop {
            position: 0
            color: Qt.rgba(1, 1, 1, root.sheen * lighting.throw_)
          }
          GradientStop {
            position: 0.4
            color: Qt.rgba(1, 1, 1, root.sheen * lighting.throw_ * 0.34)
          }
          GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
        }
        PathRectangle {
          width: lighting.width
          height: lighting.height
          radius: root.radius
        }
      }

      Behavior on opacity { NumberAnimation { duration: Design.base } }
    }

    scale: root.leaning ? 1 + root.lift : 1
    Behavior on scale {
      NumberAnimation {
        duration: root.leaning ? Design.base : Design.slow
        easing.type: root.leaning ? Easing.OutCubic : Easing.OutBack
        easing.overshoot: 1.1
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
            easing.type: root.leaning ? Easing.OutCubic : Easing.OutBack
            easing.overshoot: 1.2
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
            easing.type: root.leaning ? Easing.OutCubic : Easing.OutBack
            easing.overshoot: 1.2
          }
        }
      }
    ]
  }
}
