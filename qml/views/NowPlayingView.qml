import QtQuick
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Lrc.js" as Lrc
import "../lib/MopidyRpc.js" as Rpc
import "../lib/TidalApi.js" as Tidal

// Now playing: the record, centred, and nothing else until you ask for it.
//
// The previous version showed artwork, lyrics and a spectrum analyser side by
// side at all times, which meant the lyric panel sat empty for every
// instrumental and the artwork never got to be the subject. Both TIDAL's own
// client and Roon do the opposite: the sleeve is the page, and lyrics or
// credits are a deliberate move away from it.
//
// So this has three faces -- artwork, lyrics, info -- and one object that
// moves between them. The artwork does not disappear and get replaced by a
// lyric sheet; it shrinks and slides left while the sheet arrives beside it,
// so it stays obvious what you are looking at the words for.
Item {
  id: root

  property var svc: null
  property string pluginDir: ""
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property bool visualizerEnabled: true

  property bool alive: true
  Component.onDestruction: root.alive = false

  // artwork | lyrics | info
  property string face: "artwork"

  // Back to the player list.
  signal contract()
  // Click-through from the metadata to the artist or album page.
  signal openUri(string uri, string title)

  readonly property string trackUri: svc ? svc.trackUri : ""
  readonly property string artUrl: svc ? svc.artUrl : ""

  // ---- lyrics -------------------------------------------------------------
  //
  // Resolved by the companion (TIDAL first, then LRCLIB) and normalised to
  // {time_ms, text}, so this does not care which answered. The active line is
  // found by binary search against the playback clock rather than by scanning,
  // because it runs on every position tick.
  readonly property var lyrics: svc ? svc.lyrics : null
  readonly property var synced: lyrics && lyrics.synced ? lyrics.synced : []
  readonly property string plain: lyrics && lyrics.plain ? String(lyrics.plain) : ""
  readonly property string source: lyrics && lyrics.source ? String(lyrics.source) : ""
  readonly property bool hasSynced: synced.length > 0
  readonly property bool hasLyrics: hasSynced || plain !== ""

  // Lyrics displayed dead-on read late; a small lead lands the highlight with
  // the vocal rather than after it.
  readonly property int leadMs: 250
  readonly property int activeIndex: root.hasSynced
    ? Lrc.activeIndex(root.synced, (root.svc ? root.svc.position : 0) * 1000 + root.leadMs)
    : -1

  onActiveIndexChanged: if (root.activeIndex >= 0) lyricList.centerOn(root.activeIndex)

  // ---- album info ---------------------------------------------------------
  //
  // Fetched only when the info face is actually opened. Pulling a full album
  // page on every track change would spend a request per song on something
  // most listeners never look at.
  property var album: null
  property string albumForTrack: ""
  property bool albumLoading: false

  function loadAlbum() {
    var want = root.trackUri
    if (want === "" || want.indexOf("tidal:track:") !== 0) return
    if (root.albumForTrack === want || root.albumLoading) return
    root.albumLoading = true

    function fetch(albumUri) {
      Tidal.album(albumUri, function(page) {
        if (!root.alive || root.trackUri !== want) return
        root.album = page
        root.albumForTrack = want
        root.albumLoading = false
      }, function() {
        if (!root.alive) return
        root.albumLoading = false
      })
    }

    // mopidy-tidal emits two uri shapes. The long one carries the album id
    // already; the short one does not, so ask Mopidy for the track and take
    // the album off it rather than guessing.
    var parts = want.split(":")
    if (parts.length >= 5) { fetch("tidal:album:" + parts[3]); return }

    Rpc.lookup([want], function(result) {
      if (!root.alive || root.trackUri !== want) return
      var found = result ? result[want] : null
      var uri = found && found.length && found[0].album
        ? String(found[0].album.uri || "") : ""
      if (uri === "") { root.albumLoading = false; return }
      fetch(uri)
    }, function() { if (root.alive) root.albumLoading = false })
  }

  onFaceChanged: if (root.face === "info") root.loadAlbum()
  onTrackUriChanged: {
    root.album = null
    root.albumForTrack = ""
    root.albumLoading = false
    if (root.face === "info") root.loadAlbum()
  }

  readonly property string albumMeta: {
    if (!root.album) return ""
    var parts = []
    if (root.album.year) parts.push(String(root.album.year))
    if (root.album.num_tracks)
      parts.push(root.album.num_tracks + (root.album.num_tracks === 1 ? " track" : " tracks"))
    if (root.album.duration) parts.push(Math.round(root.album.duration / 60) + " min")
    return parts.join("  ·  ")
  }

  function showFace(next) {
    root.face = root.face === next ? "artwork" : next
  }

  // ---- backdrop -----------------------------------------------------------
  //
  // The sleeve again, enormous and almost entirely faded out. It is what gives
  // the panel the record's own colour without asking the artwork to compete
  // with the text on top of it.
  RoundedImage {
    anchors.fill: parent
    radius: Style.space(6)
    source: root.artUrl
    fillMode: Image.PreserveAspectCrop
    blur: 1.0
    opacity: 0.28
    visible: source !== ""
  }

  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.15) }
      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
    }
  }

  // Reading faces get a second, flat scrim. The wash of colour off the sleeve
  // is the point of the artwork face and ruins the lyric sheet, where every
  // line has to stay legible over whatever the record happens to look like.
  Rectangle {
    anchors.fill: parent
    color: Color.menu.background
    opacity: root.face === "artwork" ? 0 : 0.55
    Behavior on opacity { NumberAnimation { duration: Design.slow } }
  }

  Item {
    id: stage
    anchors.fill: parent
    anchors.margins: Style.space(22)
    anchors.bottomMargin: Style.space(46)

    // How big the sleeve is depends only on which face is showing, so the
    // whole transition is one number changing and everything else following.
    readonly property real artSize: root.face === "artwork"
      ? Math.min(stage.height * 0.62, stage.width * 0.44)
      : Math.min(stage.height * 0.40, Style.space(200))

    // ---- the sleeve, and what it is ----
    Column {
      id: artBlock
      width: stage.artSize
      spacing: Style.space(16)

      x: root.face === "artwork" ? (stage.width - width) / 2 : 0
      y: root.face === "artwork" ? Math.max(0, (stage.height - height) / 2) : 0

      Behavior on x { NumberAnimation { duration: Design.slow; easing.type: Easing.InOutCubic } }
      Behavior on y { NumberAnimation { duration: Design.slow; easing.type: Easing.InOutCubic } }
      Behavior on width { NumberAnimation { duration: Design.slow; easing.type: Easing.InOutCubic } }

      Item {
        width: parent.width
        height: width

        RoundedImage {
          anchors.fill: parent
          radius: Style.space(6)
          source: root.artUrl
        }

        Rectangle {
          anchors.fill: parent
          radius: Style.space(6)
          color: "#000000"
          opacity: artHover.containsMouse ? 0.32 : 0
          Behavior on opacity { NumberAnimation { duration: Design.fast } }
        }

        // What clicking the sleeve does, said plainly, only while hovered.
        Text {
          anchors.centerIn: parent
          text: root.face === "artwork"
            ? (root.hasLyrics ? "Lyrics" : "No lyrics")
            : "Artwork"
          color: "#FFFFFF"
          opacity: artHover.containsMouse ? 0.92 : 0
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1.4
          Behavior on opacity { NumberAnimation { duration: Design.fast } }
        }

        MouseArea {
          id: artHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.face !== "artwork") { root.face = "artwork"; return }
            if (root.hasLyrics) root.face = "lyrics"
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(4)

        Text {
          width: parent.width
          text: root.svc && root.svc.title !== "" ? root.svc.title : "Nothing playing"
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          horizontalAlignment: root.face === "artwork" ? Text.AlignHCenter : Text.AlignLeft
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.face === "artwork" ? Style.font.display : Style.font.title
          font.weight: Font.DemiBold
          Behavior on font.pixelSize { NumberAnimation { duration: Design.slow; easing.type: Easing.InOutCubic } }
        }

        Text {
          width: parent.width
          text: root.svc ? root.svc.artist : ""
          elide: Text.ElideRight
          horizontalAlignment: root.face === "artwork" ? Text.AlignHCenter : Text.AlignLeft
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: root.face === "artwork" ? Style.font.subtitle : Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: root.svc && root.svc.album !== ""
          text: root.svc ? root.svc.album : ""
          elide: Text.ElideRight
          horizontalAlignment: root.face === "artwork" ? Text.AlignHCenter : Text.AlignLeft
          color: Color.muted
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // The spectrum belongs to the artwork face: it is decoration for the
      // record, not something to read lyrics through. Collapsing its height
      // rather than hiding it keeps the column from jumping.
      Visualizer {
        width: parent.width
        height: root.face === "artwork" ? Style.space(64) : 0
        clip: true
        opacity: root.face === "artwork" ? 1 : 0
        bars: 32
        segments: 16
        columnGap: 3
        segmentGap: 2
        active: root.visible && root.visualizerEnabled && root.face === "artwork"
                && root.svc && root.svc.playing
        binPath: root.pluginDir !== "" ? root.pluginDir + "/bin/omarchy-tidal-cava" : ""

        Behavior on height { NumberAnimation { duration: Design.slow; easing.type: Easing.InOutCubic } }
        Behavior on opacity { NumberAnimation { duration: Design.base } }
      }
    }

    // ---- the panel that arrives beside it ----
    Item {
      id: pane
      x: stage.artSize + Style.space(30)
      width: Math.max(0, stage.width - x)
      height: stage.height
      opacity: root.face === "artwork" ? 0 : 1
      visible: opacity > 0.01

      Behavior on x { NumberAnimation { duration: Design.slow; easing.type: Easing.InOutCubic } }
      Behavior on opacity { NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic } }

      // ---- lyrics ----
      Item {
        anchors.fill: parent
        opacity: root.face === "lyrics" ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: Design.base } }

        Text {
          id: lyricSource
          anchors.top: parent.top
          anchors.right: parent.right
          // Clear of the collapse button that sits in the view's corner.
          anchors.rightMargin: Style.space(26)
          visible: root.source !== ""
          text: root.source === "tidal" ? "TIDAL" : root.source.toUpperCase()
          color: Color.muted
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
        }

        Text {
          anchors.centerIn: parent
          visible: !root.hasLyrics
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

        ListView {
          id: lyricList
          anchors.top: parent.top
          anchors.topMargin: Style.space(6)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          visible: root.hasSynced
          clip: true
          model: root.synced
          spacing: Style.space(8)
          boundsBehavior: Flickable.StopAtBounds
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

            width: Math.min(lyricList.width, Style.space(520))
            text: String(modelData.text || "")
            wrapMode: Text.WordWrap

            readonly property bool isActive: lyricLine.index === root.activeIndex
            readonly property bool isPast: lyricLine.index < root.activeIndex

            color: isActive ? root.foreground : Color.muted
            opacity: isActive ? 1.0 : (isPast ? 0.42 : 0.66)
            font.family: root.fontFamily
            font.pixelSize: isActive ? Style.font.subtitle : Style.font.body
            font.weight: isActive ? Font.DemiBold : Font.Normal

            Behavior on opacity { NumberAnimation { duration: Design.base } }
            Behavior on font.pixelSize { NumberAnimation { duration: Design.fast } }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              // The one interaction a synced lyric sheet should always have.
              onClicked: {
                if (root.svc) root.svc.seekTo(Number(lyricLine.modelData.time_ms) || 0)
              }
            }
          }
        }

        Flickable {
          anchors.top: parent.top
          anchors.topMargin: Style.space(6)
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

      // ---- info ----
      Flickable {
        anchors.fill: parent
        opacity: root.face === "info" ? 1 : 0
        visible: opacity > 0.01
        contentHeight: infoColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Behavior on opacity { NumberAnimation { duration: Design.base } }

        Column {
          id: infoColumn
          // Capped rather than filling the pane: an editorial review set the
          // full width of a 1000px panel runs to 140 characters a line, which
          // is roughly twice what anyone can track back to the next line.
          width: Math.min(parent.width, Style.space(540))
          spacing: Style.space(14)

          Text {
            width: parent.width
            visible: root.album !== null
            text: root.album ? String(root.album.name || "") : ""
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.weight: Font.DemiBold

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.album) root.openUri(String(root.album.uri),
                                             String(root.album.name || ""))
              }
            }
          }

          Text {
            width: parent.width
            visible: root.album && root.album.artist
            text: root.album ? String(root.album.artist || "") : ""
            elide: Text.ElideRight
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.album && root.album.artist_uri)
                  root.openUri(String(root.album.artist_uri),
                               String(root.album.artist || ""))
              }
            }
          }

          Text {
            width: parent.width
            visible: root.albumMeta !== ""
            text: root.albumMeta
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // What is actually coming out of the speakers. This is the whole
          // reason the plugin exists, so it is stated rather than implied.
          Row {
            spacing: Style.space(8)
            visible: root.svc && root.svc.qualityLabel !== ""

            Rectangle {
              width: qualityText.implicitWidth + Style.space(12)
              height: qualityText.implicitHeight + Style.space(6)
              radius: Style.space(3)
              color: root.svc && root.svc.isHiRes
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.14)

              Text {
                id: qualityText
                anchors.centerIn: parent
                text: root.svc ? root.svc.qualityLabel : ""
                color: root.svc && root.svc.isHiRes ? Color.accent : Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.svc && root.svc.isHiRes
              text: "HI-RES"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
            }
          }

          Text {
            width: parent.width
            visible: root.album && root.album.review
            text: root.album ? String(root.album.review || "") : ""
            wrapMode: Text.WordWrap
            color: root.foreground
            opacity: 0.82
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            lineHeight: 1.45
          }

          Text {
            width: parent.width
            visible: root.album && root.album.copyright
            text: root.album ? String(root.album.copyright || "") : ""
            wrapMode: Text.WordWrap
            color: Color.muted
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: root.album === null
            text: root.albumLoading ? "Loading…"
              : (root.svc && root.svc.isTidalTrack
                 ? "No album details for this track."
                 : "Play a TIDAL track to see its details.")
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  // ---- faces --------------------------------------------------------------
  //
  // Three words and a rule that slides between them. A segmented control with
  // borders and fills would be three more boxes on a page whose whole point is
  // the picture.
  Item {
    id: tabBar
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(10)
    width: tabRow.width
    height: tabRow.height + Style.space(8)

    Row {
      id: tabRow
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(26)

      Repeater {
        id: tabs
        model: [
          { key: "artwork", label: "Artwork" },
          { key: "lyrics",  label: "Lyrics" },
          { key: "info",    label: "Info" }
        ]

        Text {
          id: tab
          required property int index
          required property var modelData

          readonly property bool current: root.face === tab.modelData.key
          readonly property bool usable: {
            if (tab.modelData.key === "lyrics") return root.hasLyrics
            if (tab.modelData.key === "info") return root.svc && root.svc.isTidalTrack
            return true
          }

          text: tab.modelData.label
          color: tab.current ? root.foreground
                             : (tabHover.containsMouse && tab.usable ? root.foreground : Color.muted)
          opacity: tab.usable ? 1 : 0.35
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 0.8

          Behavior on color { ColorAnimation { duration: Design.fast } }
          Behavior on opacity { NumberAnimation { duration: Design.fast } }

          MouseArea {
            id: tabHover
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            enabled: tab.usable
            cursorShape: Qt.PointingHandCursor
            onClicked: root.face = tab.modelData.key
          }
        }
      }
    }

    Rectangle {
      id: tabIndicator
      // Bound through itemAt so the rule tracks the live geometry of the
      // active word rather than a width guessed from its character count.
      readonly property var target: root.face === "lyrics" ? tabs.itemAt(1)
        : (root.face === "info" ? tabs.itemAt(2) : tabs.itemAt(0))

      x: tabRow.x + (target ? target.x : 0)
      width: target ? target.width : 0
      anchors.bottom: parent.bottom
      height: Math.max(1, Style.space(2))
      radius: height / 2
      color: Color.accent

      Behavior on x { NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic } }
    }
  }

  // Back to the list. The header has a Player button too, but the gesture that
  // expanded this view should have a visible way back inside it.
  HeaderButton {
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Style.space(6)
    glyph: "\uf066"
    tooltip: "Back to player"
    fontFamily: root.fontFamily
    foreground: root.foreground
    onActivated: root.contract()
  }
}
