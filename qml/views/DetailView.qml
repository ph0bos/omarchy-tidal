import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../lib/MopidyRpc.js" as Rpc
import "../lib/TidalApi.js" as Tidal
import "../lib/Library.js" as Library

// Artist and album pages: everything TIDAL publishes about a record or a
// performer, in one scrolling surface.
//
// Both shapes come from a single companion request rather than five, so the
// page arrives complete instead of assembling itself in front of the user.
Item {
  id: root

  property var svc: null
  property string uri: ""
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  property bool alive: true
  Component.onDestruction: root.alive = false

  // The hero title sits beside the artwork, so it aligns to the sleeve's top
  // edge by its capitals rather than by its line box.
  FontMetrics {
    id: heroMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.display
  }

  readonly property real heroCapGap: heroMetrics.ascent - heroMetrics.capitalHeight

  property var page: null
  // The track list is held apart from the page so a row removed from a playlist
  // can leave without the whole page being fetched again.
  property var tracks: []
  property bool loading: false
  property string errorText: ""
  property bool bioExpanded: false

  readonly property bool isArtist: uri.indexOf("tidal:artist:") === 0
  readonly property bool isPlaylist: uri.indexOf("tidal:playlist:") === 0

  // Each kind calls its prose something different and TIDAL returns it under a
  // different name; the page shows it in the same place regardless.
  readonly property string body: {
    if (!page) return ""
    if (isArtist) return String(page.bio || "")
    if (isPlaylist) return String(page.description || "")
    return String(page.review || "")
  }
  readonly property string bodyLabel: {
    if (isArtist) return "BIOGRAPHY"
    if (isPlaylist) return "ABOUT"
    return "REVIEW"
  }
  readonly property var mentions: {
    if (!page || isPlaylist) return []
    var all = (isArtist ? page.bio_links : page.review_links) || []
    // TIDAL's editorial nearly always names the record it is reviewing, which
    // arrives as a link back to this very page. Drop it.
    var out = []
    for (var i = 0; i < all.length; i++) {
      if (all[i] && String(all[i].uri) !== root.uri) out.push(all[i])
    }
    return out
  }

  signal openUri(string uri, string title)
  // Emitted once the page resolves, so the breadcrumb can show the artist or
  // album name instead of the uri it was opened with.
  signal titleResolved(string title)
  signal back()

  onUriChanged: root.load()

  function load() {
    var want = root.uri
    if (want === "") { root.page = null; root.loading = false; root.errorText = ""; return }

    // Derive the kind from the argument, not from the isArtist binding:
    // onUriChanged runs before dependent bindings are re-evaluated, so
    // root.isArtist still describes the PREVIOUS uri at this point.
    var wantArtist = want.indexOf("tidal:artist:") === 0
    var wantAlbum = want.indexOf("tidal:album:") === 0
    var wantPlaylist = want.indexOf("tidal:playlist:") === 0
    if (!wantArtist && !wantAlbum && !wantPlaylist) {
      root.errorText = "No page for " + want
      return
    }
    root.page = null
    root.tracks = []
    root.bioExpanded = false
    root.loading = true
    root.errorText = ""

    function ok(payload) {
      if (!root.alive || root.uri !== want) return
      root.page = payload
      root.tracks = payload
        ? ((wantArtist ? payload.top_tracks : payload.tracks) || [])
        : []
      root.loading = false
      if (payload && payload.name) root.titleResolved(String(payload.name))
    }
    function fail(err) {
      if (!root.alive || root.uri !== want) return
      root.loading = false
      root.errorText = "Could not load " + want + "\n" + err
    }

    if (wantArtist) Tidal.artist(want, ok, fail)
    else if (wantPlaylist) Tidal.playlistPage(want, ok, fail)
    else Tidal.album(want, ok, fail)
  }

  // Take a track back out of a playlist. Dropped locally on success rather than
  // re-fetching the page: the list keeps its place, which is where the reader
  // is looking.
  function removeTrack(trackUri) {
    if (!root.isPlaylist || trackUri === "") return
    Tidal.playlistRemove(root.uri, [trackUri], function() {
      if (!root.alive) return
      var kept = []
      for (var i = 0; i < root.tracks.length; i++) {
        if (String(root.tracks[i].uri) !== trackUri) kept.push(root.tracks[i])
      }
      root.tracks = kept
      if (root.svc) root.svc.osd("Removed from " + String(root.page.name || "playlist"), "media")
    }, function(err) {
      // An OSD rather than the page's error slot: the page itself loaded fine,
      // and replacing it with an error message would be a strange answer to a
      // failed row removal.
      if (root.alive && root.svc) root.svc.osd("Could not remove: " + err, "media")
    })
  }

  function playAll() {
    if (!root.page) return
    Rpc.playNow([root.uri], null, function(err) { if (root.alive) root.errorText = err })
  }

  function queueAll() {
    if (!root.page) return
    Rpc.queue([root.uri], function() {
      if (root.alive && root.svc) root.svc.osd("Added to queue", "media")
    }, function(err) { if (root.alive) root.errorText = err })
  }

  function openInBrowser() {
    if (!root.page || !root.page.share_url) return
    // Handing a url straight to the desktop opener means handing it whatever
    // scheme the API returned. Only Tidal's own web address is worth opening.
    var url = String(root.page.share_url)
    if (url.indexOf("https://tidal.com/") !== 0 && url.indexOf("https://www.tidal.com/") !== 0) {
      if (root.svc) root.svc.osd("That link does not point at TIDAL", "media")
      return
    }
    Qt.openUrlExternally(url)
  }

  // Album: "1997 · 10 tracks · 43 min". Artist: the roles TIDAL lists.
  readonly property string metaLine: {
    if (!page) return ""
    var parts = []
    if (isArtist) {
      var roles = page.roles || []
      for (var i = 0; i < roles.length; i++) {
        parts.push(String(roles[i]).replace("Role.", ""))
      }
      return parts.join(" · ")
    }
    if (isPlaylist && page.creator) parts.push("by " + page.creator)
    if (page.artist) parts.push(page.artist)
    if (page.year) parts.push(String(page.year))
    if (page.num_tracks) parts.push(page.num_tracks + (page.num_tracks === 1 ? " track" : " tracks"))
    if (page.duration) parts.push(Math.round(page.duration / 60) + " min")
    return parts.join("  ·  ")
  }

  // The page arriving, in the shape it will arrive in.
  Row {
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(16)
    visible: root.loading

    Rectangle {
      width: Style.space(150)
      height: width
      radius: root.isArtist ? width / 2 : Style.space(5)
      color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.12)
    }

    Column {
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      spacing: Style.space(12)

      Rectangle {
        width: Style.space(260)
        height: Style.space(20)
        radius: Style.space(3)
        color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.14)
      }

      Rectangle {
        width: Style.space(170)
        height: Style.space(10)
        radius: Style.space(2)
        color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.10)
      }

      Rectangle {
        width: Style.space(120)
        height: Style.space(26)
        radius: Style.space(3)
        color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.08)
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: root.errorText !== "" && !root.loading
    width: parent.width - Style.space(80)
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: root.errorText
    color: Color.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  ScrollHint {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    target: flick
  }

  Flickable {
    id: flick
    anchors.fill: parent
    visible: root.page !== null && !root.loading
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: flick.width
      spacing: Style.space(16)

      // ---- hero ----
      Row {
        width: parent.width
        spacing: Style.space(16)

        RoundedImage {
          width: Style.space(150)
          height: width
          // Circular for people, softly rounded for records.
          radius: root.isArtist ? width / 2 : Style.space(5)
          decodeSize: 320
          source: root.page && root.page.image ? Tidal.artProxy(root.page.image, 640) : ""
        }

        Column {
          width: parent.width - Style.space(166)
          spacing: Style.space(8)
          topPadding: -root.heroCapGap

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.page ? root.page.name : ""
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.weight: Font.DemiBold
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.metaLine !== ""
            text: root.metaLine
            elide: Text.ElideRight
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Hi-res is the whole point of this plugin, so it gets a real badge.
          Rectangle {
            visible: root.page && root.page.hires === true
            width: hiresText.implicitWidth + Style.space(12)
            height: hiresText.implicitHeight + Style.space(5)
            radius: Style.space(3)
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)

            Text {
              textFormat: Text.PlainText
              id: hiresText
              anchors.centerIn: parent
              text: "HI-RES LOSSLESS"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.1
            }
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: "Play"
              bordered: true
              foreground: root.foreground
              accent: Color.accent
              onClicked: root.playAll()
            }

            Button {
              text: "Queue"
              bordered: true
              foreground: root.foreground
              accent: Color.accent
              onClicked: root.queueAll()
            }

            Button {
              visible: root.page && root.page.share_url
              text: "Open in TIDAL"
              foreground: Color.muted
              accent: Color.accent
              onClicked: root.openInBrowser()
            }
          }
        }
      }

      // ---- bio / review ----
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.body !== ""

        Text {
          textFormat: Text.PlainText
          text: root.bodyLabel
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
        }

        Text {
          textFormat: Text.PlainText
          // Capped: a bio set across the full width of the panel runs past 130
          // characters a line, which is about twice a comfortable measure.
          width: Math.min(parent.width, Style.space(600))
          text: root.body
          wrapMode: Text.WordWrap
          // TIDAL's bios run to tens of thousands of characters; show an
          // opening and let the reader ask for the rest.
          maximumLineCount: root.bioExpanded ? 10000 : 5
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          lineHeight: 1.35
        }

        Text {
          textFormat: Text.PlainText
          visible: root.body.length > 400
          text: root.bioExpanded ? "Show less" : "Read more"
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            onClicked: root.bioExpanded = !root.bioExpanded
          }
        }
      }

      // ---- mentions pulled out of the editorial copy ----
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.mentions.length > 0

        Text {
          textFormat: Text.PlainText
          text: "MENTIONED"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.mentions.slice(0, 14)

            Rectangle {
              id: chip
              required property var modelData
              width: chipText.implicitWidth + Style.space(14)
              height: chipText.implicitHeight + Style.space(7)
              radius: Style.space(3)
              color: chipHover.containsMouse
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
                : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.10)

              Text {
                textFormat: Text.PlainText
                id: chipText
                anchors.centerIn: parent
                text: chip.modelData.label
                color: chipHover.containsMouse ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: chipHover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.openUri(chip.modelData.uri, chip.modelData.label)
              }
            }
          }
        }
      }

      // ---- tracks ----
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: trackRepeater.count > 0

        Text {
          textFormat: Text.PlainText
          text: root.isArtist ? "TOP TRACKS" : "TRACKS"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
          bottomPadding: Style.space(4)
        }

        Repeater {
          id: trackRepeater
          model: root.tracks

          TrackRow {
            id: trackItem
            required property var modelData
            width: column.width
            row: ({
              uri: modelData.uri,
              name: modelData.name,
              // On an album page every row would otherwise repeat the album
              // name and the artist already in the hero above it. On an artist
              // page the record a top track comes from is worth saying.
              artist: root.isPlaylist ? (modelData.artist || "") : "",
              album: root.isArtist || root.isPlaylist ? (modelData.album || "") : "",
              subtitle: "",
              image: modelData.image || "",
              num: root.isPlaylist ? 0 : (modelData.track_num || 0),
              duration: modelData.duration || 0,
              type: "track",
              // Everything this row shows is already decided here, so it must
              // not go and fetch the artist back onto an artist's own page.
              complete: true,
              header: false
            })
            playing: root.svc && Library.sameTrack(root.svc.trackUri, trackItem.modelData.uri)
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily

            // Only your own playlists offer this, and only on hover.
            removable: root.isPlaylist && root.page && root.page.editable === true

            onRemoved: root.removeTrack(String(trackItem.modelData.uri))

            onActivated: Rpc.playNow([trackItem.modelData.uri])
            onQueued: Rpc.queue([trackItem.modelData.uri], function() {
              // Saving a file hot-reloads this view out from under an
              // in-flight request; reading svc afterwards is a use-after-free.
              if (!root.alive || !root.svc) return
              root.svc.osd("Added to queue", "media")
            })
          }
        }
      }

      // ---- discography / similar (artist only) ----
      Repeater {
        model: root.isArtist && root.page
          ? [{ title: "ALBUMS", items: root.page.albums || [] },
             { title: "SIMILAR ARTISTS", items: root.page.similar || [] }]
          : []

        Column {
          id: gridSection
          required property var modelData
          width: column.width
          spacing: Style.space(8)
          visible: gridSection.modelData.items.length > 0

          Text {
            textFormat: Text.PlainText
            text: gridSection.modelData.title
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
          }

          Flow {
            width: parent.width
            spacing: Style.space(12)

            Repeater {
              model: gridSection.modelData.items

              ArtCard {
                required property var modelData

                width: Style.space(112)
                entry: modelData
                foreground: root.foreground
                fontFamily: root.fontFamily

                onOpened: root.openUri(String(modelData.uri), String(modelData.name || ""))
                onActivated: Rpc.playNow([String(modelData.uri)])
              }
            }
          }
        }
      }

      // Breathing room at the end of the scroll.
      Item { width: 1; height: Style.space(8) }
    }
  }
}
