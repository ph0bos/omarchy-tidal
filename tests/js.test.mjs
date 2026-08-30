// The QML .js libraries are plain functions with no QML dependencies, so they
// can be exercised directly. They are loaded into a fresh VM context rather
// than imported, because QML script files are not ES modules.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function load(relative) {
  const context = { console };
  vm.createContext(context);
  vm.runInContext(readFileSync(path.join(root, relative), "utf8"), context);
  return context;
}

const Lrc = load("qml/lib/Lrc.js");
const Library = load("qml/lib/Library.js");
const Design = load("qml/lib/Design.js");

// ---- Lrc.js -----------------------------------------------------------------

const lines = [
  { time_ms: 1000, text: "one" },
  { time_ms: 2000, text: "two" },
  { time_ms: 3000, text: "three" },
];

test("activeIndex is -1 before the first line", () => {
  assert.equal(Lrc.activeIndex(lines, 0), -1);
  assert.equal(Lrc.activeIndex(lines, 999), -1);
});

test("activeIndex selects the line that has started", () => {
  assert.equal(Lrc.activeIndex(lines, 1000), 0);
  assert.equal(Lrc.activeIndex(lines, 1999), 0);
  assert.equal(Lrc.activeIndex(lines, 2000), 1);
});

test("activeIndex holds the last line past the end", () => {
  assert.equal(Lrc.activeIndex(lines, 99999), 2);
});

test("activeIndex handles empty input", () => {
  assert.equal(Lrc.activeIndex([], 500), -1);
  assert.equal(Lrc.activeIndex(null, 500), -1);
});

test("activeIndex agrees with a linear scan across the whole track", () => {
  // Guards the binary search against off-by-one at every boundary.
  for (let t = 0; t <= 4000; t += 50) {
    let expected = -1;
    for (let i = 0; i < lines.length; i++) if (lines[i].time_ms <= t) expected = i;
    assert.equal(Lrc.activeIndex(lines, t), expected, `at ${t}ms`);
  }
});

test("msUntilNext reports the gap, and -1 on the last line", () => {
  assert.equal(Lrc.msUntilNext(lines, 0, 1000), 1000);
  assert.equal(Lrc.msUntilNext(lines, 2, 3000), -1);
});

// ---- Library.js -------------------------------------------------------------

test("sameTrack matches the two uri shapes for one track", () => {
  // browse() returns the long form, search()/lookup() the short one.
  assert.ok(Library.sameTrack("tidal:track:1134:20505823:20505835",
                              "tidal:track:20505835"));
  assert.ok(Library.sameTrack("tidal:track:5", "tidal:track:5"));
});

test("sameTrack rejects different tracks and empty input", () => {
  assert.ok(!Library.sameTrack("tidal:track:1", "tidal:track:2"));
  assert.ok(!Library.sameTrack("", "tidal:track:1"));
  assert.ok(!Library.sameTrack(null, null));
});

test("fromTrack splits artist and album out", () => {
  const row = Library.fromTrack({
    uri: "tidal:track:1", name: "Hunter",
    artists: [{ name: "Björk" }], album: { name: "Homogenic" },
  });
  assert.equal(row.name, "Hunter");
  assert.equal(row.artist, "Björk");
  assert.equal(row.album, "Homogenic");
  assert.equal(row.type, "track");
  assert.ok(row.playable);
});

test("fromTrack joins multiple artists", () => {
  const row = Library.fromTrack({
    uri: "tidal:track:1", name: "x",
    artists: [{ name: "A" }, { name: "B" }],
  });
  assert.equal(row.artist, "A, B");
});

test("fromRef keeps directories unplayable", () => {
  const row = Library.fromRef({ uri: "tidal:home", name: "Home", type: "directory" });
  assert.equal(row.type, "directory");
  assert.ok(!row.playable);
});

test("mergeLookup backfills artist and album onto browse rows", () => {
  const rows = [Library.fromRef({ uri: "tidal:track:9", name: "Bare", type: "track" })];
  assert.equal(rows[0].artist, "");
  Library.mergeLookup(rows, {
    "tidal:track:9": [{ uri: "tidal:track:9", name: "Bare",
                        artists: [{ name: "A" }], album: { name: "B" } }],
  });
  assert.equal(rows[0].artist, "A");
  assert.equal(rows[0].album, "B");
});

