import QtQuick
import qs.Commons
import "../lib/Design.js" as Design

// What the keyboard does, on the keyboard.
//
// Every action in this plugin has a key, and until now the only place that was
// written down was the README. A shell whose premise is the keyboard should be
// able to answer the question itself, so `?` puts the whole map on screen.
//
// Grouped by where a key works rather than by what it does: the same arrows
// mean different things in a list, on the Home grid and in the queue, and
// hiding that behind one merged table would be a tidier lie.
Item {
  id: root

  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  signal closed()

  readonly property var groups: [
    {
      title: "Anywhere in Omarchy",
      keys: [
        { keys: "Super + M", what: "Open the player" },
        { keys: "Super + Shift + M", what: "Now playing, on the lyrics" },
        { keys: "Super + Alt + M", what: "Favourite what is playing" },
        { keys: "Super + Ctrl + M", what: "Start radio from it" }
      ]
    },
    {
      title: "In the player",
      keys: [
        { keys: "/", what: "Search" },
        { keys: "↑ ↓", what: "Move" },
        { keys: "Enter", what: "Play" },
        { keys: "Shift + Enter", what: "Add to the queue" },
        { keys: "→", what: "Open the page" },
        { keys: "←  Backspace", what: "Back" },
        { keys: "Tab", what: "Sidebar and back" },
        { keys: "P", what: "Add to a playlist" },
        { keys: "M", what: "Quick menu" },
        { keys: "?", what: "This list" },
        { keys: "Space", what: "Play or pause" },
        { keys: "Esc", what: "Close" }
      ]
    },
    {
      title: "On Home",
      keys: [
        { keys: "↑ ↓", what: "Between shelves" },
        { keys: "← →", what: "Along a shelf" },
        { keys: "Enter", what: "Open the card" },
        { keys: "Shift + Enter", what: "Play it" }
      ]
    },
    {
      title: "In the queue",
      keys: [
        { keys: "Enter", what: "Jump to that track" },
        { keys: "Ctrl + ↑ ↓", what: "Move it up or down" },
        { keys: "Delete", what: "Take it out" }
      ]
    },
    {
      title: "Now playing",
      keys: [
        { keys: "A", what: "Artwork" },
        { keys: "L", what: "Lyrics" },
        { keys: "I", what: "The record" }
      ]
    }
  ]

  Keys.onEscapePressed: root.closed()
  Keys.onPressed: function(event) {
    // Any second press of the key that opened it closes it again.
    if (event.key === Qt.Key_Question || event.key === Qt.Key_Slash) {
      root.closed()
      event.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Color.menu.background
    opacity: root.visible ? 0.72 : 0
    Behavior on opacity { NumberAnimation { duration: Design.fast } }

    MouseArea {
      anchors.fill: parent
      onClicked: root.closed()
    }
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(Style.space(720), parent.width - Style.space(60))
    height: Math.min(content.implicitHeight + Style.space(34),
                     parent.height - Style.space(50))
    radius: Style.cornerRadius
    color: Color.menu.background
    border.width: Math.max(1, Style.space(1))
    border.color: Color.menu.border

    MouseArea { anchors.fill: parent }

    Column {
      id: content
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(17)
      spacing: Style.space(14)

      Text {
        textFormat: Text.PlainText
        text: "Keyboard"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.weight: Font.DemiBold
      }

      // Two columns of groups, because five stacked sections is a scroll and
      // this should be readable at a glance.
      Row {
        width: parent.width
        spacing: Style.space(26)

        Repeater {
          model: 2

          Column {
            id: column
            required property int index

            width: (content.width - Style.space(26)) / 2
            spacing: Style.space(14)

            Repeater {
              model: root.groups

              Column {
                id: group
                required property int index
                required property var modelData

                // Alternate groups down the two columns.
                visible: group.index % 2 === column.index
                width: column.width
                spacing: Style.space(5)

                Text {
                  textFormat: Text.PlainText
                  text: group.modelData.title.toUpperCase()
                  color: Color.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.3
                  bottomPadding: Style.space(2)
                }

                Repeater {
                  model: group.modelData.keys

                  Item {
                    id: row
                    required property var modelData

                    width: group.width
                    height: Style.space(19)

                    Text {
                      textFormat: Text.PlainText
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(120)
                      text: row.modelData.keys
                      elide: Text.ElideRight
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(126)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: row.modelData.what
                      elide: Text.ElideRight
                      color: root.foreground
                      opacity: 0.85
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "Media keys work everywhere; they drive MPRIS directly."
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
