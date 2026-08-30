import QtQuick
import qs.Commons
import "../lib/Design.js" as Design
import "../lib/TidalApi.js" as Tidal

// The bar's mini player: what is on, how far through it is, and the controls
// you actually reach for -- without taking over the screen.
//
// The full player is a modal overlay that dims the desktop, which is the right
// weight for browsing a library and far too much for skipping a track. This
// sits under the bar widget like every other Omarchy panel, and hands off to
// the overlay for anything that needs room.
Item {
  id: root

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily

  // The caller opens the full surfaces; the popup only says which one.
  signal openPlayer()
  signal openNowPlaying()
  signal openUri(string uri, string title)

  readonly property bool hasTrack: svc ? svc.hasTrack : false
  readonly property bool playing: svc ? svc.playing : false

  // Scrims and labels that sit on top of album art. Derived from the theme
  // rather than hardcoded black and white: Omarchy ships light themes, and a
  // black wash under white text is only correct on half of them.
  readonly property color scrim: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                                         Color.popups.background.b, 0.4)
  readonly property color onArt: Color.popups.text

  // The sleeve's colour, lifted until it reads against this surface. Falls back
  // to the theme's accent only when no lightness of that hue would do.
  function tintFrom(colour, background) {
    if (!colour || colour === "") return Color.accent
    var candidate = Qt.color(colour)
    if (Design.contrast(candidate, background) >= 3) return candidate
    var lightness = Design.contrastLightness(candidate.hslHue, candidate.hslSaturation,
                                             candidate.hslLightness, background, 3)
    if (lightness < 0) return Color.accent
    return Qt.hsla(candidate.hslHue, candidate.hslSaturation, lightness, 1)
  }

  // Vetted here rather than in the service: this panel's background is not the
  // overlay's, and the same colour is not equally readable on both.
  readonly property color artAccent: root.svc
    ? root.tintFrom(root.svc.artColor, Color.popups.background) : Color.accent

  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(13)

    // ---- what is playing ----
    Row {
      width: parent.width
      spacing: Style.space(12)

      Item {
        width: Style.space(72)
        height: width

        RoundedImage {
          anchors.fill: parent
          radius: Style.space(4)
          decodeSize: 192
          source: root.svc ? Tidal.artProxy(root.svc.artUrl, 320) : ""
        }

        Rectangle {
          anchors.fill: parent
          radius: Style.space(4)
          color: root.scrim
          opacity: artHover.containsMouse ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Design.fast } }
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "\uf065"
          color: root.onArt
          opacity: artHover.containsMouse ? 0.95 : 0
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          Behavior on opacity { NumberAnimation { duration: Design.fast } }
        }

        MouseArea {
          id: artHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openNowPlaying()
        }
      }

      Column {
        width: parent.width - Style.space(84)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.hasTrack ? root.svc.title : "Nothing playing"
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.WordWrap
          color: titleLink.containsMouse ? Color.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.weight: Font.DemiBold

          Behavior on color { ColorAnimation { duration: Design.fast } }

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
          width: parent.width
          visible: root.hasTrack
          text: root.svc ? root.svc.artist : ""
          elide: Text.ElideRight
          color: artistLink.containsMouse ? Color.accent : Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall

          Behavior on color { ColorAnimation { duration: Design.fast } }

          MouseArea {
            id: artistLink
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.svc && root.svc.artistUri !== ""
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openUri(root.svc.artistUri, root.svc.artist)
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.svc && root.svc.album !== ""
          text: root.svc ? root.svc.album : ""
          elide: Text.ElideRight
          color: Color.muted
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    SeekBar {
      width: parent.width
      visible: root.hasTrack
      svc: root.svc
      accent: root.artAccent
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    // ---- transport ----
    Item {
      width: parent.width
      height: Style.space(24)

      Row {
        anchors.centerIn: parent
        spacing: Style.space(18)

        Repeater {
          model: [
            { glyph: "\uf048", action: "previous" },
            { glyph: root.playing ? "\uf04c" : "\uf04b", action: "playPause" },
            { glyph: "\uf051", action: "next" }
          ]

          Text {
            textFormat: Text.PlainText
            id: button
            required property var modelData
            anchors.verticalCenter: parent.verticalCenter
            text: button.modelData.glyph
            color: buttonHover.containsMouse ? root.artAccent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: button.modelData.action === "playPause"
                            ? Style.font.heading : Style.font.subtitle

            Behavior on color { ColorAnimation { duration: Design.fast } }

            MouseArea {
              id: buttonHover
              anchors.fill: parent
              anchors.margins: -Style.space(7)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (!root.svc) return
                if (button.modelData.action === "previous") root.svc.previous()
                else if (button.modelData.action === "next") root.svc.next()
                else root.svc.playPause()
              }
            }
          }
        }
      }

      // Favourite and radio sit out at the edges: they act on the track rather
      // than on playback, and grouping them with the transport would suggest
      // otherwise.
      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: root.svc && root.svc.isTidalTrack
        text: root.svc && root.svc.favorite ? "\uf004" : "\uf08a"
        color: root.svc && root.svc.favorite ? root.artAccent
               : (heartHover.containsMouse ? root.foreground : Color.muted)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        MouseArea {
          id: heartHover
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { if (root.svc) root.svc.toggleFavorite() }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.svc && root.svc.isTidalTrack
        text: "\uf1b8"
        color: radioHover.containsMouse ? root.artAccent : Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        MouseArea {
          id: radioHover
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { if (root.svc) root.svc.startRadio() }
        }
      }
    }

    Rectangle {
      width: parent.width
      height: Math.max(1, Style.space(1))
      color: Color.popups.border
      opacity: 0.35
    }

    // ---- what it is, and the way through to the app ----
    Item {
      width: parent.width
      height: Style.space(20)

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: root.svc && root.svc.qualityLabel !== ""
        width: quality.implicitWidth + Style.space(11)
        height: quality.implicitHeight + Style.space(5)
        radius: Style.space(3)
        color: root.svc && root.svc.isHiRes
          ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
          : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.14)

        Text {
          textFormat: Text.PlainText
          id: quality
          anchors.centerIn: parent
          text: root.svc ? root.svc.qualityLabel : ""
          color: root.svc && root.svc.isHiRes ? Color.accent : Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(14)

        Text {
          textFormat: Text.PlainText
          text: "Player"
          color: playerHover.containsMouse ? Color.accent : Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          Behavior on color { ColorAnimation { duration: Design.fast } }

          MouseArea {
            id: playerHover
            anchors.fill: parent
            anchors.margins: -Style.space(5)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openPlayer()
          }
        }

        Text {
          textFormat: Text.PlainText
          text: "Now playing"
          color: npHover.containsMouse ? Color.accent : Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          Behavior on color { ColorAnimation { duration: Design.fast } }

          MouseArea {
            id: npHover
            anchors.fill: parent
            anchors.margins: -Style.space(5)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openNowPlaying()
          }
        }
      }
    }
  }
}