test("trackUris only collects track rows", () => {
  const rows = [
    { type: "track", uri: "tidal:track:1" },
    { type: "directory", uri: "tidal:home" },
    { type: "track", uri: "tidal:track:2" },
  ];
  // Array.from re-homes the VM's array into this realm; deepStrictEqual
  // compares prototypes and would otherwise fail on identical contents.
  assert.deepStrictEqual(Array.from(Library.trackUris(rows)),
                         ["tidal:track:1", "tidal:track:2"]);
});

test("flatten inserts headers and marks rows", () => {
  const flat = Library.flatten([{ title: "Tracks", rows: [{ name: "a" }] }]);
  assert.equal(flat[0].header, true);
  assert.equal(flat[0].name, "Tracks");
  assert.equal(flat[1].header, false);
});

test("navigation covers the browse tree and the queue", () => {
  const uris = Library.navigation().map((n) => n.uri);
  assert.ok(uris.includes("tidal:mixes"));
  assert.ok(uris.includes("tidal:my_albums"));
  assert.ok(uris.includes("queue"));
});

// ---- Design.js --------------------------------------------------------------

test("fitCards keeps cards at or above the minimum width", () => {
  for (const width of [200, 340, 480, 700, 900, 1200]) {
    const n = Design.fitCards(width, 12, 148);
    assert.ok(n >= 1, `no cards fit in ${width}`);
    assert.ok(
      Design.cardWidth(width, 12, n) >= Design.cardMin || n === 1,
      `cards too narrow at ${width}`,
    );
  }
});

test("cards and their gutters never exceed the shelf", () => {
  for (const width of [200, 340, 480, 700, 900, 1200]) {
    const n = Design.fitCards(width, 12, 148);
    const used = n * Design.cardWidth(width, 12, n) + (n - 1) * 12;
    assert.ok(used <= width, `overflowed ${width} by ${used - width}`);
  }
});

test("fitCards copes with a shelf that has no width yet", () => {
  assert.equal(Design.fitCards(0, 12, 148), 0);
  assert.equal(Design.fitCards(undefined, 12, 148), 0);
  assert.equal(Design.cardWidth(500, 12, 0), 0);
});

test("clock formats seconds as m:ss", () => {
  assert.equal(Design.clock(0), "0:00");
  assert.equal(Design.clock(9), "0:09");
  assert.equal(Design.clock(64), "1:04");
  assert.equal(Design.clock(3599), "59:59");
  assert.equal(Design.clock(-1), "0:00");
  assert.equal(Design.clock(NaN), "0:00");
});

// ---- Library.js: rows built from the companion's own shape -------------------

test("fromEntry keeps artwork, artist and the year an album row shows", () => {
  const row = Library.fromEntry({
    type: "album",
    uri: "tidal:album:1",
    name: "10,000 Days",
    artist: "TOOL",
    year: 2006,
    image: "https://resources.tidal.com/x.jpg",
    hires: true,
  });
  assert.equal(row.artist, "TOOL");
  assert.equal(row.album, "2006");
  assert.equal(row.image, "https://resources.tidal.com/x.jpg");
  assert.equal(row.hires, true);
  // Nothing left for the row to go and look up.
  assert.equal(row.complete, true);
});

test("fromEntry gives a track its album rather than a year", () => {
  const row = Library.fromEntry({
    type: "track",
    uri: "tidal:track:1",
    name: "Woken Furies",
    artist: "GUNSHIP",
    album: "Dark All Day",
    duration: 307,
  });
  assert.equal(row.album, "Dark All Day");
  assert.equal(row.duration, 307);
});

test("fromEntry rejects an item with no uri", () => {
  assert.equal(Library.fromEntry({ name: "nowhere" }), null);
  assert.equal(Library.fromEntry(null), null);
  // Length, not deepEqual: the VM context's Array is from another realm.
  assert.equal(Library.fromEntries(null).length, 0);
});

test("librarySection maps only the four favourites lists", () => {
  assert.equal(Library.librarySection("tidal:my_albums"), "albums");
  assert.equal(Library.librarySection("tidal:my_artists"), "artists");
  assert.equal(Library.librarySection("tidal:my_tracks"), "tracks");
  assert.equal(Library.librarySection("tidal:my_playlists"), "playlists");
  assert.equal(Library.librarySection("tidal:mixes"), "");
  assert.equal(Library.librarySection("tidal:home"), "");
  assert.equal(Library.librarySection(""), "");
});

