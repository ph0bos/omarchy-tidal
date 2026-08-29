import QtQuick

// The "Crest" mark, drawn natively rather than loaded from assets/icon.svg.
//
// Drawing it keeps the mark crisp at any bar height and lets it take a theme
// colour directly, with no SVG recolour or rasterisation step.
//
// Geometry mirrors assets/icon.svg exactly, on the same 32-unit grid: five
// rectangles, square terminals, every edge on a whole unit. That squareness is
// the point -- Omarchy's own logo is orthogonal throughout, and the rounded
// caps this used to have were the one thing about the mark that was not.
Item {
  id: root

  // Nominal size of the 32-unit design grid. The drawn mark is smaller than
  // this, because the grid includes the surrounding padding.
  property real gridSize: 16

  // Height of the drawn mark, which is the measurement a caller actually has
  // in mind when it says "as tall as the text". Setting it drives the grid;
  // leaving it at 0 keeps gridSize in charge.
  property real markHeight: 0

  property color color: "white"

  readonly property real u: markHeight > 0 ? markHeight / 24 : gridSize / 32

  // Left edge and top of each bar, in grid units.
  readonly property var lefts: [2, 8, 14, 20, 26]
  readonly property var tops: [18, 10, 4, 8, 14]
  readonly property real barWidth: 4
  readonly property real bottomY: 28

  // Content bounds, so callers can lay this out without knowing the padding.
  readonly property real originX: 2
  readonly property real originY: 4

  implicitWidth: 28 * u
  implicitHeight: 24 * u

  // The bars stand on the mark's bottom edge, so that is its baseline. Set it
  // and a wordmark beside it can align to the same line the letters sit on,
  // instead of centring two boxes of different heights against each other --
  // which is what made the mark look like it was floating above the word.
  baselineOffset: implicitHeight

  Repeater {
    model: 5

    Rectangle {
      id: bar
      required property int index

      width: root.barWidth * root.u
      height: (root.bottomY - root.tops[bar.index]) * root.u
      x: (root.lefts[bar.index] - root.originX) * root.u
      y: (root.tops[bar.index] - root.originY) * root.u
      color: root.color

      Behavior on color { ColorAnimation { duration: 140 } }
    }
  }
}
