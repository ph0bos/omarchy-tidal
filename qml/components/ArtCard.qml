import QtQuick
import qs.Commons
import "../lib/Design.js" as Design
import "../lib/TidalApi.js" as Tidal

// One piece of artwork in a Home shelf: a record, a mix, an artist, a track.
//
// The card is mostly picture. Everything else -- the name, who made it, the
// fact that it is hi-res -- sits underneath in two fixed lines, so shelves
// line up with each other no matter what their items are. A card whose
// subtitle happens to be empty still occupies both lines rather than pulling
// its neighbours' baselines out of alignment.
//
// Two ways in, and they mean different things: the picture opens the page,
// the play button starts it. Apple's stores and Music both work this way, and
// it is the difference between browsing and committing.
Item {
  id: root

  property var entry: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property bool selected: false

  signal activated()   // play this now
  signal opened()      // show its page

  readonly property string kind: entry ? String(entry.type || "") : ""
  readonly property bool isArtist: kind === "artist"
  readonly property bool isTrack: kind === "track"
  readonly property bool hires: entry ? entry.hires === true : false
  readonly property string label: entry ? String(entry.name || "") : ""
  // Artists are their own subtitle; repeating the name there is noise.
  readonly property string sublabel: {
    if (!root.entry || root.isArtist) return ""
    return String(root.entry.artist || "")
  }

  // Anything with a track list can be started from the card. An artist has to
  // be opened first -- "play an artist" is not a thing the backend can do.
  readonly property bool playable: !root.isArtist

  // Keyboard selection and the pointer get the same treatment. A card that is
  // "selected" but looks nothing like a card under the cursor teaches two
  // different affordances for one state.
  readonly property bool hot: hover.containsMouse || root.selected

  // The space under a tile should be the space you can see. A text item's box
  // starts above its capitals, so a 9px margin drew as 12 and the labels sat
  // adrift from their artwork.
  FontMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  readonly property real labelCapGap: labelMetrics.ascent - labelMetrics.capitalHeight

  // Scrims and labels that sit on top of album art. Derived from the theme
  // rather than hardcoded black and white: Omarchy ships light themes, and a
  // black wash under white text is only correct on half of them.
  readonly property color scrim: Qt.rgba(Color.menu.background.r, Color.menu.background.g,
                                         Color.menu.background.b, 0.55)
  readonly property color onArt: Color.menu.text

  implicitWidth: Style.space(Design.cardIdeal)
  height: width + labels.implicitHeight + Style.space(9)

  Item {
    id: artFrame
    width: parent.width
    height: width

    RoundedImage {
      id: art
      anchors.fill: parent
      // Round for people, softly square for records -- the same distinction
      // the detail pages already make.
      radius: root.isArtist ? width / 2 : Style.space(4)
      decodeSize: 256
      source: root.entry && root.entry.image ? Tidal.artProxy(String(root.entry.image), 320) : ""

      // The picture leans towards the cursor. Scaling the masked item scales
      // its mask with it, so the corners stay round through the whole move.
      // Only the pointer does this: the keyboard cursor gets a ring instead,
      // so the two states stay tellable apart when both are on screen.
      scale: hover.containsMouse ? 1.035 : 1.0
      Behavior on scale { NumberAnimation { duration: Design.fast; easing.type: Easing.OutCubic } }
    }

    // A wash under the play button so a white glyph survives pale artwork.
    Rectangle {
      anchors.fill: parent
      radius: art.radius
      opacity: root.hot ? 1 : 0
      gradient: Gradient {
        GradientStop { position: 0.55; color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0) }
        GradientStop { position: 1.0;  color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0.45) }
      }
      Behavior on opacity { NumberAnimation { duration: Design.fast } }
    }

    // The keyboard cursor. A ring rather than a fill: the artwork is the
    // content, and a selected card should still be a picture.
    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      radius: art.radius + Style.space(4)
      color: "transparent"
      border.width: Math.max(1, Style.space(2))
      border.color: Color.accent
      opacity: root.selected ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Design.fast } }
    }

    Rectangle {
      id: playButton
      visible: root.playable
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(8)
      width: Style.space(26)
      height: width
      radius: width / 2
      color: playHover.containsMouse ? Color.accent : root.scrim
      opacity: root.hot ? 1 : 0

      // Rises into place rather than blinking on. Animated through a
      // transform, not through anchors.bottomMargin: anchors are a grouped
      // property and a Behavior on one never runs.
      transform: Translate {
        y: root.hot ? 0 : Style.space(6)
        Behavior on y { NumberAnimation { duration: Design.fast; easing.type: Easing.OutCubic } }
      }

      Behavior on opacity { NumberAnimation { duration: Design.fast } }
      Behavior on color { ColorAnimation { duration: Design.fast } }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        // Nudged right: a play triangle's optical centre is left of its box.
        anchors.horizontalCenterOffset: Style.space(1)
        text: "\uf04b"
        color: playHover.containsMouse ? Color.menu.background : root.onArt
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: playHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
      }
    }
  }

  Column {
    id: labels
    anchors.top: artFrame.bottom
    anchors.topMargin: Style.space(9) - root.labelCapGap
    width: parent.width
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.label
      elide: Text.ElideRight
      maximumLineCount: 1
      color: root.hot ? Color.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: root.isArtist ? Text.AlignHCenter : Text.AlignLeft
      Behavior on color { ColorAnimation { duration: Design.fast } }
    }

    // Held even when empty so every shelf sits on the same baseline.
    Row {
      width: parent.width
      height: sub.implicitHeight
      spacing: Style.space(5)
      layoutDirection: Qt.LeftToRight

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.hires
        width: Style.space(4)
        height: width
        radius: width / 2
        color: Color.accent
        opacity: 0.9
      }

      Text {
        textFormat: Text.PlainText
        id: sub
        width: parent.width - (root.hires ? Style.space(9) : 0)
        text: root.sublabel
        elide: Text.ElideRight
        maximumLineCount: 1
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: root.isArtist ? Text.AlignHCenter : Text.AlignLeft
      }
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    // A track has no page worth opening; clicking it plays it.
    onClicked: { if (root.isTrack) root.activated(); else root.opened() }
  }
}
