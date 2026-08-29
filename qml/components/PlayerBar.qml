import QtQuick
import qs.Commons
import "../lib/Design.js" as Design
import "../lib/TidalApi.js" as Tidal

// Transport strip along the bottom of the player.
//
// Laid out with anchors, not a Row: a Row sums fixed child widths plus a
// "remaining space" child, and any miscalculation pushes the right-hand group
// off the edge (which is exactly how the quality pill got clipped). Anchoring
// the left and right groups to their edges and letting the seek bar fill what
// is between them cannot overflow at any width.
//
// Playback state comes from the service (MPRIS-backed). Seeking goes through
// the service too, which moves its local clock immediately so the playhead
// responds before the backend round trip completes.
Item {
  id: root

  property var svc: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  readonly property bool hasTrack: svc ? svc.hasTrack : false
  readonly property bool playing: svc ? svc.playing : false
  readonly property real position: svc ? svc.position : 0
  readonly property real length: svc ? svc.length : 0
  readonly property real progress: length > 0 ? Math.max(0, Math.min(1, position / length)) : 0

  // Scrims and labels that sit on top of album art. Derived from the theme
  // rather than hardcoded black and white: Omarchy ships light themes, and a
  // black wash under white text is only correct on half of them.
  readonly property color scrim: Qt.rgba(Color.menu.background.r, Color.menu.background.g,
                                         Color.menu.background.b, 0.45)
  readonly property color onArt: Color.menu.text

  // Clicking the artwork expands to the full now-playing view and clicking it
  // again contracts back, the way the native TIDAL desktop app behaves. The
  // host owns the view state; the bar only reports the intent and is told
  // which direction it is currently pointing.
  property bool expanded: false
  signal artClicked()
  // The title and the artist are links: everywhere else in the player a name
  // is a way into its page, and the transport strip was the one surface where
  // it was only text.
  signal openUri(string uri, string title)

  implicitHeight: Style.space(64)
  height: implicitHeight

  Rectangle {
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.max(1, Style.space(1))
    color: Color.menu.border
    opacity: 0.4
  }

  // ---- left: art + title ----
  Row {
    id: leftGroup
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(11)
    width: Style.space(250)

    Item {
      anchors.verticalCenter: parent.verticalCenter
      width: root.hasTrack ? Style.space(42) : 0
      height: width
      visible: width > 0

      RoundedImage {
        id: barArt
        anchors.fill: parent
        radius: Style.space(3)
        source: root.svc ? Tidal.artProxy(root.svc.artUrl, 160) : ""
      }

      // Expand affordance, revealed on hover so it does not clutter the bar.
      Rectangle {
        anchors.fill: parent
        radius: Style.space(3)
        color: root.scrim
        opacity: artHover.containsMouse ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.expanded ? "\uf066" : "\uf065"
        color: root.onArt
        opacity: artHover.containsMouse ? 0.95 : 0
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      MouseArea {
        id: artHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.artClicked()
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(53)
      spacing: 2

      Text {
        textFormat: Text.PlainText
        id: barTitle
        width: parent.width
        text: root.hasTrack ? root.svc.title : "Nothing playing"
        elide: Text.ElideRight
        color: titleLink.containsMouse ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        Behavior on color { ColorAnimation { duration: 110 } }

        MouseArea {
          id: titleLink
          anchors.fill: parent
          hoverEnabled: true
          enabled: root.svc && root.svc.albumUri !== ""
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openUri(root.svc.albumUri, root.svc.album)
        }
      }

      Text {
        textFormat: Text.PlainText
        id: barArtist
        width: parent.width
        visible: root.hasTrack
        text: root.svc ? root.svc.artist : ""
        elide: Text.ElideRight
        color: artistLink.containsMouse ? Color.accent : Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption

        Behavior on color { ColorAnimation { duration: 110 } }

        MouseArea {
          id: artistLink
          anchors.fill: parent
          hoverEnabled: true
          enabled: root.svc && root.svc.artistUri !== ""
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openUri(root.svc.artistUri, root.svc.artist)
        }
      }
    }
  }

  // ---- right: favourite + quality ----
  Row {
    id: rightGroup
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.svc && root.svc.isTidalTrack
      text: root.svc && root.svc.favorite ? "\uf004" : "\uf08a"
      color: root.svc && root.svc.favorite ? Color.accent : Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(5)
        cursorShape: Qt.PointingHandCursor
        onClicked: { if (root.svc) root.svc.toggleFavorite() }
      }
    }

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.svc && root.svc.qualityLabel !== ""
      width: badge.implicitWidth + Style.space(11)
      height: badge.implicitHeight + Style.space(5)
      radius: Style.space(3)
      color: root.svc && root.svc.isHiRes
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.14)

      Text {
        textFormat: Text.PlainText
        id: badge
        anchors.centerIn: parent
        text: root.svc ? root.svc.qualityLabel : ""
        color: root.svc && root.svc.isHiRes ? Color.accent : Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---- transport ----
  Row {
    id: transport
    anchors.left: leftGroup.right
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(14)

    Repeater {
      model: [
        { glyph: "\uf048", action: "previous" },
        { glyph: root.playing ? "\uf04c" : "\uf04b", action: "playPause" },
        { glyph: "\uf051", action: "next" }
      ]

      Text {
        textFormat: Text.PlainText
        id: btn
        required property var modelData
        anchors.verticalCenter: parent.verticalCenter
        text: btn.modelData.glyph
        color: hover.containsMouse ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: btn.modelData.action === "playPause" ? Style.font.title : Style.font.body

        MouseArea {
          id: hover
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (!root.svc) return
            if (btn.modelData.action === "previous") root.svc.previous()
            else if (btn.modelData.action === "next") root.svc.next()
            else root.svc.playPause()
          }
        }
      }
    }
  }

  // ---- seek bar: fills whatever is left between transport and the right group ----
  SeekBar {
    anchors.left: transport.right
    anchors.leftMargin: Style.space(16)
    anchors.right: rightGroup.left
    anchors.rightMargin: Style.space(16)
    anchors.verticalCenter: parent.verticalCenter
    height: Style.space(26)
    visible: width > Style.space(90)
    svc: root.svc
    foreground: root.foreground
    fontFamily: root.fontFamily
  }
}