// ---- Lrc.js: instrumental gaps ----------------------------------------------

const sung = [
  { time_ms: 0, text: "one" },
  { time_ms: 2000, text: "two" },
  { time_ms: 20000, text: "after the solo" },
];

test("withGaps marks a long instrumental and leaves short ones alone", () => {
  const marked = Lrc.withGaps(sung, 5000);
  assert.equal(marked.length, 4);
  assert.equal(marked[0].text, "one");
  assert.equal(marked[1].text, "two");
  assert.equal(marked[2].gap, true);
  assert.equal(marked[3].text, "after the solo");
});

test("a gap starts after its line has had time to be read", () => {
  const gap = Lrc.withGaps(sung, 5000)[2];
  // 18s of silence: the marker waits 2.5s (the cap) and spans the rest.
  assert.equal(gap.time_ms, 4500);
  assert.equal(gap.duration, 15500);
});

test("gap markers keep activeIndex working on the combined list", () => {
  const marked = Lrc.withGaps(sung, 5000);
  assert.equal(Lrc.activeIndex(marked, 2100), 1);
  assert.equal(Lrc.activeIndex(marked, 9000), 2);
  assert.equal(marked[Lrc.activeIndex(marked, 9000)].gap, true);
  assert.equal(Lrc.activeIndex(marked, 20500), 3);
});

test("gapProgress runs 0 to 1 across the gap and clamps outside it", () => {
  const gap = Lrc.withGaps(sung, 5000)[2];
  assert.equal(Lrc.gapProgress(gap, 4500), 0);
  assert.equal(Lrc.gapProgress(gap, 12250), 0.5);
  assert.equal(Lrc.gapProgress(gap, 20000), 1);
  assert.equal(Lrc.gapProgress(gap, 0), 0);
  assert.equal(Lrc.gapProgress({ text: "not a gap" }, 5000), 0);
});

test("withGaps copes with an empty or single-line sheet", () => {
  assert.equal(Lrc.withGaps([], 5000).length, 0);
  assert.equal(Lrc.withGaps(null, 5000).length, 0);
  assert.equal(Lrc.withGaps([{ time_ms: 0, text: "only" }], 5000).length, 1);
});

test("withGaps marks the intro when the first line is late", () => {
  const late = [{ time_ms: 30000, text: "first words" }];
  const marked = Lrc.withGaps(late, 10000);
  assert.equal(marked.length, 2);
  assert.equal(marked[0].gap, true);
  assert.equal(marked[0].time_ms, 0);
  assert.equal(marked[0].duration, 30000);
  // And the playhead sitting in the intro finds it.
  assert.equal(Lrc.activeIndex(marked, 5000), 0);
});

test("withGaps leaves a prompt first line alone", () => {
  const prompt = [{ time_ms: 1200, text: "straight in" }];
  assert.equal(Lrc.withGaps(prompt, 10000).length, 1);
});

// ---- Design.js: contrast ----------------------------------------------------

const rgb = (r, g, b) => ({ r, g, b });

test("luminance and contrast follow the WCAG definitions", () => {
  assert.equal(Design.luminance(rgb(0, 0, 0)), 0);
  assert.equal(Design.luminance(rgb(1, 1, 1)), 1);
  assert.equal(Design.contrast(rgb(1, 1, 1), rgb(0, 0, 0)), 21);
  assert.equal(Design.contrast(rgb(0.5, 0.5, 0.5), rgb(0.5, 0.5, 0.5)), 1);
});

test("contrast is symmetric", () => {
  const a = rgb(0.1, 0.1, 0.15);
  const b = rgb(0.66, 0.69, 0.84);
  assert.equal(Design.contrast(a, b).toFixed(4), Design.contrast(b, a).toFixed(4));
});

test("readableOr keeps an artwork colour only when it can be seen", () => {
  const dark = rgb(0.1, 0.11, 0.15);       // a dark theme's background
  const theme = rgb(0.48, 0.64, 0.97);     // the theme accent, the fallback
  const bright = rgb(0.9, 0.5, 0.2);       // an orange sleeve: fine on dark
  const muddy = rgb(0.13, 0.14, 0.17);     // nearly the background itself

  assert.equal(Design.readableOr(bright, dark, theme), bright);
  assert.equal(Design.readableOr(muddy, dark, theme), theme);
  // Nothing extracted at all falls back too.
  assert.equal(Design.readableOr(null, dark, theme), theme);
});

