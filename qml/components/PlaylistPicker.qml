import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Design.js" as Design
import "../lib/TidalApi.js" as Tidal

// "Add this to a playlist", as a small panel over whatever you were doing.
//
// It lists only the playlists this account can write to -- the ones you made --
// because the favourites list includes other people's, and adding to those
// fails at the far end rather than here.
//
// The picker owns the keyboard while it is up: arrows, Enter, Escape. The
// surface underneath gets it back on close.
Item {
  id: root

  property var svc: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  // What is being filed, and what to call it while asking.
  property string trackUri: ""
  property string trackTitle: ""

  property bool alive: true
  Component.onDestruction: root.alive = false

  signal closed()

  property var playlists: []
  property int selectedIndex: 0
  property bool loading: false
  property bool working: false
  property string errorText: ""
  property bool creating: false

  // The "New playlist" row sits above the list, so index 0 is always it.
  readonly property int rowCount: root.playlists.length + 1

  onVisibleChanged: {
    if (!root.visible) return
    root.selectedIndex = 0
    root.creating = false
    root.errorText = ""
    nameField.text = ""
    root.load()
    Qt.callLater(function() { root.forceActiveFocus() })
  }

  function load() {
    if (root.loading) return
    root.loading = true
    Tidal.playlists(function(payload) {
      if (!root.alive) return
      root.loading = false
      root.playlists = (payload && payload.items) || []
    }, function(err) {
      if (!root.alive) return
      root.loading = false
      root.errorText = "Could not read your playlists: " + err
    })
  }

  function move(delta) {
    if (root.creating) return
    root.selectedIndex = Math.max(0, Math.min(root.rowCount - 1, root.selectedIndex + delta))
  }

  function activate() {
    if (root.selectedIndex === 0) {
      // Making one and filing into it are a single intention; the field is the
      // second half of the same gesture.
      root.creating = true
      Qt.callLater(function() { nameField.forceActiveFocus() })
      return
    }
    var playlist = root.playlists[root.selectedIndex - 1]
    if (playlist) root.addTo(String(playlist.uri), String(playlist.name || ""))
  }

  function addTo(uri, name) {
    if (root.working || root.trackUri === "") return
    root.working = true
    root.errorText = ""
    Tidal.playlistAdd(uri, [root.trackUri], function() {
      if (!root.alive) return
      root.working = false
      if (root.svc) root.svc.osd("Added to " + name, "media")
      root.closed()
    }, function(err) {
      if (!root.alive) return
      root.working = false
      root.errorText = "Could not add to " + name + ": " + err
    })
  }

  function createAndAdd() {
    var name = nameField.text.replace(/^\s+|\s+$/g, "")
    if (name === "" || root.working) return
    root.working = true
    root.errorText = ""
    Tidal.playlistCreate(name, function(created) {
      if (!root.alive) return
      root.working = false
      if (!created || !created.uri) {
        root.errorText = "TIDAL did not return the new playlist"
        return
      }
      root.addTo(String(created.uri), String(created.name || name))
    }, function(err) {
      if (!root.alive) return
      root.working = false
      root.errorText = "Could not create the playlist: " + err
    })
  }

  Keys.onEscapePressed: {
    if (root.creating) { root.creating = false; root.forceActiveFocus(); return }
    root.closed()
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Down) { root.move(1); event.accepted = true; return }
    if (event.key === Qt.Key_Up) { root.move(-1); event.accepted = true; return }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.activate(); event.accepted = true; return
    }
  }

  // Anything outside the panel dismisses it, and the surface behind dims so it
  // is obvious the keyboard now belongs to the panel.
  Rectangle {
    anchors.fill: parent
    color: Color.menu.background
    opacity: root.visible ? 0.62 : 0

    Behavior on opacity { NumberAnimation { duration: Design.fast } }

    MouseArea {
      anchors.fill: parent
      onClicked: root.closed()
    }
  }

  Rectangle {
    id: panel
    anchors.centerIn: parent
    width: Math.min(Style.space(360), parent.width - Style.space(60))
    height: Math.min(content.implicitHeight + Style.space(28),
                     parent.height - Style.space(60))
    radius: Style.cornerRadius
    color: Color.menu.background
    border.width: Math.max(1, Style.space(1))
    border.color: Color.menu.border

    // Swallow clicks so the dismiss area behind does not see them.
    MouseArea { anchors.fill: parent }

    Column {
      id: content
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(14)
      spacing: Style.space(10)

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: "Add to playlist"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.weight: Font.DemiBold
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.trackTitle !== ""
          text: root.trackTitle
          elide: Text.ElideRight
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- new playlist ----
      Rectangle {
        width: parent.width
        height: Style.space(30)
        radius: Style.space(3)
        visible: !root.creating
        color: root.selectedIndex === 0 ? Color.menu.selectedBackground : "transparent"

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(9)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(9)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf067"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "New playlist"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.selectedIndex = 0; root.activate() }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.creating

        TextField {
          id: nameField
          width: parent.width - createButton.width - Style.space(8)
          placeholderText: "Playlist name"
          foreground: root.foreground
          accent: Color.accent
          onAccepted: root.createAndAdd()
        }

        Button {
          id: createButton
          text: "Create"
          bordered: true
          foreground: root.foreground
          accent: Color.accent
          onClicked: root.createAndAdd()
        }
      }

      Rectangle {
        width: parent.width
        height: Math.max(1, Style.space(1))
        color: Color.menu.border
        opacity: 0.4
      }

      // ---- the playlists ----
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.loading && root.playlists.length === 0
        text: "Reading your playlists…"
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: !root.loading && root.playlists.length === 0 && root.errorText === ""
        wrapMode: Text.WordWrap
        text: "You have no playlists of your own yet. Make one above."
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Column {
        width: parent.width
        spacing: 1

        Repeater {
          model: root.playlists

          Rectangle {
            id: playlistRow
            required property int index
            required property var modelData

            width: content.width
            height: Style.space(34)
            radius: Style.space(3)
            color: root.selectedIndex === playlistRow.index + 1
              ? Color.menu.selectedBackground : "transparent"

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(9)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(9)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(9)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf03a"
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(80)
                text: playlistRow.modelData.name || ""
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: playlistRow.modelData.num_tracks !== null
                         && playlistRow.modelData.num_tracks !== undefined
                text: String(playlistRow.modelData.num_tracks || 0)
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.selectedIndex = playlistRow.index + 1
                root.activate()
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.errorText !== "" || root.working
        wrapMode: Text.WordWrap
        text: root.working ? "Working…" : root.errorText
        color: root.working ? Color.muted : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
