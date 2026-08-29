import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../lib/MopidyRpc.js" as Rpc
import "../lib/Library.js" as Library

// The full player: sidebar, browsable content, search, and transport.
//
// Everything in the sidebar is a plain `browse()` target, because mopidy-tidal
// already exposes the whole Tidal tree that way (tidal:home, tidal:hires,
// tidal:my_albums, ...). That keeps navigation to one code path instead of a
// special case per section.
//
// Keyboard model, matched to what people already expect from this kind of pane:
//   /  or Ctrl+F   focus search        Up/Down     move
//   Enter          play now            Shift+Enter queue
//   Right          open                Left/Bksp   back
//   Tab            sidebar <-> list    Esc         close
Item {
  id: root

  property var svc: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  property bool alive: true
  Component.onDestruction: root.alive = false

  // ---- navigation state ----
  property var rows: []
  property int selectedIndex: 0
  property string currentUri: ""
  property string currentTitle: "Home"
  property bool loading: false
  property string errorText: ""
  property int sidebarIndex: 1
  property bool sidebarFocused: false

  // Breadcrumb of {uri, title} so Left/Backspace can walk back out.
  property var history: []

  // When set, the content pane shows the rich artist/album page instead of a
  // list. Albums and artists have art, bios, reviews and credits worth showing;
  // a flat track list throws all of that away.
  property string detailUri: ""

  readonly property var navItems: Library.navigation()

  // Deep link, delivered as bound state rather than a method call so it cannot
  // race the Loader. The serial makes a repeat request of the same uri count.
  property string deepLinkUri: ""
  property string deepLinkTitle: ""
  property int deepLinkSerial: 0

  onDeepLinkSerialChanged: {
    if (root.deepLinkUri !== "") root.showDetail(root.deepLinkUri, root.deepLinkTitle)
    else if (root.currentUri === "") root.reset()
  }

  Component.onCompleted: {
    if (root.deepLinkUri !== "") root.showDetail(root.deepLinkUri, root.deepLinkTitle)
    else root.reset()
  }

  function reset() {
    root.history = []
    root.openTarget("tidal:home", "Home")
  }

  // ---- loading ----

  function openTarget(uri, title) {
    root.detailUri = ""
    if (uri === "queue") { loadQueue(); return }
    if (uri === "") { focusSearch(); return }

    root.currentUri = uri
    root.currentTitle = title || uri
    root.loading = true
    root.errorText = ""

    Rpc.browse(uri, function(refs) {
      if (!root.alive || root.currentUri !== uri) return
      var rows = Library.fromBrowse(refs)
      root.rows = rows
      root.selectedIndex = 0
      root.loading = false
      if (rows.length === 0) root.errorText = "Nothing here."
      // browse() returns bare Refs -- name and type only. Fill in artist and
      // album with one batched lookup so every track row is complete.
      root.enrich(rows, uri)
    }, function(err) {
      if (!root.alive || root.currentUri !== uri) return
      root.rows = []
      root.loading = false
      root.errorText = "Could not load: " + err
    })
  }

  // Mopidy caps how much it will look up in one call comfortably; a page of
  // rows at a time keeps the UI responsive on big libraries.
  readonly property int enrichLimit: 100

  function enrich(rows, forUri) {
    var uris = Library.trackUris(rows).slice(0, root.enrichLimit)
    if (uris.length === 0) return
    Rpc.lookup(uris, function(result) {
      if (!root.alive || root.currentUri !== forUri) return
      var merged = Library.mergeLookup(rows.slice(), result)
      root.rows = merged
    }, function() { /* rows stay as-is; a name is still usable */ })
  }

  function loadQueue() {
    root.currentUri = "queue"
    root.currentTitle = "Queue"
    root.loading = true
    root.errorText = ""

    Rpc.getTracklist(function(tlTracks) {
      if (!root.alive || root.currentUri !== "queue") return
      var out = []
      for (var i = 0; i < (tlTracks || []).length; i++) {
        var row = Library.fromTrack(tlTracks[i].track)
        if (row) out.push(row)
      }
      root.rows = out
      root.selectedIndex = 0
      root.loading = false
      if (out.length === 0) root.errorText = "The queue is empty."
    }, function(err) {
      if (!root.alive) return
      root.rows = []
      root.loading = false
      root.errorText = "Could not read the queue: " + err
    })
  }

  property string pendingQuery: ""

  function runSearch(query) {
    var q = String(query || "").trim()
    if (q.length === 0) return
    root.pendingQuery = q
    root.currentUri = "search:" + q
    root.currentTitle = "Search · " + q
    root.loading = true
    root.errorText = ""

    Rpc.search({ any: [q] }, null, function(results) {
      if (!root.alive || root.pendingQuery !== q) return
      root.rows = Library.flatten(Library.fromSearch(results))
      root.selectedIndex = root.rows.length && root.rows[0].header ? 1 : 0
      root.loading = false
      if (root.rows.length === 0) root.errorText = "No results for “" + q + "”."
    }, function(err) {
      if (!root.alive || root.pendingQuery !== q) return
      root.rows = []
      root.loading = false
      root.errorText = "Search failed: " + err
    })
  }

  // ---- actions ----

  function currentRow() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.rows.length) return null
    return root.rows[root.selectedIndex]
  }

  function playRow(row) {
    if (!row || !row.uri) return
    if (row.type === "track" || row.type === "album" || row.type === "playlist") {
      Rpc.playNow([row.uri], null, function(err) { if (root.alive) root.errorText = err })
    } else {
      openRow(row)
    }
  }

  function queueRow(row) {
    if (!row || !row.uri || row.type === "directory") return
    Rpc.queue([row.uri], function() {
      if (root.alive && root.svc) root.svc.osd("Added to queue", "media")
    }, function(err) { if (root.alive) root.errorText = err })
  }

  function openRow(row) {
    if (!row || !row.uri) return
    if (row.type === "track") { playRow(row); return }
    root.pushHistory()
    if (row.type === "album" || row.type === "artist") {
      root.showDetail(row.uri, row.name)
      return
    }
    root.openTarget(row.uri, row.name)
  }

  function pushHistory() {
    var next = root.history.slice()
    next.push({ uri: root.currentUri, title: root.currentTitle,
                index: root.selectedIndex, detail: root.detailUri })
    root.history = next
  }

  function showDetail(uri, title) {
    root.detailUri = uri
    root.currentTitle = title || uri
  }

  function goBack() {
    if (root.history.length === 0) return false
    var next = root.history.slice()
    var prev = next.pop()
    root.history = next
    if (prev.detail && prev.detail !== "") {
      root.showDetail(prev.detail, prev.title)
      return true
    }
    root.detailUri = ""
    if (prev.uri.indexOf("search:") === 0) root.runSearch(prev.uri.substring(7))
    else root.openTarget(prev.uri, prev.title)
    return true
  }

  function focusSearch() {
    searchField.forceActiveFocus()
    root.sidebarFocused = false
  }

  function moveSelection(delta) {
    if (root.rows.length === 0) return
    var i = root.selectedIndex
    do {
      i = Math.max(0, Math.min(root.rows.length - 1, i + delta))
      if (i === 0 && delta < 0 && root.rows[i].header) { i = root.selectedIndex; break }
    } while (root.rows[i] && root.rows[i].header && i > 0 && i < root.rows.length - 1)
    root.selectedIndex = i
    listView.positionViewAtIndex(i, ListView.Contain)
  }

  // ---- layout ----

  // Sidebar
  Rectangle {
    id: sidebar
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(168)
    color: "transparent"

    Column {
      anchors.fill: parent
      anchors.topMargin: Style.space(4)
      spacing: 1

      Repeater {
        model: root.navItems

        Rectangle {
          id: navRow
          required property int index
          required property var modelData

          width: sidebar.width
          height: Style.space(30)
          radius: Style.space(3)
          color: root.sidebarIndex === navRow.index && root.sidebarFocused
            ? Color.menu.selectedBackground
            : (root.currentUri === navRow.modelData.uri ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10) : "transparent")

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            spacing: Style.space(9)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Library.glyph(navRow.modelData.icon)
              color: root.currentUri === navRow.modelData.uri ? Color.accent : Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: navRow.modelData.label
              color: root.currentUri === navRow.modelData.uri ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          MouseArea {
            anchors.fill: parent
            onClicked: {
              root.sidebarIndex = navRow.index
              root.history = []
              root.openTarget(navRow.modelData.uri, navRow.modelData.label)
            }
          }
        }
      }
    }
  }

  Rectangle {
    anchors.left: sidebar.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Math.max(1, Style.space(1))
    color: Color.menu.border
    opacity: 0.4
  }

  // Content
  Item {
    id: content
    anchors.left: sidebar.right
    anchors.leftMargin: Style.space(12)
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom

    TextField {
      id: searchField
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.space(4)
      foreground: root.foreground
      accent: Color.accent
      onAccepted: {
        root.history = []
        root.runSearch(text)
        listView.forceActiveFocus()
      }
    }

    Text {
      id: crumb
      anchors.top: searchField.bottom
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      text: root.loading ? "Loading…" : root.currentTitle
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.1
    }

    Text {
      anchors.centerIn: parent
      visible: root.errorText !== "" && !root.loading && root.detailUri === ""
      text: root.errorText
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    DetailView {
      id: detail
      anchors.top: crumb.bottom
      anchors.topMargin: Style.space(8)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      visible: root.detailUri !== ""
      svc: root.svc
      uri: root.detailUri
      foreground: root.foreground
      fontFamily: root.fontFamily

      onOpenUri: function(uri, title) {
        root.pushHistory()
        root.showDetail(uri, title)
      }
    }

    ListView {
      id: listView
      visible: root.detailUri === ""
      anchors.top: crumb.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      clip: true
      model: root.rows
      currentIndex: root.selectedIndex
      boundsBehavior: Flickable.StopAtBounds

      delegate: TrackRow {
        required property int index
        required property var modelData

        width: listView.width
        row: modelData
        selected: index === root.selectedIndex && !root.sidebarFocused
        playing: root.svc && modelData && !modelData.header
                 && Library.sameTrack(root.svc.trackUri, modelData.uri)
        foreground: root.foreground
        accent: Color.accent
        fontFamily: root.fontFamily

        onActivated: { root.selectedIndex = index; root.playRow(modelData) }
        onQueued: { root.selectedIndex = index; root.queueRow(modelData) }
        onOpened: { root.selectedIndex = index; root.openRow(modelData) }
      }
    }
  }

  // ---- keyboard ----

  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

    if (event.key === Qt.Key_Slash || (ctrl && event.key === Qt.Key_F)) {
      root.focusSearch(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Tab) {
      root.sidebarFocused = !root.sidebarFocused; event.accepted = true; return
    }

    if (root.sidebarFocused) {
      if (event.key === Qt.Key_Down) {
        root.sidebarIndex = Math.min(root.navItems.length - 1, root.sidebarIndex + 1)
        event.accepted = true; return
      }
      if (event.key === Qt.Key_Up) {
        root.sidebarIndex = Math.max(0, root.sidebarIndex - 1)
        event.accepted = true; return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
        var item = root.navItems[root.sidebarIndex]
        root.history = []
        root.openTarget(item.uri, item.label)
        root.sidebarFocused = false
        event.accepted = true; return
      }
      return
    }

    if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true; return }
    if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true; return }
    if (event.key === Qt.Key_PageDown) { root.moveSelection(8); event.accepted = true; return }
    if (event.key === Qt.Key_PageUp) { root.moveSelection(-8); event.accepted = true; return }

    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      var row = root.currentRow()
      if (shift) root.queueRow(row); else root.playRow(row)
      event.accepted = true; return
    }
    if (event.key === Qt.Key_Right) { root.openRow(root.currentRow()); event.accepted = true; return }
    if (event.key === Qt.Key_Left || event.key === Qt.Key_Backspace) {
      if (root.goBack()) event.accepted = true
      return
    }
    if (event.key === Qt.Key_Space) {
      if (root.svc) root.svc.playPause()
      event.accepted = true; return
    }
  }
}
