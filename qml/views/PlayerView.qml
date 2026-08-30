import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../lib/MopidyRpc.js" as Rpc
import "../lib/Library.js" as Library
import "../lib/Design.js" as Design
import "../lib/TidalApi.js" as Tidal

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
//
// On Home the arrows walk the artwork grid instead -- up and down between
// shelves, left and right along one -- and Enter opens the card's page while
// Shift+Enter starts it, which is what the two halves of the card do to the
// mouse.
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
  property int sidebarIndex: 0
  property bool sidebarFocused: false

  // Breadcrumb of {uri, title} so Left/Backspace can walk back out.
  property var history: []

  // When set, the content pane shows the rich artist/album page instead of a
  // list. Albums and artists have art, bios, reviews and credits worth showing;
  // a flat track list throws all of that away.
  property string detailUri: ""

  // Home is the personalised shelf page, not a browse target -- unless the
  // companion cannot answer, in which case we fall back to browsing
  // tidal:home and the folder list it returns.
  property bool homeFallback: false

  // Your own albums, artists, tracks and playlists come from the companion as
  // whole objects rather than as browse refs, so a row arrives knowing who made
  // it. Paged, because a library of a thousand albums is twenty round trips to
  // Tidal and the first screen should not wait for the twentieth.
  property string librarySection: ""
  property int libraryOffset: 0
  property bool libraryMore: false
  property bool libraryLoading: false
  property bool libraryFallback: false

  readonly property int libraryPageSize: 100
  readonly property bool homeActive: root.currentUri === "tidal:home"
    && root.detailUri === "" && !root.homeFallback

  readonly property var navItems: Library.navigation()

  // Filing a track away is the host's job -- the picker is raised over the
  // whole card, not inside this pane.
  signal addToPlaylist(string uri, string title)

  // The quick menu and the keyboard map are the host's, so this only asks.
  signal menuRequested()
  signal shortcutsRequested()

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
    if (uri !== "tidal:home") homePage.clearSelection()
    if (uri === "queue") { loadQueue(); return }
    if (uri === "") { focusSearch(); return }

    // Favourites come from the companion, whole.
    var section = Library.librarySection(uri)
    if (section !== "" && !root.libraryFallback
        && root.svc && root.svc.companionAvailable) {
      root.currentUri = uri
      root.currentTitle = title || uri
      root.rows = []
      root.selectedIndex = 0
      root.errorText = ""
      root.librarySection = section
      root.libraryOffset = 0
      root.libraryMore = false
      root.loadLibraryPage(true)
      return
    }
    root.librarySection = ""

    // The shelf page owns tidal:home. Browsing it as well would spend a round
    // trip on a folder list nobody is going to see.
    if (uri === "tidal:home" && !root.homeFallback) {
      root.currentUri = uri
      root.currentTitle = title || "Home"
      root.rows = []
      root.selectedIndex = 0
      root.loading = false
      root.errorText = ""
      return
    }

    root.currentUri = uri
    root.currentTitle = title || uri
    // Cleared, not left standing: a page that shows the previous section's
    // rows under the new section's title is lying while it waits.
    root.rows = []
    root.selectedIndex = 0
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

  function loadLibraryPage(first) {
    if (root.libraryLoading || root.librarySection === "") return
    if (!first && !root.libraryMore) return

    root.libraryLoading = true
    if (first) root.loading = true

    var forUri = root.currentUri
    var section = root.librarySection
    var offset = first ? 0 : root.libraryOffset

    Tidal.library(section, root.libraryPageSize, offset, function(payload) {
      if (!root.alive || root.currentUri !== forUri) return
      root.libraryLoading = false
      root.loading = false

      var items = (payload && payload.items) || []
      var rows = Library.fromEntries(items)
      root.rows = first ? rows : root.rows.concat(rows)
      root.libraryOffset = offset + items.length
      root.libraryMore = !!(payload && payload.more) && items.length > 0
      if (root.rows.length === 0) root.errorText = "Nothing here."
    }, function(err) {
      if (!root.alive || root.currentUri !== forUri) return
      root.libraryLoading = false
      root.loading = false
      if (!first) return
      // One fall back to browsing, for the rest of the session: a companion
      // that cannot answer for albums will not answer for artists either.
      root.libraryFallback = true
      root.librarySection = ""
      root.openTarget(forUri, root.currentTitle)
    })
  }

  // Fetch the next page before the list runs out, so scrolling does not stop
  // at a boundary the reader can feel.
  function maybeLoadMore(index) {
    if (root.librarySection === "" || !root.libraryMore) return
    if (index >= root.rows.length - 20) root.loadLibraryPage(false)
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
    root.rows = []
    root.selectedIndex = 0
    root.loading = true
    root.errorText = ""

    Rpc.getTracklist(function(tlTracks) {
      if (!root.alive || root.currentUri !== "queue") return
      var out = []
      for (var i = 0; i < (tlTracks || []).length; i++) {
        var row = Library.fromTrack(tlTracks[i].track)
        if (!row) continue
        // The tracklist id, kept so a row can be removed or played by name.
        // The same track can be in the queue twice and a uri cannot tell them
        // apart.
        row.tlid = tlTracks[i].tlid
        row.queued = true
        out.push(row)
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
    root.rows = []
    root.selectedIndex = 0
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

  // In the queue, playing a row means jumping to that entry rather than
  // starting a new tracklist from it.
  function playQueueRow(row) {
    if (!row || row.tlid === undefined) return
    Rpc.playTlid(row.tlid, null, function(err) { if (root.alive) root.errorText = err })
  }

  function removeQueueRow(row) {
    if (!row || row.tlid === undefined) return
    var gone = row.tlid
    Rpc.removeTlid(gone, function() {
      if (!root.alive) return
      // Drop it locally rather than re-reading the whole tracklist: the list
      // keeps its scroll position and the cursor stays where the eye is.
      var next = []
      for (var i = 0; i < root.rows.length; i++) {
        if (root.rows[i].tlid !== gone) next.push(root.rows[i])
      }
      root.rows = next
      root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, next.length - 1))
      if (next.length === 0) root.errorText = "The queue is empty."
    }, function(err) { if (root.alive) root.errorText = err })
  }

  // Reorder the queue from the keyboard. The list is mirrored locally on
  // success rather than re-read: the rows are already here, and re-reading
  // would throw away the scroll position and the cursor mid-gesture, which is
  // the one thing you cannot afford while dragging something into place.
  function moveQueueRow(delta) {
    if (root.currentUri !== "queue") return
    var from = root.selectedIndex
    var to = from + delta
    if (from < 0 || from >= root.rows.length) return
    if (to < 0 || to >= root.rows.length) return

    Rpc.moveTrack(from, to, function() {
      if (!root.alive) return
      var next = root.rows.slice()
      next.splice(to, 0, next.splice(from, 1)[0])
      root.rows = next
      root.selectedIndex = to
      listView.positionViewAtIndex(to, ListView.Contain)
    }, function(err) { if (root.alive) root.errorText = err })
  }

  function clearQueue() {
    Rpc.clear(function() {
      if (!root.alive) return
      root.rows = []
      root.selectedIndex = 0
      root.errorText = "The queue is empty."
      if (root.svc) root.svc.osd("Queue cleared", "media")
    }, function(err) { if (root.alive) root.errorText = err })
  }

  function playRow(row) {
    if (!row || !row.uri) return
    if (row.queued === true) { root.playQueueRow(row); return }
    if (row.type === "track" || row.type === "album") {
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
    if (row.type === "album" || row.type === "artist" || row.type === "playlist") {
      root.showDetail(row.uri, row.name)
      return
    }
    root.openTarget(row.uri, row.name)
  }

  // A Home card carries the same shapes the rest of the player deals in, so
  // opening one lands in the page it deserves: albums and artists have real
  // pages, everything else is a browse target, and a track just plays.
  function openEntry(entry) {
    if (!entry || !entry.uri) return
    var uri = String(entry.uri)
    var type = String(entry.type || "")
    if (type === "track") { root.playEntry(entry); return }
    root.pushHistory()
    if (type === "album" || type === "artist" || type === "playlist") {
      root.showDetail(uri, String(entry.name || ""))
      return
    }
    root.openTarget(uri, String(entry.name || uri))
  }

  function playEntry(entry) {
    if (!entry || !entry.uri) return
    Rpc.playNow([String(entry.uri)], null,
                function(err) { if (root.alive) root.errorText = err })
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
    root.maybeLoadMore(i)
    listView.positionViewAtIndex(i, ListView.Contain)
  }

  // ---- layout ----

  // Sidebar
  Rectangle {
    id: sidebar
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(150)
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
            : (root.detailUri === "" && root.currentUri === navRow.modelData.uri
               ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10) : "transparent")

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            spacing: Style.space(9)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: Library.glyph(navRow.modelData.icon)
              color: root.detailUri === "" && root.currentUri === navRow.modelData.uri ? Color.accent : Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: navRow.modelData.label
              color: root.detailUri === "" && root.currentUri === navRow.modelData.uri ? Color.accent : root.foreground
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
    anchors.leftMargin: Style.space(16)
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom

    // ---- page header ----
    //
    // Where you are on the left, the way out on the right. The old layout
    // stacked a full-width empty input above a whispered breadcrumb, which
    // put the least interesting thing on the page in the most prominent
    // position. Search is a tool here, not the subject.
    Item {
      id: pageHeader
      anchors.top: parent.top
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(30)

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: clearQueue.visible ? clearQueue.left : searchField.left
        anchors.rightMargin: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        // A detail page carries its own name at display size a few pixels
        // below this; printing it twice made the header look like a mistake.
        visible: root.detailUri === ""
        text: root.currentTitle
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.weight: Font.DemiBold
        // Dimmed rather than replaced with the word "Loading": the title is
        // still true while the page underneath it is arriving.
        opacity: root.loading ? 0.4 : 1
        Behavior on opacity { NumberAnimation { duration: Design.base } }
      }

      Text {
        textFormat: Text.PlainText
        id: clearQueue
        anchors.right: searchField.left
        anchors.rightMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        visible: root.currentUri === "queue" && root.rows.length > 0
        text: "Clear"
        color: clearHover.containsMouse ? Color.urgent : Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        Behavior on color { ColorAnimation { duration: Design.fast } }

        MouseArea {
          id: clearHover
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.clearQueue()
        }
      }

      TextField {
        id: searchField
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(Style.space(220), parent.width * 0.42)
        verticalPadding: Style.space(4)
        leftPadding: Style.space(26)
        placeholderText: "Search"
        font.pixelSize: Style.font.bodySmall
        foreground: root.foreground
        accent: Color.accent
        onAccepted: {
          root.history = []
          root.runSearch(text)
          root.forceActiveFocus()
        }
      }

      Text {
        textFormat: Text.PlainText
        // Inside the field rather than beside it, so the control reads as one
        // object instead of an icon that happens to sit next to a box.
        x: searchField.x + Style.space(9)
        anchors.verticalCenter: searchField.verticalCenter
        text: "\uf002"
        color: searchField.activeFocus ? Color.accent : Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Behavior on color { ColorAnimation { duration: Design.fast } }
      }
    }

    // ---- body ----
    //
    // Three faces of the same pane -- shelves, a detail page, a list -- that
    // cross-fade rather than cut. Each stays loaded so going back does not
    // re-fetch what was already on screen.
    Item {
      id: body
      anchors.top: pageHeader.bottom
      anchors.topMargin: Style.space(16)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom

      HomeView {
        id: homePage
        anchors.fill: parent
        opacity: root.homeActive ? 1 : 0
        visible: opacity > 0.01
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily

        onOpenEntry: function(entry) { root.openEntry(entry) }
        onPlayEntry: function(entry) { root.playEntry(entry) }
        // No companion, no shelves: browse tidal:home the old way rather than
        // leaving Home empty.
        onUnavailable: {
          if (root.homeFallback) return
          root.homeFallback = true
          if (root.currentUri === "tidal:home") root.openTarget("tidal:home", "Home")
        }

        Behavior on opacity { NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic } }
      }

      DetailView {
        id: detail
        anchors.fill: parent
        opacity: root.detailUri !== "" ? 1 : 0
        visible: opacity > 0.01
        svc: root.svc
        uri: root.detailUri
        foreground: root.foreground
        fontFamily: root.fontFamily

        onOpenUri: function(uri, title) {
          root.pushHistory()
          root.showDetail(uri, title)
        }

        onTitleResolved: function(title) {
          if (root.detailUri !== "") root.currentTitle = title
        }

        Behavior on opacity { NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic } }
      }

      // Waiting looks like the thing you are waiting for. A TIDAL search goes
      // out through Mopidy and can take the better part of ten seconds; an
      // empty pane for that long reads as a failure rather than as progress.
      Column {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.space(8)
        spacing: Style.space(12)
        visible: root.loading && root.rows.length === 0
                 && root.detailUri === "" && !root.homeActive

        Repeater {
          model: 8

          Row {
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(14)
              height: width
              radius: Style.space(2)
              color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.12)
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(5)

              Rectangle {
                width: Style.space(180)
                height: Style.space(9)
                radius: Style.space(2)
                color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.14)
              }

              Rectangle {
                width: Style.space(120)
                height: Style.space(7)
                radius: Style.space(2)
                color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.09)
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: root.errorText !== "" && !root.loading
                 && root.detailUri === "" && !root.homeActive
        text: root.errorText
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      ScrollHint {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        target: listView
        opacity: listView.opacity
      }

      ListView {
        id: listView
        anchors.fill: parent
        opacity: root.detailUri === "" && !root.homeActive ? 1 : 0
        visible: opacity > 0.01
        clip: true
        model: root.rows
        currentIndex: root.selectedIndex
        boundsBehavior: Flickable.StopAtBounds

        // A page and a half of runway, so the next page is already in hand by
        // the time the current one runs out.
        onContentYChanged: {
          if (contentHeight <= 0) return
          if (contentY > contentHeight - height * 1.5) root.loadLibraryPage(false)
        }

        Behavior on opacity { NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic } }

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

          removable: root.currentUri === "queue"

          onActivated: { root.selectedIndex = index; root.playRow(modelData) }
          onQueued: { root.selectedIndex = index; root.queueRow(modelData) }
          onOpened: { root.selectedIndex = index; root.openRow(modelData) }
          onRemoved: { root.selectedIndex = index; root.removeQueueRow(modelData) }
        }
      }
    }
  }

  // ---- keyboard ----

  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

    // The quick menu had no key at all, which in a keyboard-first shell means
    // half its actions were unreachable without a mouse. Handled before the
    // per-pane branches below, which end in a bare return: a global key must
    // not depend on which pane happens to be showing.
    if (event.key === Qt.Key_M) {
      root.menuRequested()
      event.accepted = true; return
    }

    // The question mark, where every application that has one keeps it.
    if (event.key === Qt.Key_Question) {
      root.shortcutsRequested()
      event.accepted = true; return
    }

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

    // Home is a grid, not a list, so the same four keys mean rows and columns
    // there. Everything else -- Enter, Shift+Enter, Space -- keeps its meaning.
    if (root.homeActive) {
      if (event.key === Qt.Key_Down) { homePage.moveRow(1); event.accepted = true; return }
      if (event.key === Qt.Key_Up) { homePage.moveRow(-1); event.accepted = true; return }
      if (event.key === Qt.Key_Right) { homePage.moveCol(1); event.accepted = true; return }
      if (event.key === Qt.Key_Left) { homePage.moveCol(-1); event.accepted = true; return }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (shift) homePage.playSelected(); else homePage.openSelected()
        event.accepted = true; return
      }
      if (event.key === Qt.Key_Space) {
        if (root.svc) root.svc.playPause()
        event.accepted = true; return
      }
      if (event.key === Qt.Key_P) {
        var card = homePage.selectedEntry()
        if (card && String(card.type) === "track") {
          root.addToPlaylist(String(card.uri), String(card.name || ""))
          event.accepted = true
        }
        return
      }
      return
    }

    // Ctrl with the arrows carries the row instead of moving between rows.
    if (root.currentUri === "queue" && ctrl
        && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
      root.moveQueueRow(event.key === Qt.Key_Down ? 1 : -1)
      event.accepted = true; return
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
    if (root.currentUri === "queue"
        && (event.key === Qt.Key_Delete
            || (event.key === Qt.Key_Backspace && !root.sidebarFocused))) {
      root.removeQueueRow(root.currentRow())
      event.accepted = true; return
    }

    if (event.key === Qt.Key_Left || event.key === Qt.Key_Backspace) {
      if (root.goBack()) event.accepted = true
      return
    }
    if (event.key === Qt.Key_Space) {
      if (root.svc) root.svc.playPause()
      event.accepted = true; return
    }

    // P for the row under the cursor, matching the quick menu's entry for
    // whatever is playing.
    if (event.key === Qt.Key_P) {
      var chosen = root.currentRow()
      if (chosen && chosen.type === "track") {
        root.addToPlaylist(String(chosen.uri), String(chosen.name || ""))
        event.accepted = true
      }
      return
    }
  }
}
