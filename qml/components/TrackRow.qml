import QtQuick
import qs.Commons
import "../lib/Library.js" as Library
import "../lib/Design.js" as Design
import "../lib/TidalApi.js" as Tidal

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

  // Set on rows that come from a record rather than from a search: on an album
  // page the position and the running time are what you want in the margins,
  // and repeating the album name down every row says nothing.
  // Every list shows artwork, the way Apple Music and TIDAL's own client do.
  // Rows that arrive from /home or /album carry an image url already; a browse
  // ref or a search result carries only a uri, and the companion resolves it.
  // Either way the bytes come through the local cache.
  readonly property string artSource: {
    if (!root.row || root.isHeader) return ""
    if (root.row.image) return Tidal.artProxy(String(root.row.image), 320)
    return Tidal.artUrl(String(root.row.uri || ""), 320)
  }

  readonly property string numberText: row && row.num ? String(row.num) : ""
  readonly property string durationText: row && row.duration ? Design.clock(row.duration) : ""

  // A row with an artist and album under the title needs two lines of room; a
  // numbered album track is one line and should not sit in a 38px gap.
  // Artwork sets the floor on row height now: a 34px sleeve wants a 44px row
  // with two lines of text beside it, 40 with one.
  implicitHeight: isHeader ? Style.space(30)
                  : (hasMeta ? Style.space(44) : Style.space(40))

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

    // Position, when the row has one, sits outside the sleeve: on an album
    // page the numbers are a column you read down.
    Text {
      id: trackNumber
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      horizontalAlignment: Text.AlignRight
      visible: root.numberText !== ""
      text: root.numberText
      color: root.playing ? root.accent : Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      id: artSlot
      anchors.left: trackNumber.visible ? trackNumber.right : parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      height: width

      RoundedImage {
        id: art
        anchors.fill: parent
        // Round for people, softly square for records -- the distinction the
        // detail pages and the Home shelves already make.
        radius: root.rowType === "artist" ? width / 2 : Style.space(3)
        source: root.artSource
      }

      // Whatever has no art of its own -- a folder, a section of the tree --
      // keeps its glyph, inside the same silhouette so the column still lines
      // up.
      Text {
        anchors.centerIn: parent
        visible: !art.ready
        text: Library.typeGlyph(root.rowType)
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // The playing row is marked on the sleeve itself rather than by taking
      // the sleeve away.
      Rectangle {
        anchors.fill: parent
        radius: art.radius
        visible: root.playing
        color: Qt.rgba(0, 0, 0, 0.55)

        Text {
          anchors.centerIn: parent
          text: "\uf028"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Text {
      id: durationLabel
      anchors.right: chevron.visible ? chevron.left : parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      visible: root.durationText !== ""
      text: root.durationText
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
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
      anchors.left: artSlot.right
      anchors.leftMargin: Style.space(11)
      anchors.right: durationLabel.visible ? durationLabel.left
                     : (chevron.visible ? chevron.left : parent.right)
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
