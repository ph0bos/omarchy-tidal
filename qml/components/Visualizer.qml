import QtQuick
import Quickshell.Io
import qs.Commons

// Live spectrum analyser, drawn old-school: monochrome segmented columns with
// falling peak-hold caps, in the theme's own foreground colour.
//
// Deliberately not neon. This sits inside Omarchy, which is monochrome and
// restrained, and a two-colour gradient would be the one loud thing on screen.
// The segmentation is what carries the character instead.
//
// The data is real: `bin/omarchy-tidal-cava` streams an FFT from PipeWire's
// default sink monitor, one line of magnitudes per frame. Reading the sink
// monitor rather than Mopidy means the bars follow whatever is audible.
//
// Painted on a single Canvas rather than a few hundred Rectangles: at 36 bars
// by 18 segments a per-segment item tree would be ~650 nodes rebinding at 60fps.
Item {
  id: root

  property bool active: false

  // Attaching and detaching a PipeWire capture stream makes the graph
  // re-negotiate, and with rate-following enabled that is audible as a dropout
  // in whatever is playing. Flicking between views would otherwise restart cava
  // every time, so the capture is held open briefly after it stops being
  // needed and reused if the view comes back.
  property int stopGraceMs: 6000
  property bool capturing: false
  property int bars: 36
  property int framerate: 60
  property string binPath: ""

  // Segments per column. Fewer reads chunkier and more "hardware".
  property int segments: 18
  property real segmentGap: 2
  property real columnGap: 3

  property color litColor: Color.menu.text
  property color dimColor: Color.muted
  property color peakColor: Color.accent
  property real dimOpacity: 0.10

  property real floorLevel: 0.0

  // Normalised 0..1 magnitudes, newest frame.
  property var levels: []
  // Peak-hold per column, decaying a little each frame.
  property var peaks: []
  property real peakFall: 0.012

  readonly property int barCount: levels.length > 0 ? levels.length : bars

  Timer {
    id: stopGrace
    interval: root.stopGraceMs
    onTriggered: root.capturing = false
  }

  onActiveChanged: {
    if (root.active) {
      stopGrace.stop()
      root.capturing = true
    } else {
      stopGrace.restart()
    }
    canvas.requestPaint()
  }

  Component.onDestruction: stopGrace.stop()

  Process {
    id: cava
    running: root.capturing && root.binPath !== ""
    command: [root.binPath, String(root.bars), String(root.framerate)]

    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text === "") return
        var parts = text.split(";")
        var out = []
        for (var i = 0; i < parts.length; i++) {
          if (parts[i] === "") continue
          var v = parseInt(parts[i], 10)
          if (isNaN(v)) continue
          out.push(Math.max(0, Math.min(1, v / 1000)))
        }
        if (out.length === 0) return

        // Peak-hold: jump to a new maximum instantly, fall back slowly. This is
        // the detail that makes an analyser read as an analyser.
        var held = root.peaks
        var next = []
        for (var j = 0; j < out.length; j++) {
          var prev = (held && held.length > j) ? held[j] : 0
          next.push(out[j] >= prev ? out[j] : Math.max(out[j], prev - root.peakFall))
        }
        root.levels = out
        root.peaks = next
        canvas.requestPaint()
      }
    }

    onExited: function(exitCode) {
      root.levels = []
      root.peaks = []
      canvas.requestPaint()
    }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      if (width <= 0 || height <= 0) return

      var count = root.barCount
      if (count <= 0) return

      var colW = (width - root.columnGap * (count - 1)) / count
      if (colW <= 0) return

      var segH = (height - root.segmentGap * (root.segments - 1)) / root.segments
      if (segH <= 0) return

      var lit = root.litColor
      var dim = root.dimColor
      var peak = root.peakColor

      for (var i = 0; i < count; i++) {
        var x = i * (colW + root.columnGap)
        var level = root.levels.length > i ? root.levels[i] : root.floorLevel
        var litCount = Math.round(level * root.segments)
        var peakLevel = root.peaks.length > i ? root.peaks[i] : 0
        var peakIndex = Math.min(root.segments - 1, Math.round(peakLevel * root.segments) - 1)

        for (var s = 0; s < root.segments; s++) {
          // Segment 0 is the bottom of the column.
          var y = height - (s + 1) * segH - s * root.segmentGap
          var on = s < litCount

          if (s === peakIndex && peakIndex >= 0) {
            ctx.globalAlpha = 0.95
            ctx.fillStyle = peak
          } else if (on) {
            // Slight lift toward the top of a column so tall hits read louder.
            ctx.globalAlpha = 0.55 + 0.45 * (s / root.segments)
            ctx.fillStyle = lit
          } else {
            ctx.globalAlpha = root.dimOpacity
            ctx.fillStyle = dim
          }

          ctx.fillRect(x, y, colW, segH)
        }
      }
      ctx.globalAlpha = 1.0
    }
  }

  // Repaint when the theme swaps the resolved colours out from under us.
  onLitColorChanged: canvas.requestPaint()
  onDimColorChanged: canvas.requestPaint()
  onPeakColorChanged: canvas.requestPaint()

  // Drain the bars while the capture is winding down so a hidden analyser is
  // not left frozen mid-frame when it comes back.
  onCapturingChanged: {
    if (!root.capturing) {
      root.levels = []
      root.peaks = []
      canvas.requestPaint()
    }
  }

  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
}
