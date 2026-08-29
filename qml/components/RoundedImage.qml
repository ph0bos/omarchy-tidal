import QtQuick
import QtQuick.Effects
import qs.Commons

// An image with genuinely rounded (or circular) corners.
//
// `clip: true` on a Rectangle only clips to the bounding box, not the rounded
// shape, so album art in a "rounded" frame still renders with square corners.
// Masking through MultiEffect is what Omarchy's own image picker and tray do.
//
// Set `radius` to width/2 for a circle -- artist photos read as portraits that
// way, which is the convention every music app uses to separate people from
// records.
Item {
  id: root

  property string source: ""
  property real radius: 4
  // 0 = sharp. The now-playing backdrop turns this up so the sleeve behind the
  // page reads as its colour rather than as a second, competing picture.
  property real blur: 0
  property color placeholderColor: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.12)
  property int fillMode: Image.PreserveAspectCrop

  readonly property bool ready: image.status === Image.Ready

  // Rendered to a texture and used only as the mask; never drawn itself.
  Rectangle {
    id: mask
    anchors.fill: parent
    radius: root.radius
    color: "black"
    visible: false
    layer.enabled: true
    layer.smooth: true
  }

  // The placeholder is inside the masked item so an empty slot keeps the same
  // silhouette as a loaded one -- no square flash before art arrives.
  Item {
    anchors.fill: parent
    layer.enabled: true
    layer.smooth: true
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: mask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.1
      blurEnabled: root.blur > 0
      blur: root.blur
      blurMax: 48
    }

    Rectangle {
      anchors.fill: parent
      color: root.placeholderColor
    }

    Image {
      id: image
      anchors.fill: parent
      source: root.source
      fillMode: root.fillMode
      asynchronous: true
      cache: true
      smooth: true
      mipmap: true
      visible: status === Image.Ready
    }
  }
}
