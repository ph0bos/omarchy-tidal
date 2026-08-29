import QtQuick

// The "Crest" mark, drawn natively rather than loaded from assets/icon.svg.
//
// Drawing it keeps the mark crisp at any bar height and lets it take a theme
// color directly, with no SVG recolor or rasterization step.
//
// Geometry mirrors assets/icon.svg exactly, on the same 32-unit grid. The SVG
// uses stroke-linecap="round", which extends each line by half the 3.2 stroke
// at both ends, so the rounded rectangles here span the stroke's *visual*
// extent: top - 1.6 through 27 + 1.6.
Item {
  id: root

  // Nominal size of the 32-unit design grid. The drawn mark is smaller than
  // this, because the grid includes the SVG's surrounding padding.
  property real gridSize: 16
  property color color: "white"

  readonly property real u: gridSize / 32

  // Bar center x, and the visual top y of each bar, in grid units.
  readonly property var centers: [4, 10, 16, 22, 28]
  readonly property var tops: [16.4, 8.4, 3.4, 7.4, 13.4]
  readonly property real bottomY: 28.6

  // Content bounds, so callers can lay this out without knowing the padding.
  readonly property real originX: 2.4
  readonly property real originY: 3.4

  implicitWidth: 27.2 * u
  implicitHeight: 25.2 * u

  Repeater {
    model: 5

    Rectangle {
      id: bar
      required property int index

      width: 3.2 * root.u
      height: (root.bottomY - root.tops[bar.index]) * root.u
      x: (root.centers[bar.index] - 1.6 - root.originX) * root.u
      y: (root.tops[bar.index] - root.originY) * root.u
      radius: width / 2
      color: root.color

      Behavior on color { ColorAnimation { duration: 140 } }
    }
  }
}