test("hslToRgb round-trips the primaries", () => {
  const near = (a, b) => Math.abs(a - b) < 0.001;
  const red = Design.hslToRgb(0, 1, 0.5);
  assert.ok(near(red.r, 1) && near(red.g, 0) && near(red.b, 0));
  const grey = Design.hslToRgb(0.5, 0, 0.5);
  assert.ok(near(grey.r, 0.5) && near(grey.g, 0.5) && near(grey.b, 0.5));
});

test("contrastLightness lifts a hue until it reads, keeping the hue", () => {
  const panel = { r: 0.102, g: 0.106, b: 0.149 };   // a dark theme panel
  // GUNSHIP's Dark All Day: #9e4061, which fails at 3:1 as extracted.
  const hue = 0.936, saturation = 0.42, lightness = 0.435;
  assert.ok(Design.contrast(Design.hslToRgb(hue, saturation, lightness), panel) < 3);

  const lifted = Design.contrastLightness(hue, saturation, lightness, panel, 3);
  assert.ok(lifted > lightness, "should have been lightened");
  assert.ok(Design.contrast(Design.hslToRgb(hue, saturation, lifted), panel) >= 3);
});

test("contrastLightness darkens instead on a light background", () => {
  const paper = { r: 0.94, g: 0.94, b: 0.95 };
  const lifted = Design.contrastLightness(0.6, 0.5, 0.85, paper, 3);
  assert.ok(lifted < 0.85);
});

test("contrastLightness gives up rather than returning something unreadable", () => {
  // Nothing contrasts 21:1 with mid-grey.
  assert.equal(Design.contrastLightness(0.3, 0.5, 0.5, { r: 0.5, g: 0.5, b: 0.5 }, 21), -1);
});

// ---- Library.js: reordering -------------------------------------------------

test("reindex lifts an item out and re-inserts it, downwards", () => {
  // Checked against both backends: index 0 to position 3 lands third.
  const list = ["a", "b", "c", "d", "e"];
  assert.deepEqual(Library.reindex(list, 0, 3).join(""), "bcdae");
});

test("reindex moves upwards too, and leaves the source alone", () => {
  const list = ["a", "b", "c", "d"];
  assert.equal(Library.reindex(list, 3, 1).join(""), "adbc");
  assert.equal(list.join(""), "abcd");
});

test("reindex clamps a target past either end", () => {
  assert.equal(Library.reindex(["a", "b", "c"], 0, 99).join(""), "bca");
  assert.equal(Library.reindex(["a", "b", "c"], 2, -5).join(""), "cab");
});

test("reindex ignores a source that is not in the list", () => {
  assert.equal(Library.reindex(["a", "b"], 7, 0).join(""), "ab");
});

test("dropIndex turns a drag distance into the row it landed on", () => {
  // Two rows down from row 1, at 44px a row.
  assert.equal(Library.dropIndex(1, 88, 44, 6), 3);
  // Half a row does not count as a move.
  assert.equal(Library.dropIndex(1, 20, 44, 6), 1);
  // Upwards.
  assert.equal(Library.dropIndex(4, -90, 44, 6), 2);
  // Never past the ends.
  assert.equal(Library.dropIndex(0, -400, 44, 6), 0);
  assert.equal(Library.dropIndex(5, 400, 44, 6), 5);
  // A list that has not been laid out yet cannot be dropped into.
  assert.equal(Library.dropIndex(2, 100, 0, 6), 2);
});

test("releaseDate reads the date half and drops the time", () => {
  assert.equal(Design.releaseDate("2025-08-22 00:00:00"), "22 August 2025");
  assert.equal(Design.releaseDate("1997-10-28"), "28 October 1997");
});

test("releaseDate returns nothing it cannot vouch for", () => {
  assert.equal(Design.releaseDate(""), "");
  assert.equal(Design.releaseDate(null), "");
  assert.equal(Design.releaseDate("sometime in 2025"), "");
  assert.equal(Design.releaseDate("2025-13-01"), "");
  assert.equal(Design.releaseDate("2025-00-01"), "");
  assert.equal(Design.releaseDate("2025-08-00"), "");
});

