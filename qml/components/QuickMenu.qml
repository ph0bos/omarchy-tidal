import QtQuick
import qs.Commons

// Small popup of the actions you want without opening the player: playback
// modes, radio, favourite, and the jumps to the two full views.
//
// Rendered inline by whatever hosts it rather than as its own layer-shell
// surface, because a plugin only gets one panel-kind entry point and that is
// already spent on the overlay.
Item {
  id: root

  property var svc: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property bool open: false

  signal requested(string action)

  readonly property bool isTidal: svc ? svc.isTidalTrack : false
  readonly property bool favorited: svc ? svc.favorite : false
  readonly property bool shuffled: svc ? svc.shuffle : false
  readonly property string repeatMode: svc ? svc.repeatMode : "off"

  // Each row: glyph, label, action, an optional live state string, and whether
  // it applies to what is playing right now.
  readonly property var items: [
    { glyph: "\uf001", label: "Open player",     action: "player",   state: "", enabled: true },
    { glyph: "\uf036", label: "Now playing",     action: "lyrics",   state: "", enabled: true },
    { glyph: "",       label: "",                action: "sep",      state: "", enabled: true },
    { glyph: root.favorited ? "\uf004" : "\uf08a",
      label: root.favorited ? "Remove favourite" : "Add to favourites",
      action: "favorite", state: "", enabled: root.isTidal },
    { glyph: "\uf012", label: "Start radio",     action: "radio",    state: "", enabled: root.isTidal },
    { glyph: "\uf03a", label: "Add to playlist", action: "playlist", state: "", enabled: root.isTidal },
    { glyph: "",       label: "",                action: "sep",      state: "", enabled: true },
    { glyph: "\uf074", label: "Shuffle",         action: "shuffle",
      state: root.shuffled ? "on" : "off", enabled: true },
    { glyph: "\uf01e", label: "Repeat",          action: "repeat",
      state: root.repeatMode, enabled: true },
    { glyph: "\uf28b", label: "Pause after track", action: "consume", state: "", enabled: true }
  ]

  implicitWidth: Style.space(214)
  implicitHeight: column.implicitHeight + Style.space(12)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.menu.background
    border.width: Math.max(1, Style.space(1))
    border.color: Color.menu.border

    Column {
      id: column
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.space(6)
      spacing: 0

      Repeater {
        model: root.items

        Item {
          id: entry
          required property var modelData
          width: column.width
          height: entry.modelData.action === "sep" ? Style.space(9) : Style.space(30)

          // Separator
          Rectangle {
            visible: entry.modelData.action === "sep"
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            height: Math.max(1, Style.space(1))
            color: Color.menu.border
            opacity: 0.45
          }

          Rectangle {
            visible: entry.modelData.action !== "sep"
            anchors.fill: parent
            anchors.leftMargin: Style.space(5)
            anchors.rightMargin: Style.space(5)
            radius: Style.space(3)
            color: hover.containsMouse && entry.modelData.enabled
              ? Color.menu.selectedBackground : "transparent"

            Text {
              textFormat: Text.PlainText
              id: icon
              anchors.left: parent.left
              anchors.leftMargin: Style.space(9)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              text: entry.modelData.glyph
              color: entry.modelData.state === "on" || entry.modelData.state === "all"
                     || entry.modelData.state === "single"
                ? Color.accent : Color.muted
              opacity: entry.modelData.enabled ? 1.0 : 0.35
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: icon.right
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: entry.modelData.label
              color: root.foreground
              opacity: entry.modelData.enabled ? 1.0 : 0.35
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Live state on the right: "on", "all", "single".
            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              visible: entry.modelData.state !== ""
              text: entry.modelData.state
              color: entry.modelData.state === "off" ? Color.muted : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              enabled: entry.modelData.enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.requested(entry.modelData.action)
            }
          }
        }
      }
    }
  }
}
