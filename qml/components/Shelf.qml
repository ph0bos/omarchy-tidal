import QtQuick
import qs.Commons
import "../lib/Design.js" as Design

// One titled row of artwork on the Home page.
//
// The shelf does not scroll sideways. In a panel this size a horizontal
// scroller inside a vertical one is a trap: the wheel does the wrong thing,
// and half of every row sits permanently out of sight. So a shelf shows the
// cards that fit at a legible size and stops -- these are suggestions, and
// there are twenty more rows underneath. Card width is shared out from the
// same grid on every shelf, so the columns line up down the whole page.
Item {
  id: root

  property string title: ""
  property var entries: []
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  // -1 when the cursor is not on this shelf.
  property int selectedIndex: -1

  signal openEntry(var entry)
  signal playEntry(var entry)

  readonly property int gutter: Style.space(12)
  readonly property int fits: Design.fitCards(width, gutter, Style.space(Design.cardIdeal))
  readonly property int shown: Math.min(entries ? entries.length : 0, fits)
  // Sized from the grid, not from how many this shelf happens to have. Taking
  // the count from `shown` let a five-item row spread into fat tiles while the
  // row above it stayed narrow, and the page lost its columns.
  readonly property int cardWidth: Design.cardWidth(width, gutter, fits)

  visible: shown > 0
  height: visible ? heading.height + Style.space(12) + cards.height : 0

  Text {
    textFormat: Text.PlainText
    id: heading
    anchors.left: parent.left
    anchors.top: parent.top
    width: parent.width
    text: root.title
    elide: Text.ElideRight
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.weight: Font.DemiBold
  }

  Row {
    id: cards
    anchors.top: heading.bottom
    anchors.topMargin: Style.space(12)
    anchors.left: parent.left
    spacing: root.gutter

    Repeater {
      model: root.shown

      ArtCard {
        required property int index

        width: root.cardWidth
        entry: root.entries[index]
        selected: index === root.selectedIndex
        foreground: root.foreground
        fontFamily: root.fontFamily

        onOpened: root.openEntry(root.entries[index])
        onActivated: root.playEntry(root.entries[index])
      }
    }
  }
}
