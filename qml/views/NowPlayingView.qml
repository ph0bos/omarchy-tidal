import QtQuick
import qs.Commons
import "../components"
import "../lib/Lrc.js" as Lrc

// Full-screen now playing: art, live spectrum, and time-synced lyrics.
//
// Lyrics come from the companion extension, which resolves TIDAL first and
// falls back to LRCLIB. Both are normalised to the same {time_ms, text} shape,
// so this does not care which answered.
//
// The active line is found by binary search against the playback clock rather
// than by scanning, because this runs on every position tick.
Item {
  id: root

  property var svc: null
  property string pluginDir: ""
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property bool visualizerEnabled: true

  // Clicking the large artwork contracts back to the player -- the same
  // gesture that expanded it, in reverse.
  signal contract()

  readonly property var lyrics: svc ? svc.lyrics : null
  readonly property var synced: lyrics && lyrics.synced ? lyrics.synced : []
  readonly property string plain: lyrics && lyrics.plain ? String(lyrics.plain) : ""
  readonly property string source: lyrics && lyrics.source ? String(lyrics.source) : ""
  readonly property bool hasSynced: synced.length > 0

  // Lyrics run slightly ahead of the beat when displayed dead-on; a small lead
  // makes the highlight land with the vocal rather than after it.
  readonly property int leadMs: 250
  readonly property int activeIndex: root.hasSynced
    ? Lrc.activeIndex(root.synced, (root.svc ? root.svc.position : 0) * 1000 + root.leadMs)
    : -1

  onActiveIndexChanged: if (root.activeIndex >= 0) lyricList.centerOn(root.activeIndex)

  // ---- backdrop: album art, blown up and dimmed ----
  RoundedImage {
    anchors.fill: parent
    radius: Style.space(6)
    source: root.svc ? root.svc.artUrl : ""
    opacity: 0.16
    visible: source !== ""
  }

  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.15) }
      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
    }
  }

  Row {
    anchors.fill: parent
    anchors.margins: Style.space(22)
    spacing: Style.space(26)

    // ---- left: art, title, spectrum ----
    Column {
      id: left
      width: Math.min(Style.space(320), parent.width * 0.42)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(16)

      Item {
        width: parent.width
        height: width

        RoundedImage {
          anchors.fill: parent
          radius: Style.space(6)
          source: root.svc ? root.svc.artUrl : ""
        }

        Rectangle {
          anchors.fill: parent
          radius: Style.space(6)
          color: "#000000"
          opacity: artHover.containsMouse ? 0.35 : 0
          Behavior on opacity { NumberAnimation { duration: 130 } }
        }

        Text {
          anchors.centerIn: parent
          text: "\uf066"
          color: "#FFFFFF"
          opacity: artHover.containsMouse ? 0.9 : 0
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          Behavior on opacity { NumberAnimation { duration: 130 } }
        }

        MouseArea {
          id: artHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.contract()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(3)

        Text {
          width: parent.width
          text: root.svc && root.svc.title !== "" ? root.svc.title : "Nothing playing"
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
        }

        Text {
          width: parent.width
          text: root.svc ? root.svc.artist : ""
          elide: Text.ElideRight
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: root.svc && root.svc.album !== ""
          text: root.svc ? root.svc.album : ""
          elide: Text.ElideRight
          color: Color.muted
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // Live spectrum from the PipeWire sink monitor.
      Visualizer {
        id: viz
        width: parent.width
        height: Style.space(74)
        bars: 32
        segments: 16
        columnGap: 3
        segmentGap: 2
        active: root.visible && root.visualizerEnabled && root.svc && root.svc.playing
        binPath: root.pluginDir !== "" ? root.pluginDir + "/bin/omarchy-tidal-cava" : ""
      }
    }

    // ---- right: lyrics ----
    Item {
      width: parent.width - left.width - Style.space(26)
      height: parent.height

      Text {
        id: lyricsHeader
        anchors.top: parent.top
        anchors.left: parent.left
        text: root.hasSynced ? "LYRICS" : (root.plain !== "" ? "LYRICS" : "")
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.2
      }

      Text {
        anchors.top: parent.top
        anchors.right: parent.right
        visible: root.source !== ""
        text: root.source === "tidal" ? "TIDAL" : root.source.toUpperCase()
        color: Color.muted
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Nothing to show: say which case it is rather than a blank panel.
      Text {
        anchors.centerIn: parent
        visible: !root.hasSynced && root.plain === ""
        width: parent.width - Style.space(40)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: root.svc && root.svc.hasTrack
          ? "No lyrics for this track."
          : "Play something to see lyrics."
      }

      // ---- synced ----
      ListView {
        id: lyricList
        anchors.top: lyricsHeader.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.hasSynced
        clip: true
        model: root.synced
        spacing: Style.space(7)
        boundsBehavior: Flickable.StopAtBounds
        // Keep the active line near the middle rather than at the top edge.
        preferredHighlightBegin: height / 2 - Style.space(24)
        preferredHighlightEnd: height / 2 + Style.space(24)
        highlightRangeMode: ListView.ApplyRange

        function centerOn(index) {
          if (index < 0 || index >= count) return
          positionViewAtIndex(index, ListView.Center)
        }

        delegate: Text {
          id: lyricLine
          required property int index
          required property var modelData

          width: lyricList.width
          text: String(modelData.text || "")
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignLeft

          readonly property bool isActive: lyricLine.index === root.activeIndex
          readonly property bool isPast: lyricLine.index < root.activeIndex

          color: isActive ? root.foreground : Color.muted
          opacity: isActive ? 1.0 : (isPast ? 0.35 : 0.55)
          font.family: root.fontFamily
          font.pixelSize: isActive ? Style.font.subtitle : Style.font.body
          font.weight: isActive ? Font.DemiBold : Font.Normal

          Behavior on opacity { NumberAnimation { duration: 180 } }
          Behavior on font.pixelSize { NumberAnimation { duration: 140 } }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            // Clicking a line seeks to it -- the one interaction a synced
            // lyric sheet should always have.
            onClicked: {
              if (root.svc) root.svc.seekTo(Number(lyricLine.modelData.time_ms) || 0)
            }
          }
        }
      }

      // ---- unsynced fallback ----
      Flickable {
        anchors.top: lyricsHeader.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: !root.hasSynced && root.plain !== ""
        contentHeight: plainText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Text {
          id: plainText
          width: parent.width
          text: root.plain
          wrapMode: Text.WordWrap
          color: root.foreground
          opacity: 0.85
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          lineHeight: 1.4
        }
      }
    }
  }
}
