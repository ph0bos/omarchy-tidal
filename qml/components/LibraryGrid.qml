import QtQuick
import qs.Commons
import "../lib/Design.js" as Design

// A wall of covers, for the parts of the library that are records and people.
//
// My Albums and My Artists were lists: one line each, a 34px thumbnail, and two
// thirds of the row empty to the right of it. Apple Music and TIDAL both open
// those on a grid, because a record is recognised by its sleeve long before its
// title is read, and because a name in a list tells you nothing you did not
// already know when you went looking for it.
//
// It indexes the same rows and the same selected index as the list it stands
// in for, so the sidebar, Tab, paging and every action keep working unchanged.
// Only the geometry differs -- and that Up and Down move by a row of cards.
Item {
  id: root

  property var rows: []
  property int selectedIndex: 0
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  signal openEntry(var entry)
  signal playEntry(var entry)
  signal selectRequested(int index)
  // Emitted with a page and a half of runway left, so the next page is already
  // in hand by the time this one runs out.
  signal nearEnd()

  readonly property real gutter: Style.space(12)
  readonly property int perRow: Math.max(1,
    Design.fitCards(grid.width, root.gutter, Design.cardIdeal))
  // The grid's own sum, not the shelf's: a cell carries its gutter, so a row of
  // n cells is n cards and n gutters rather than n-1.
  readonly property real cardWidth:
    Design.gridCardWidth(grid.width, root.gutter, root.perRow)

  // A GridView needs one cell height for every delegate, and a card's height is
  // its artwork plus two lines of label. ArtCard holds the second line even
  // when it is empty, so this is the same for a record and for a person.
  FontMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
  readonly property real labelBlock: Style.space(9)
    - (labelMetrics.ascent - labelMetrics.capitalHeight)
    + labelMetrics.height * 2 + Style.space(2)

  function position(index) {
    grid.positionViewAtIndex(Math.max(0, index), GridView.Contain)
  }

  GridView {
    id: grid
    anchors.fill: parent
    clip: true
    model: root.rows
    currentIndex: root.selectedIndex
    cellWidth: root.cardWidth + root.gutter
    cellHeight: root.cardWidth + root.labelBlock + root.gutter
    boundsBehavior: Flickable.StopAtBounds

    onContentYChanged: {
      if (contentHeight <= 0) return
      if (contentY > contentHeight - height * 1.5) root.nearEnd()
    }

    // The cell is the card plus its gutter, so the cards sit on a grid rather
    // than stretching to fill one.
    delegate: Item {
      id: cell
      required property int index
      required property var modelData

      width: grid.cellWidth
      height: grid.cellHeight

      ArtCard {
        width: root.cardWidth
        entry: cell.modelData
        selected: cell.index === root.selectedIndex
        foreground: root.foreground
        fontFamily: root.fontFamily

        onOpened: {
          root.selectRequested(cell.index)
          root.openEntry(cell.modelData)
        }
        onActivated: {
          root.selectRequested(cell.index)
          root.playEntry(cell.modelData)
        }
      }
    }
  }

  ScrollHint {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    target: grid
  }
}
