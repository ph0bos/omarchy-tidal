// Timing helpers for synced lyrics.
//
// The companion extension already parses LRC into [{time_ms, text}] sorted by
// time, so the only job here is finding which line is current. That runs on
// every position tick, so it is a binary search rather than a scan -- a long
// track can carry a few hundred lines.

// Index of the last line whose timestamp is <= positionMs, or -1 before the
// first line starts.
function activeIndex(lines, positionMs) {
  if (!lines || lines.length === 0) return -1
  var pos = Number(positionMs) || 0
  if (pos < Number(lines[0].time_ms || 0)) return -1

  var lo = 0
  var hi = lines.length - 1
  var best = -1
  while (lo <= hi) {
    var mid = (lo + hi) >> 1
    var t = Number(lines[mid].time_ms || 0)
    if (t <= pos) {
      best = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  return best
}

// Milliseconds until the next line, or -1 when this is the last one. Useful for
// scheduling a repaint exactly on the change instead of polling harder.
function msUntilNext(lines, index, positionMs) {
  if (!lines || index < 0 || index + 1 >= lines.length) return -1
  return Math.max(0, Number(lines[index + 1].time_ms || 0) - (Number(positionMs) || 0))
}

function lineAt(lines, index) {
  if (!lines || index < 0 || index >= lines.length) return null
  return lines[index]
}
