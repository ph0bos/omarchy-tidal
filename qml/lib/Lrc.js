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

// Insert markers where the song stops singing.
//
// A lyric sheet that holds one line on screen for twenty seconds looks stuck.
// Apple Music and TIDAL both fill an instrumental with a small progress
// indicator instead, which turns dead air into something that is visibly still
// running. This puts a `{gap: true}` entry into the line list wherever the
// silence is long enough to be worth marking, so the view can render it as one
// more delegate rather than as a special case layered over the list.
//
// A gap entry carries the same `time_ms` the view already searches on, plus the
// duration it spans, so `activeIndex` needs no changes: the gap simply becomes
// the current "line" while it lasts.
function withGaps(lines, minGapMs) {
  var threshold = Number(minGapMs) || 10000
  var out = []
  // An intro is a gap like any other: the sheet should show the song running
  // up to the first line rather than sitting inert with nothing marked.
  if (lines && lines.length && Number(lines[0].time_ms || 0) >= threshold) {
    out.push({ gap: true, time_ms: 0, duration: Number(lines[0].time_ms || 0), text: "" })
  }
  for (var i = 0; i < (lines || []).length; i++) {
    var line = lines[i]
    out.push(line)
    if (i + 1 >= lines.length) continue
    // Sung lines have no end time, so the gap is measured from the start of
    // this line to the start of the next. A long one means this line has been
    // hanging on screen alone.
    var start = Number(line.time_ms || 0)
    var next = Number(lines[i + 1].time_ms || 0)
    var span = next - start
    if (span < threshold) continue
    // The marker begins once the line has had its moment, not the instant it
    // appears -- roughly how long a line takes to read.
    var lead = Math.min(2500, span / 3)
    out.push({ gap: true, time_ms: start + lead, duration: span - lead, text: "" })
  }
  return out
}

// How far through a gap the playhead is, 0..1.
function gapProgress(entry, positionMs) {
  if (!entry || !entry.gap) return 0
  var span = Number(entry.duration || 0)
  if (span <= 0) return 0
  var elapsed = (Number(positionMs) || 0) - Number(entry.time_ms || 0)
  return Math.max(0, Math.min(1, elapsed / span))
}