test("search results put people and records above songs", () => {
  const results = [{
    tracks: Array.from({ length: 20 }, (_, i) => ({
      uri: `tidal:track:${i}`, name: `Track ${i}`, length: 1000,
      artists: [{ name: "Deftones" }], album: { name: "White Pony" }
    })),
    albums: Array.from({ length: 20 }, (_, i) => ({
      uri: `tidal:album:${i}`, name: `Album ${i}`, artists: [{ name: "Deftones" }]
    })),
    artists: Array.from({ length: 20 }, (_, i) => ({
      uri: `tidal:artist:${i}`, name: `Artist ${i}`
    })),
  }];
  const sections = Library.fromSearch(results);
  // Joined rather than compared as arrays: these come back from the script's
  // own VM context, where a plain Array has a different prototype and
  // deepEqual refuses them.
  assert.equal(sections.map((s) => s.title).join(","), "Artists,Albums,Tracks");
  // Each kind is capped on its own, so all three fit on one screen.
  assert.equal(sections.map((s) => s.rows.length).join(","), "6,8,12");
});

test("search sections keep an explicit limit for every kind", () => {
  const results = [{
    tracks: [{ uri: "tidal:track:1", name: "T", length: 1000, artists: [{ name: "A" }] }],
    albums: [{ uri: "tidal:album:1", name: "B", artists: [{ name: "A" }] }],
    artists: [{ uri: "tidal:artist:1", name: "A" }],
  }];
  const sections = Library.fromSearch(results, 1);
  assert.equal(sections.map((s) => s.rows.length).join(","), "1,1,1");
});

test("search drops sections that came back empty", () => {
  const sections = Library.fromSearch([{ artists: [], albums: [], tracks: [] }]);
  assert.equal(sections.length, 0);
});

test("an album row says the artist and the year, not its own name twice", () => {
  const row = Library.fromAlbum({
    uri: "tidal:album:1", name: "Unicorn", date: "2019-10-04",
    artists: [{ name: "GUNSHIP" }],
  });
  assert.equal(row.name, "Unicorn");
  assert.equal(row.artist, "GUNSHIP");
  assert.equal(row.album, "2019");
});

test("an album with no date still names its artist", () => {
  const row = Library.fromAlbum({
    uri: "tidal:album:2", name: "Untitled", artists: [{ name: "GUNSHIP" }],
  });
  assert.equal(row.artist, "GUNSHIP");
  assert.equal(row.album, "");
});

test("a track row carries its running time, in seconds", () => {
  const row = Library.fromTrack({
    uri: "tidal:track:1", name: "Passenger", length: 369000,
    artists: [{ name: "Deftones" }], album: { name: "White Pony" },
  });
  assert.equal(row.duration, 369);
  assert.equal(Design.clock(row.duration), "6:09");
});

test("a track with no length reported does not invent one", () => {
  const row = Library.fromTrack({ uri: "tidal:track:2", name: "Untimed" });
  assert.equal(row.duration, 0);
});

test("the sidebar has one door onto the personalised page", () => {
  const uris = Library.navigation().map((n) => n.uri);
  assert.ok(uris.includes("tidal:home"));
  // For You is the same page as Home -- seventeen of twenty rows identical.
  assert.ok(!uris.includes("tidal:for_you"));
  // Hi-Res was a row whose name had to be explained. Everything here is
  // hi-res when the account and the record allow it.
  assert.ok(!uris.includes("tidal:hires"));
  assert.equal(uris[uris.length - 1], "queue");
});

test("a grid's cards leave room for the gutter each cell carries", () => {
  // A shelf puts gutters between the cards: 4 cards and 3 gaps.
  assert.equal(Design.cardWidth(830, 12, 4), 198);
  assert.equal(4 * 198 + 3 * 12, 828);
  // A grid cell is card-plus-gutter, so four of them must fit inside 830.
  const card = Design.gridCardWidth(830, 12, 4);
  assert.equal(card, 195);
  assert.ok(4 * (card + 12) <= 830);
  // The shelf width would not have fitted, which is the bug this exists for.
  assert.ok(4 * (198 + 12) > 830);
});

test("gridCardWidth refuses to return a width nothing can be drawn at", () => {
  assert.equal(Design.gridCardWidth(0, 12, 4), 1);
  assert.equal(Design.gridCardWidth(830, 12, 0), 0);
  assert.equal(Design.gridCardWidth(10, 12, 4), 1);
});
