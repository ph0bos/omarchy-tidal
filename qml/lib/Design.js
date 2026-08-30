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

// How long the arriving half of a transition waits for the leaving half.
//
// When a sleeve shrinks aside and a lyric sheet takes its place, moving both at
// once reads as the whole panel wobbling. Letting the object move first and the
// content follow makes it read as one thing making room for another. Short
// enough that it feels like sequence rather than delay.
var stagger = 110

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

// ---- contrast ---------------------------------------------------------------
//
// The interface draws over album art, and album art is not under our control:
// a white sleeve lifts a blurred backdrop until muted text vanishes into it.
// These are the WCAG definitions, so "is this readable" can be a measurement
// rather than an opinion. Channels are 0..1, which is what QML colours use.

function _channel(value) {
  return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
}

// Relative luminance of a QML colour, 0 (black) to 1 (white).
function luminance(color) {
  if (!color) return 0
  return 0.2126 * _channel(color.r) + 0.7152 * _channel(color.g) + 0.0722 * _channel(color.b)
}

// Contrast between two QML colours: 1 (identical) to 21 (black on white).
// WCAG asks 4.5 for body text and 3 for large text or a meaningful graphic.
function contrast(first, second) {
  var a = luminance(first)
  var b = luminance(second)
  return ((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05))
}

// HSL to RGB, so a colour can be lightened without leaving its hue behind.
// Written out rather than reached for through Qt, so the search below stays a
// pure function and can be tested.
function hslToRgb(hue, saturation, lightness) {
  var c = (1 - Math.abs(2 * lightness - 1)) * saturation
  var x = c * (1 - Math.abs(((hue * 6) % 2) - 1))
  var m = lightness - c / 2
  var i = Math.floor(hue * 6) % 6
  var table = [[c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x]]
  var t = table[i < 0 ? i + 6 : i]
  return { r: t[0] + m, g: t[1] + m, b: t[2] + m }
}

// The lightness at which a hue first reads against a background, or -1 when no
// lightness does.
//
// A colour taken from artwork often lands close to the surface it is drawn on:
// GUNSHIP's Dark All Day gives #9e4061, which measures 2.73:1 against a dark
// panel where a control needs 3. Falling back to the theme's accent throws the
// record away for the sake of a few percent of luminance; lifting the same hue
// until it passes keeps the sleeve's identity and the legibility both.
function contrastLightness(hue, saturation, lightness, background, minimum) {
  var target = minimum || 3
  var toward = luminance(background) < 0.5 ? 1 : -1
  var step = 0.04
  var value = lightness
  for (var i = 0; i <= 24; i++) {
    if (contrast(hslToRgb(hue, saturation, value), background) >= target) return value
    value += toward * step
    if (value > 0.97 || value < 0.05) break
  }
  return -1
}

// A colour taken from artwork is only worth using if it can be seen against
// what it is drawn on. `minimum` defaults to 3, the threshold WCAG asks of a
// user interface component.
function readableOr(candidate, background, fallback, minimum) {
  if (!candidate) return fallback
  return contrast(candidate, background) >= (minimum || 3) ? candidate : fallback
}

// "2025-08-22 00:00:00" -> "22 August 2025".
//
// TIDAL sends a release date as a Python datetime that has been stringified,
// so the time half is always midnight and always noise. A year on its own is
// what a listing needs; a full date is what an album page can afford, and it
// is the one piece of metadata that says whether a record is new.
var MONTHS = ["January", "February", "March", "April", "May", "June",
              "July", "August", "September", "October", "November", "December"]

function releaseDate(value) {
  if (!value) return ""
  var match = String(value).match(/^(\d{4})-(\d{2})-(\d{2})/)
  if (!match) return ""
  var month = parseInt(match[2], 10)
  if (month < 1 || month > 12) return ""
  var day = parseInt(match[3], 10)
  if (day < 1 || day > 31) return ""
  return day + " " + MONTHS[month - 1] + " " + match[1]
}
