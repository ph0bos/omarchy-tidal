import QtQuick
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Library.js" as Library
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
  // Through the companion's cache when it is a Tidal asset, untouched when it
  // is anything else -- MPRIS art can be a local file.
  // Scrims and labels that sit on top of album art. Derived from the theme
  // rather than hardcoded black and white: Omarchy ships light themes, and a
  // black wash under white text is only correct on half of them.
  readonly property color scrim: Qt.rgba(Color.menu.background.r, Color.menu.background.g,
                                         Color.menu.background.b, 1)
  readonly property color onArt: Color.menu.text

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

  // The colour this view paints artwork-adjacent things with.
  readonly property color artAccent: root.svc
    ? root.tintFrom(root.svc.artColor, Color.menu.background) : Color.accent

  // How light the sleeve is, which decides how much wash the text needs. A
  // white cover lifts the blurred backdrop until muted metadata disappears
  // into it -- measured at 1.15:1 against a Bring Me The Horizon sleeve, where
  // 4.5:1 is the readable floor.
  readonly property real artLuma: root.svc ? root.svc.artLuma : 0

  // Optical alignment between the sleeve and the column beside it.
  //
  // A picture's top is a hard edge; a line of text's top is the top of its line
  // box, which carries the ascent above the capitals. Aligning the two puts the
  // words a few pixels low, and two columns that are almost level read as a
  // mistake rather than as a decision. Qt reports both numbers, so the gap is
  // measured rather than nudged.
  FontMetrics {
    id: eyebrowMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  FontMetrics {
    id: metaMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
  }

  readonly property real eyebrowCapGap: eyebrowMetrics.ascent - eyebrowMetrics.capitalHeight
  readonly property real metaCapGap: metaMetrics.ascent - metaMetrics.capitalHeight

  // What the column beside the sleeve is, said once at its top. On the lyric
  // sheet it also carries where the words came from, which is a real question
  // when the companion falls back from TIDAL to LRCLIB.
  readonly property string paneLabel: {
    if (root.face === "info") return "ALBUM"
    if (root.source === "") return "LYRICS"
    return "LYRICS \u00b7 " + (root.source === "tidal" ? "TIDAL" : root.source.toUpperCase())
  }

  readonly property string artUrl: svc ? Tidal.artProxy(svc.artUrl, 640) : ""

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

  // The sheet as it is displayed: the sung lines with instrumental markers
  // folded in. Held as one list so the view has a single model and the active
  // index means the same thing for both kinds of entry.
  readonly property var lines: root.hasSynced ? Lrc.withGaps(root.synced, 10000) : []
  readonly property real gapProgress: {
    var entry = root.lines[root.activeIndex]
    if (!entry || !entry.gap) return 0
    return Lrc.gapProgress(entry, (root.svc ? root.svc.position : 0) * 1000 + root.leadMs)
  }
  readonly property bool hasLyrics: hasSynced || plain !== ""

  // Lyrics displayed dead-on read late; a small lead lands the highlight with
  // the vocal rather than after it.
  readonly property int leadMs: 250
  readonly property int activeIndex: root.hasSynced
    ? Lrc.activeIndex(root.lines, (root.svc ? root.svc.position : 0) * 1000 + root.leadMs)
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

  // The artist page, fetched only as a fallback.
  //
  // Most records have no editorial review -- TIDAL writes them for maybe one
  // release in five -- and an info panel that answers "nothing to say about
  // this album" is worse than one that says something true instead. When the
  // review comes back empty, the artist's biography takes its place, which is
  // what the native client falls back to as well.
  property var artistPage: null
  property bool artistLoading: false
  property bool narrativeExpanded: false

  function loadArtist(artistUri) {
    if (!artistUri || root.artistLoading) return
    if (root.artistPage && String(root.artistPage.uri) === artistUri) return
    root.artistLoading = true
    Tidal.artist(artistUri, function(page) {
      if (!root.alive) return
      root.artistPage = page
      root.artistLoading = false
    }, function() {
      if (!root.alive) return
      root.artistLoading = false
    })
  }

  // What the narrative section says, and what to call it.
  readonly property string narrative: {
    if (root.album && root.album.review) return String(root.album.review)
    if (root.artistPage && root.artistPage.bio) return String(root.artistPage.bio)
    return ""
  }
  readonly property string narrativeLabel: {
    if (root.album && root.album.review) return "REVIEW"
    if (root.artistPage && root.artistPage.name)
      return "ABOUT " + String(root.artistPage.name).toUpperCase()
    return ""
  }

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
        if (!page.review && page.artist_uri) root.loadArtist(String(page.artist_uri))
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

  onFaceChanged: {
    if (root.face === "info") root.loadAlbum()
    // Coming back to the sheet, the next placement is a cut rather than a
    // glide: a sheet that fades in and then scrolls has arrived twice.
    if (root.face === "lyrics") lyricList.snapNext = true
  }
  onTrackUriChanged: {
    // A different song's sheet also arrives in place rather than scrolling to it.
    lyricList.snapNext = true
    root.album = null
    root.albumForTrack = ""
    root.albumLoading = false
    root.narrativeExpanded = false
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

  readonly property string releaseLine: {
    if (!root.album) return ""
    var when = Design.releaseDate(root.album.release_date)
    return when === "" ? "" : "Released " + when
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
    // Blurred past recognition and then faded, so it has no use for detail:
    // 128 pixels a side is a fortieth of the memory of the full sleeve and
    // looks exactly the same once the blur is on it.
    decodeSize: 128
    // A bright sleeve is shown less of, because everything drawn on top has to
    // stay legible over it.
    opacity: 0.28 - 0.16 * root.artLuma
    visible: source !== ""
  }

  Rectangle {
    anchors.fill: parent
    // The wash under the text grows with the sleeve's brightness, so the
    // metadata keeps its contrast whatever the cover happens to be.
    gradient: Gradient {
      GradientStop {
        position: 0.0
        color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0.15 + 0.3 * root.artLuma)
      }
      GradientStop {
        position: 1.0
        color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0.55 + 0.42 * root.artLuma)
      }
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

      TiltFrame {
        width: parent.width
        height: width
        radius: Style.space(6)
        // The sleeve is the subject of this page, so it is the one thing that
        // leans. Only on the artwork face: tilting a 200px thumbnail beside a
        // lyric sheet would be fidgeting.
        leanEnabled: root.face === "artwork"
        maxAngle: 13
        // The sleeve's own click area is the one that hears the pointer.
        active: artHover.containsMouse
        pointerX: artHover.mouseX
        pointerY: artHover.mouseY

        RoundedImage {
          anchors.fill: parent
          radius: Style.space(6)
          source: root.artUrl
          // Pinned to the biggest it is ever drawn: this one animates between
          // faces, and a bound decode size would re-decode on every frame.
          decodeSize: 512
        }

        // No wash and no word over the artwork. The tabs below already name
        // the faces, and the lean under the pointer says the sleeve is live --
        // a label on top of the picture was saying a third time what two other
        // things already said, over the one thing worth looking at.

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
        // Pulled up by the ascent gap so the space between the sleeve and the
        // title is the space you can see, not the space plus the invisible
        // room above the capitals.
        topPadding: -root.metaCapGap

        Text {
          textFormat: Text.PlainText
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
          textFormat: Text.PlainText
          width: parent.width
          text: root.svc ? root.svc.artist : ""
          elide: Text.ElideRight
          horizontalAlignment: root.face === "artwork" ? Text.AlignHCenter : Text.AlignLeft
          // Foreground dimmed, not `muted`: muted is a colour for the theme's
          // own chrome, and over a bright sleeve it measured 1.15:1.
          color: artistLink.containsMouse ? root.artAccent : root.foreground
          // Dimming secondary text is a choice worth making when the backdrop
          // allows it, and worth giving up when it does not: over a white
          // sleeve this rises until the line is readable again.
          opacity: 0.78 + 0.22 * root.artLuma
          font.family: root.fontFamily
          font.pixelSize: root.face === "artwork" ? Style.font.subtitle : Style.font.bodySmall

          Behavior on color { ColorAnimation { duration: Design.fast } }

          // The name of a thing is the way to its page, here as everywhere else
          // in the plugin.
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
          horizontalAlignment: root.face === "artwork" ? Text.AlignHCenter : Text.AlignLeft
          color: albumLink.containsMouse ? root.artAccent : root.foreground
          opacity: 0.6 + 0.35 * root.artLuma
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          Behavior on color { ColorAnimation { duration: Design.fast } }

          MouseArea {
            id: albumLink
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.svc && root.svc.albumUri !== ""
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openUri(root.svc.albumUri, root.svc.album)
          }
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
        // Beside the record, in the record's own colour.
        litColor: root.artAccent
        peakColor: root.artAccent
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
      // Lifted by the ascent gap so the eyebrow's capitals sit on the sleeve's
      // top edge, and made that much taller so it still reaches the bottom.
      y: -root.eyebrowCapGap
      height: stage.height + root.eyebrowCapGap
      opacity: root.face === "artwork" ? 0 : 1
      visible: opacity > 0.01

      // No Behavior on x. The pane's column depends on the sleeve's size, so
      // animating it sent the two sliding toward each other at once, which is
      // two things moving where the eye wants one. It repositions while it is
      // invisible instead, and only its opacity is animated.
      Behavior on opacity {
        SequentialAnimation {
          // Arriving, wait for the sleeve to be under way; leaving, go at once.
          PauseAnimation { duration: root.face === "artwork" ? 0 : Design.stagger }
          NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic }
        }
      }

      // A short rise as it arrives, settling back as it goes. Small enough to
      // be felt rather than watched.
      transform: Translate {
        y: root.face === "artwork" ? Style.space(14) : 0
        Behavior on y {
          NumberAnimation { duration: Design.base + Design.stagger; easing.type: Easing.OutCubic }
        }
      }

      Text {
        id: eyebrow
        textFormat: Text.PlainText
        anchors.top: parent.top
        anchors.left: parent.left
        text: root.paneLabel
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.3
      }

      // ---- lyrics ----
      Item {
        anchors.top: eyebrow.bottom
        anchors.topMargin: Style.space(16)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        opacity: root.face === "lyrics" ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: Design.base } }

        Text {
          textFormat: Text.PlainText
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
          model: root.lines
          spacing: Style.space(15)
          boundsBehavior: Flickable.StopAtBounds

          // No highlight range: it moves contentY on its own and would fight
          // the glide below for the same property.

          // Set while the sheet is arriving, so its first placement is a cut
          // rather than a glide. A sheet that fades in and *then* scrolls to
          // the right line has arrived twice.
          property bool snapNext: true

          // Apple Music and TIDAL both slide the sheet rather than cutting to
          // the next line, and the movement is most of what makes a lyric
          // sheet feel like it is keeping time with the song. The view is
          // asked where the line would land, then animated there.
          function centerOn(index) {
            if (index < 0 || index >= count) return
            var from = contentY
            positionViewAtIndex(index, ListView.Center)
            var to = contentY
            if (snapNext) { snapNext = false; return }
            if (Math.abs(to - from) < 1) return
            contentY = from
            glide.to = to
            glide.restart()
          }

          NumberAnimation {
            id: glide
            target: lyricList
            property: "contentY"
            duration: Design.slow
            easing.type: Easing.OutCubic
          }

          // A drag should not be fought by the next line arriving mid-gesture.
          onMovingChanged: if (moving) glide.stop()

          delegate: Item {
            id: lyricLine
            required property int index
            required property var modelData

            readonly property bool isGap: modelData.gap === true
            readonly property bool isActive: lyricLine.index === root.activeIndex
            readonly property bool isPast: lyricLine.index < root.activeIndex

            width: lyricList.width
            height: lyricLine.isGap ? dots.height : line.implicitHeight

            // ---- a sung line ----
            Text {
              id: line
              textFormat: Text.PlainText
              visible: !lyricLine.isGap
              // A lyric sheet set the full width of the pane is a paragraph,
              // not a song; capping the measure keeps it a column you read
              // down rather than across.
              width: Math.min(lyricList.width, Style.space(520))
              text: String(lyricLine.modelData.text || "")
              wrapMode: Text.WordWrap
              lineHeight: 1.25

              // One colour, dimmed by opacity. Colouring the inactive lines
              // muted *and* fading them dimmed them twice, which left a sheet
              // you had to work to read at all.
              color: root.foreground
              opacity: lyricLine.isActive ? 1.0
                       : (hover.containsMouse ? 0.85 : (lyricLine.isPast ? 0.42 : 0.62))
              font.family: root.fontFamily
              // A real jump, not a nudge: the line being sung should be
              // findable without reading any of the others.
              font.pixelSize: lyricLine.isActive ? Style.font.heading : Style.font.subtitle
              font.weight: lyricLine.isActive ? Font.DemiBold : Font.Normal

              Behavior on opacity { NumberAnimation { duration: Design.base } }
              Behavior on color { ColorAnimation { duration: Design.fast } }
              Behavior on font.pixelSize {
                NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic }
              }
            }

            // ---- an instrumental ----
            //
            // Three dots that fill as the gap runs down, so a long solo reads
            // as the song still playing rather than as a sheet that has stuck.
            Row {
              id: dots
              visible: lyricLine.isGap
              spacing: Style.space(6)
              height: Style.space(20)

              Repeater {
                model: 3

                Rectangle {
                  id: dot
                  required property int index

                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: root.foreground
                  // Each dot owns a third of the gap, and lights when the
                  // playhead reaches it.
                  readonly property real reached:
                    lyricLine.isActive
                      ? Math.max(0, Math.min(1, root.gapProgress * 3 - dot.index))
                      : 0
                  opacity: 0.18 + 0.72 * reached

                  Behavior on opacity { NumberAnimation { duration: Design.base } }
                }
              }
            }

            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              // The one interaction a synced lyric sheet should always have.
              onClicked: {
                if (root.svc) root.svc.seekTo(Number(lyricLine.modelData.time_ms) || 0)
              }
            }
          }
        }

        // The sheet dissolves at the edges rather than being cut off by them.
        Rectangle {
          anchors.top: lyricList.top
          anchors.left: lyricList.left
          anchors.right: lyricList.right
          height: Style.space(36)
          visible: root.hasSynced
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0.85) }
            GradientStop { position: 1.0; color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0) }
          }
        }

        Rectangle {
          anchors.bottom: lyricList.bottom
          anchors.left: lyricList.left
          anchors.right: lyricList.right
          height: Style.space(48)
          visible: root.hasSynced
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0) }
            GradientStop { position: 1.0; color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0.9) }
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
            textFormat: Text.PlainText
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
        id: infoFlick
        anchors.top: eyebrow.bottom
        anchors.topMargin: Style.space(16)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        opacity: root.face === "info" ? 1 : 0
        visible: opacity > 0.01
        contentHeight: infoColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Behavior on opacity { NumberAnimation { duration: Design.base } }

        Column {
          id: infoColumn
          width: parent.width
          spacing: Style.space(14)
          // Room to scroll the last track clear of the face tabs, which float
          // over the bottom of this pane rather than sitting under it.
          bottomPadding: Style.space(52)

          // Prose is capped even though the pane is not: an editorial review
          // set the full width of a 1000px panel runs to 140 characters a
          // line, which is roughly twice what anyone can track back to the
          // next line. The track list is a table, so it takes the full width.
          readonly property real proseWidth: Math.min(width, Style.space(540))

          Text {
            textFormat: Text.PlainText
            width: infoColumn.proseWidth
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
            textFormat: Text.PlainText
            width: infoColumn.proseWidth
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
            textFormat: Text.PlainText
            width: infoColumn.proseWidth
            visible: root.albumMeta !== ""
            text: root.albumMeta
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: infoColumn.proseWidth
            visible: root.releaseLine !== ""
            text: root.releaseLine
            color: Color.muted
            opacity: 0.7
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
                textFormat: Text.PlainText
                id: qualityText
                anchors.centerIn: parent
                text: root.svc ? root.svc.qualityLabel : ""
                color: root.svc && root.svc.isHiRes ? Color.accent : Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              visible: root.svc && root.svc.isHiRes
              text: "HI-RES"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
            }
          }

          // ---- narrative ----
          //
          // The review if TIDAL wrote one, the artist's biography if it did
          // not. Clamped to a few lines with the rest a click away: a page
          // that opens with eight hundred words of prose has buried the track
          // list under it.
          Column {
            width: infoColumn.proseWidth
            spacing: Style.space(6)
            visible: root.narrative !== ""

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.narrativeLabel
              elide: Text.ElideRight
              color: Color.muted
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
            }

            Text {
              id: narrativeText
              textFormat: Text.PlainText
              width: parent.width
              text: root.narrative
              wrapMode: Text.WordWrap
              maximumLineCount: root.narrativeExpanded ? 0 : 6
              elide: root.narrativeExpanded ? Text.ElideNone : Text.ElideRight
              color: root.foreground
              opacity: 0.82
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              lineHeight: 1.45
            }

            Text {
              textFormat: Text.PlainText
              visible: narrativeText.truncated || root.narrativeExpanded
              text: root.narrativeExpanded ? "Show less" : "Read more"
              color: root.artAccent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.narrativeExpanded = !root.narrativeExpanded
              }
            }
          }

          // ---- tracks ----
          //
          // The record you are inside, in order, with the playing track lit.
          // This is the question the info face gets asked most -- what else is
          // on this album -- and answering it here saves a trip out to the
          // album page and back.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: infoTracks.count > 0

            Text {
              textFormat: Text.PlainText
              text: "TRACKS"
              color: Color.muted
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
            }

            Repeater {
              id: infoTracks
              model: root.album && root.album.tracks ? root.album.tracks : []

              TrackRow {
                id: infoTrack
                required property var modelData
                width: infoColumn.width
                row: ({
                  uri: modelData.uri,
                  name: modelData.name,
                  // The artist and the album are both stated above this list.
                  artist: "",
                  album: "",
                  subtitle: "",
                  image: modelData.image || "",
                  num: modelData.track_num || 0,
                  duration: modelData.duration || 0,
                  type: "track",
                  complete: true,
                  header: false
                })
                playing: root.svc
                  && Library.sameTrack(root.svc.trackUri, infoTrack.modelData.uri)
                foreground: root.foreground
                accent: root.artAccent
                fontFamily: root.fontFamily

                onActivated: Rpc.playNow([infoTrack.modelData.uri])
                onQueued: Rpc.queue([infoTrack.modelData.uri], function() {
                  if (!root.alive || !root.svc) return
                  root.svc.osd("Added to queue", "media")
                })
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: infoColumn.proseWidth
            visible: root.album && root.album.copyright
            text: root.album ? String(root.album.copyright || "") : ""
            wrapMode: Text.WordWrap
            color: Color.muted
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
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

      // The face tabs float over the bottom of this pane, so the track list
      // has to arrive under them rather than stop dead behind them. Same
      // treatment as the lyric sheet, for the same reason.
      Rectangle {
        anchors.bottom: infoFlick.bottom
        anchors.left: infoFlick.left
        anchors.right: infoFlick.right
        height: Style.space(48)
        opacity: root.face === "info" ? 1 : 0
        visible: opacity > 0.01
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0) }
          GradientStop { position: 1.0; color: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b, 0.9) }
        }
        Behavior on opacity { NumberAnimation { duration: Design.base } }
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
          textFormat: Text.PlainText
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
      readonly property var target: {
        // itemAt() is a call, not a property, so this binding has to be told
        // when the answer can change: on the face, and on the delegates coming
        // into existence. Without the count the rule sat at zero width under
        // the face the view opens on, and only appeared once you switched.
        var ready = tabs.count
        if (ready === 0) return null
        if (root.face === "lyrics") return tabs.itemAt(1)
        if (root.face === "info") return tabs.itemAt(2)
        return tabs.itemAt(0)
      }

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
