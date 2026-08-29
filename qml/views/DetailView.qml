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

  property var page: null
  property bool loading: false
  property string errorText: ""
  property bool bioExpanded: false

  readonly property bool isArtist: uri.indexOf("tidal:artist:") === 0
  readonly property string body: {
    if (!page) return ""
    return String((isArtist ? page.bio : page.review) || "")
  }
  readonly property var mentions: {
    if (!page) return []
    return (isArtist ? page.bio_links : page.review_links) || []
  }

  signal openUri(string uri, string title)
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
    if (!wantArtist && !wantAlbum) {
      root.errorText = "Not an artist or album: " + want
      return
    }
    root.page = null
    root.bioExpanded = false
    root.loading = true
    root.errorText = ""

    function ok(payload) {
      if (!root.alive || root.uri !== want) return
      root.page = payload
      root.loading = false
    }
    function fail(err) {
      if (!root.alive || root.uri !== want) return
      root.loading = false
      root.errorText = "Could not load " + want + "\n" + err
    }

    if (wantArtist) Tidal.artist(want, ok, fail)
    else Tidal.album(want, ok, fail)
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
    Qt.openUrlExternally(String(root.page.share_url))
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
    if (page.artist) parts.push(page.artist)
    if (page.year) parts.push(String(page.year))
    if (page.num_tracks) parts.push(page.num_tracks + (page.num_tracks === 1 ? " track" : " tracks"))
    if (page.duration) parts.push(Math.round(page.duration / 60) + " min")
    return parts.join("  ·  ")
  }

  Text {
    anchors.centerIn: parent
    visible: root.loading || root.errorText !== ""
    text: root.loading ? "Loading…" : root.errorText
    color: Color.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
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
          source: root.page && root.page.image ? root.page.image : ""
        }

        Column {
          width: parent.width - Style.space(166)
          spacing: Style.space(8)

          Text {
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
          text: root.isArtist ? "BIOGRAPHY" : "REVIEW"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
        }

        Text {
          width: parent.width
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
          text: root.isArtist ? "TOP TRACKS" : "TRACKS"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
          bottomPadding: Style.space(4)
        }

        Repeater {
          id: trackRepeater
          model: root.page ? (root.isArtist ? root.page.top_tracks : root.page.tracks) : []

          TrackRow {
            id: trackItem
            required property var modelData
            width: column.width
            row: ({
              uri: modelData.uri,
              name: modelData.name,
              subtitle: modelData.album || modelData.artist || "",
              type: "track",
              header: false
            })
            playing: root.svc && Library.sameTrack(root.svc.trackUri, trackItem.modelData.uri)
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily

            onActivated: Rpc.playNow([trackItem.modelData.uri])
            onQueued: Rpc.queue([trackItem.modelData.uri], function() {
              if (root.svc) root.svc.osd("Added to queue", "media")
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
            text: gridSection.modelData.title
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
          }

          Flow {
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: gridSection.modelData.items

              Column {
                id: card
                required property var modelData
                width: Style.space(104)
                spacing: Style.space(5)

                RoundedImage {
                  width: parent.width
                  height: width
                  radius: card.modelData.type === "artist" ? width / 2 : Style.space(4)
                  source: card.modelData.image || ""

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.openUri(card.modelData.uri, card.modelData.name)
                  }
                }

                Text {
                  width: parent.width
                  text: card.modelData.name
                  elide: Text.ElideRight
                  maximumLineCount: 2
                  wrapMode: Text.WordWrap
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
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
