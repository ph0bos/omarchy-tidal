import QtQuick
import qs.Commons
import "../lib/Library.js" as Library

// One row in the player's lists: a track, album, artist, playlist, or a folder
// to descend into. Also used for the queue and for detail pages, which is why
// "playing" is a separate flag from "selected".
//
// Track rows always show three things -- name, artist, album -- because a bare
// title is ambiguous across a library this size. Browse results arrive without
// artist or album, so PlayerView backfills them with a batched lookup.
Item {
  id: root

  property var row: null
  property bool selected: false
  property bool playing: false
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily

  signal activated()   // Enter        -> play now
  signal queued()      // Shift+Enter  -> append
  signal opened()      // Right arrow  -> descend

  readonly property bool isHeader: row ? row.header === true : false
  readonly property string rowType: row ? String(row.type || "") : ""

  // Falls back to the joined subtitle for rows that carry no split fields.
  readonly property string artistText: {
    if (!row) return ""
    if (row.artist) return String(row.artist)
    return row.subtitle ? String(row.subtitle) : ""
  }
  readonly property string albumText: row && row.album ? String(row.album) : ""
  readonly property bool hasMeta: artistText !== "" || albumText !== ""

  implicitHeight: isHeader ? Style.space(30) : Style.space(38)

  Text {
    visible: root.isHeader
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(6)
    text: root.row ? String(root.row.name).toUpperCase() : ""
    color: Color.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1.2
  }

  Rectangle {
    visible: !root.isHeader
    anchors.fill: parent
    anchors.leftMargin: Style.space(2)
    anchors.rightMargin: Style.space(2)
    radius: Style.space(3)
    color: root.selected ? Color.menu.selectedBackground : "transparent"

    Text {
      id: typeIcon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      text: root.playing ? "\uf028" : Library.typeGlyph(root.rowType)
      color: root.playing ? root.accent : Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: chevron
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      visible: root.rowType === "directory" || root.rowType === "album"
               || root.rowType === "artist" || root.rowType === "playlist"
      text: "\uf054"
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Column {
      anchors.left: typeIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: chevron.visible ? chevron.left : parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2

      Text {
        width: parent.width
        text: root.row ? root.row.name : ""
        elide: Text.ElideRight
        color: root.playing ? root.accent
                            : (root.selected ? Color.menu.selectedText : root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // Artist and album as separate fields, not one pre-joined string: the
      // artist is what people scan for, so it keeps the stronger colour and
      // the album trails it at lower emphasis.
      Row {
        width: parent.width
        spacing: Style.space(5)
        visible: root.hasMeta

        Text {
          id: artistLabel
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, parent.width * 0.55)
          visible: root.artistText !== ""
          text: root.artistText
          elide: Text.ElideRight
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: sep
          anchors.verticalCenter: parent.verticalCenter
          visible: root.artistText !== "" && root.albumText !== ""
          text: "·"
          color: Color.muted
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - artistLabel.width
                             - (sep.visible ? sep.width + Style.space(10) : 0))
          visible: root.albumText !== ""
          text: root.albumText
          elide: Text.ElideRight
          color: Color.muted
          opacity: 0.68
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) { root.queued(); return }
        if (mouse.modifiers & Qt.ShiftModifier) { root.queued(); return }
        if (root.rowType === "track") root.activated()
        else root.opened()
      }
      onDoubleClicked: root.activated()
    }
  }
}
