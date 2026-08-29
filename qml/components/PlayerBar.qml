import QtQuick
import qs.Commons
import "../lib/Design.js" as Design

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

  // While the playhead is held, `position` follows the pointer locally and no
  // seek is sent. One seek goes out on release. Sending a seek per mouse-move
  // floods the backend and makes the audio stutter under the cursor.
  property bool scrubbing: false

  function fractionToMs(fraction) {
    return Math.max(0, Math.min(1, fraction)) * root.length * 1000
  }

  function previewFraction(fraction) {
    if (!root.svc || root.length <= 0) return
    root.svc.previewSeek(root.fractionToMs(fraction))
  }

  function commitFraction(fraction) {
    if (!root.svc || root.length <= 0) return
    root.svc.commitSeek(root.fractionToMs(fraction))
  }

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
        source: root.svc ? root.svc.artUrl : ""
      }

      // Expand affordance, revealed on hover so it does not clutter the bar.
      Rectangle {
        anchors.fill: parent
        radius: Style.space(3)
        color: "#000000"
        opacity: artHover.containsMouse ? 0.45 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      Text {
        anchors.centerIn: parent
        text: root.expanded ? "\uf066" : "\uf065"
        color: "#FFFFFF"
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
  Item {
    id: seekArea
    anchors.left: transport.right
    anchors.leftMargin: Style.space(16)
    anchors.right: rightGroup.left
    anchors.rightMargin: Style.space(16)
    anchors.verticalCenter: parent.verticalCenter
    height: Style.space(26)
    visible: width > Style.space(90)

    Text {
      id: elapsed
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      text: Design.clock(root.position)
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
    }

    Text {
      id: total
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      text: Design.clock(root.length)
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      id: track
      anchors.left: elapsed.right
      anchors.right: total.left
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height

      Rectangle {
        id: rail
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(4)
        radius: height / 2
        color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.28)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * root.progress
          radius: parent.radius
          color: Color.accent
        }
      }

      // Playhead. Grows on hover/drag so the bar reads as grabbable.
      Rectangle {
        id: knob
        width: seekMouse.containsMouse || root.scrubbing ? Style.space(11) : Style.space(8)
        height: width
        radius: width / 2
        color: Color.accent
        anchors.verticalCenter: rail.verticalCenter
        x: Math.max(0, Math.min(rail.width, rail.width * root.progress)) - width / 2
        visible: root.length > 0

        Behavior on width { NumberAnimation { duration: 100 } }
      }

      MouseArea {
        id: seekMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        preventStealing: true

        // Press and drag preview locally; the seek is issued once, on release.
        onPressed: function(mouse) {
          root.scrubbing = true
          root.previewFraction(mouse.x / width)
        }
        onPositionChanged: function(mouse) {
          if (root.scrubbing) root.previewFraction(mouse.x / width)
        }
        onReleased: function(mouse) {
          if (!root.scrubbing) return
          root.scrubbing = false
          root.commitFraction(mouse.x / width)
        }
        onCanceled: root.scrubbing = false
      }
    }
  }
}
