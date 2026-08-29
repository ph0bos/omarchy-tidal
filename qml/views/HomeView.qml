import QtQuick
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/TidalApi.js" as Tidal

// Home, as TIDAL actually means it: the personalised shelves the real client
// opens on, not the folder list `browse(tidal:home)` returns.
//
// The companion answers /home with about twenty rows, each already carrying
// artwork urls, so the page arrives in one round trip instead of a browse per
// row. If the companion is not there, this says so once and the player falls
// back to the folder list -- Home should degrade to something, never to a
// blank pane.
//
// Rows are held after the first load. Coming back from an album should feel
// like returning to a page that was always there, not like fetching it again.
Item {
  id: root

  property var svc: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var rows: []
  property bool loading: false
  property bool loaded: false
  property string errorText: ""

  // ---- keyboard cursor ----
  //
  // -1 means the cursor is not on the page: nothing is highlighted until an
  // arrow key says otherwise, so opening Home does not look like something is
  // already chosen.
  property int selectedRow: -1
  property int selectedCol: 0

  readonly property int perRow: Design.fitCards(list.width, Style.space(12),
                                                Style.space(Design.cardIdeal))

  function rowLength(index) {
    if (index < 0 || index >= root.rows.length) return 0
    var items = root.rows[index].items || []
    return Math.min(items.length, root.perRow)
  }

  function moveRow(delta) {
    if (root.rows.length === 0) return
    if (root.selectedRow < 0) { root.select(0, 0); return }
    var next = Math.max(0, Math.min(root.rows.length - 1, root.selectedRow + delta))
    root.select(next, root.selectedCol)
  }

  function moveCol(delta) {
    if (root.rows.length === 0) return
    if (root.selectedRow < 0) { root.select(0, 0); return }
    root.select(root.selectedRow, root.selectedCol + delta)
  }

  function select(row, col) {
    var length = root.rowLength(row)
    if (length === 0) return
    root.selectedRow = row
    root.selectedCol = Math.max(0, Math.min(length - 1, col))
    list.positionViewAtIndex(row, ListView.Contain)
  }

  function selectedEntry() {
    if (root.selectedRow < 0 || root.selectedRow >= root.rows.length) return null
    var items = root.rows[root.selectedRow].items || []
    return items[root.selectedCol] || null
  }

  function openSelected() {
    var entry = root.selectedEntry()
    if (entry) root.openEntry(entry)
  }

  function playSelected() {
    var entry = root.selectedEntry()
    if (entry) root.playEntry(entry)
  }

  function clearSelection() { root.selectedRow = -1; root.selectedCol = 0 }

  signal openEntry(var entry)
  signal playEntry(var entry)
  // Raised when the companion cannot answer, so the caller can show the plain
  // browse list instead of leaving the user staring at an apology.
  signal unavailable()

  readonly property bool companionReady: svc ? svc.companionAvailable : false

  Component.onCompleted: root.load(false)

  // A shell restart can land here before the first health probe answers; load
  // again the moment the companion is known to be up.
  onCompanionReadyChanged: if (root.companionReady && !root.loaded) root.load(false)

  function load(force) {
    if (root.loading) return
    if (root.loaded && !force) return
    root.loading = true
    root.errorText = ""

    Tidal.home(function(payload) {
      if (!root.alive) return
      root.loading = false
      var rows = (payload && payload.rows) || []
      // Drop rows the account has nothing in; an empty heading is worse than
      // no heading.
      var kept = []
      for (var i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].items && rows[i].items.length) kept.push(rows[i])
      }
      root.rows = kept
      root.loaded = true
      if (kept.length === 0) root.unavailable()
    }, function(err) {
      if (!root.alive) return
      root.loading = false
      root.errorText = String(err)
      root.unavailable()
    })
  }

  // ---- shelves ----
  ListView {
    id: list
    anchors.fill: parent
    clip: true
    model: root.rows
    spacing: Style.space(26)
    boundsBehavior: Flickable.StopAtBounds
    // The last shelf should be able to clear the transport strip.
    bottomMargin: Style.space(10)

    opacity: root.rows.length > 0 ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic } }

    delegate: Shelf {
      required property var modelData

      width: list.width
      required property int index

      title: modelData && modelData.title ? String(modelData.title) : ""
      entries: modelData && modelData.items ? modelData.items : []
      selectedIndex: root.selectedRow === index ? root.selectedCol : -1
      foreground: root.foreground
      fontFamily: root.fontFamily

      onOpenEntry: function(entry) { root.openEntry(entry) }
      onPlayEntry: function(entry) { root.playEntry(entry) }
    }
  }

  ScrollHint {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    target: list
  }

  // ---- first load ----
  //
  // Blocks in the shape of the page rather than a spinner: the layout is
  // already known, so showing it settle is less of a jolt than a wait cursor
  // followed by a full page of content arriving at once.
  Column {
    anchors.fill: parent
    spacing: Style.space(26)
    visible: root.rows.length === 0 && root.errorText === ""
    opacity: root.loading || !root.loaded ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Design.fast } }

    Repeater {
      model: 3

      Column {
        width: parent.width
        spacing: Style.space(12)

        Rectangle {
          width: Style.space(130)
          height: Style.space(11)
          radius: Style.space(2)
          color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.16)
        }

        Row {
          spacing: Style.space(12)

          Repeater {
            model: Design.fitCards(parent.parent.width, Style.space(12),
                                   Style.space(Design.cardIdeal))

            Rectangle {
              width: Design.cardWidth(parent.parent.width, Style.space(12),
                                      Design.fitCards(parent.parent.width, Style.space(12),
                                                      Style.space(Design.cardIdeal)))
              height: width
              radius: Style.space(4)
              color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.10)
            }
          }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: root.errorText !== ""
    width: parent.width - Style.space(60)
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: "Home needs the companion extension.\n" + root.errorText
    color: Color.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
