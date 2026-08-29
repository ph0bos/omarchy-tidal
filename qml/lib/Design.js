// The plugin's motion and density constants.
//
// Durations live here rather than as literals at each call site because the
// surfaces animate together: a card lifting under the cursor, a shelf fading
// in, and a lyric line taking focus all read as one machine only if they move
// at the same speeds. Three steps is the whole vocabulary --
//
//   fast   a state change under the pointer, felt rather than seen
//   base   something appearing or swapping places
//   slow   a whole face of the UI changing
//
// Pure functions and numbers only: no QML imports, so the layout maths below
// is exercised directly by tests/js.test.mjs.

var fast = 130
var base = 190
var slow = 280

// Artwork tiles. `cardIdeal` is the width a card wants; a shelf fits as many
// as it can at or above `cardMin` and then shares the remainder out, so cards
// stay on a common grid instead of every shelf picking its own size.
var cardIdeal = 148
var cardMin = 96

// How many cards fit across `width`, given `gutter` between them.
//
// Rounded rather than floored: at 700px the floor rule leaves a 5th card 20px
// short and drops it, wasting the space on four fat tiles. Rounding takes the
// nearer answer and lets the shared remainder absorb the difference, which is
// what keeps a shelf from visibly changing card size as the panel resizes.
function fitCards(width, gutter, ideal) {
  var w = Number(width)
  if (!isFinite(w) || w <= 0) return 0
  var g = Number(gutter) || 0
  var want = Number(ideal) || cardIdeal
  var n = Math.round((w + g) / (want + g))
  if (n < 1) n = 1
  // Never shrink below cardMin: fewer, legible tiles beat a row of stamps.
  while (n > 1 && cardWidth(w, g, n) < cardMin) n = n - 1
  return n
}

// The width one card gets when `count` of them share `width`.
function cardWidth(width, gutter, count) {
  var n = Number(count) || 0
  if (n <= 0) return 0
  var w = Number(width) || 0
  var g = Number(gutter) || 0
  return Math.floor((w - (n - 1) * g) / n)
}

// Elapsed/total as "1:04", the only time format the UI shows.
function clock(seconds) {
  var total = Number(seconds)
  if (!isFinite(total) || total < 0) return "0:00"
  total = Math.floor(total)
  var m = Math.floor(total / 60)
  var s = total % 60
  return m + ":" + (s < 10 ? "0" + s : s)
}
