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
  assert.ok(uris.includes("tidal:hires"));
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
