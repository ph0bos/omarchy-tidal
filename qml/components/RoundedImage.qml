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

  // Decode to this many pixels a side, rather than to whatever the file
  // happens to be.
  //
  // A 320x320 sleeve decodes to 400 KB of RGBA whether it is drawn at 320
  // pixels or at 34, and a library view holds a lot of rows. Set it to roughly
  // the size the image is drawn at -- allowing for a HiDPI screen -- and Qt
  // keeps that instead. 0 means "as the file is", for anything drawn at full
  // size.
  //
  // Pin it rather than binding it to `width`: Qt reloads the image when this
  // changes, so an animating size would re-decode on every frame.
  property int decodeSize: 0

  readonly property bool ready: image.status === Image.Ready

  // Rendered to a texture and used only as the mask; never drawn itself.
  Rectangle {
    id: mask
    anchors.fill: parent
    radius: root.radius
    color: "black"
    visible: false
    antialiasing: true
    layer.enabled: true
    layer.smooth: true
    // Multisampled: the mask is what draws the corner, so a jagged mask is a
    // jagged sleeve, and at this size the stair-stepping was visible without
    // looking for it.
    layer.samples: 4
  }

  // The placeholder is inside the masked item so an empty slot keeps the same
  // silhouette as a loaded one -- no square flash before art arrives.
  Item {
    anchors.fill: parent
    layer.enabled: true
    layer.smooth: true
    layer.samples: 4
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: mask
      maskThresholdMin: 0.5
      // A wider spread is what antialiases the cut. At 0.1 the threshold is
      // effectively binary and every corner is a staircase.
      maskSpreadAtMin: 0.45
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
      sourceSize.width: root.decodeSize
      sourceSize.height: root.decodeSize
      fillMode: root.fillMode
      asynchronous: true
      cache: true
      smooth: true
      mipmap: true
      visible: status === Image.Ready
    }
  }
}
