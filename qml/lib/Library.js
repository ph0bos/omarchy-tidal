// Normalises Mopidy's models into one flat row shape the UI can render.
//
// Mopidy hands back three different shapes depending on the call:
//   browse()  -> Ref      { uri, name, type }
//   search()  -> Track / Album / Artist, fully populated
//   playlists -> Ref      { uri, name }
//
// Rendering all of those directly would push the branching into the delegates.
// Everything below collapses them into:
//
//   { uri, name, subtitle, type, playable }
//
// `type` is one of: track | album | artist | playlist | directory.
// `playable` marks rows that can go straight to the tracklist; a directory has
// to be browsed first.

function _artistNames(item) {
  var artists = item && item.artists
  if (!artists || !artists.length) return ""
  var names = []
  for (var i = 0; i < artists.length; i++) {
    if (artists[i] && artists[i].name) names.push(artists[i].name)
  }
  return names.join(", ")
}

function _row(uri, name, subtitle, type, artist, album, duration) {
  return {
    uri: String(uri || ""),
    name: String(name || ""),
    subtitle: String(subtitle || ""),
    // Kept apart from `subtitle` so a row can show "artist · album" as two
    // distinct pieces of information rather than one pre-joined string.
    artist: String(artist || ""),
    album: String(album || ""),
    // Seconds, because that is what the rest of the plugin counts in. Mopidy
    // reports a track's length in milliseconds; TIDAL reports it in seconds.
    duration: Number(duration || 0),
    type: String(type || "directory"),
    playable: type === "track" || type === "album" || type === "playlist"
  }
}

// A Ref from browse(): no metadata beyond a name and a type.
function fromRef(ref) {
  if (!ref || !ref.uri) return null
  var type = String(ref.type || "directory")
  // Mopidy calls playlist refs "playlist"; everything else maps straight over.
  return _row(ref.uri, ref.name, "", type)
}

function fromTrack(track) {
  if (!track || !track.uri) return null
  var artist = _artistNames(track)
  var album = track.album && track.album.name ? track.album.name : ""
  var subtitle = artist && album ? (artist + " · " + album) : (artist || album)
  // Mopidy's `length` is milliseconds; every row in this plugin counts in
  // seconds. A queue and a page of search results both have a column of empty
  // space on the right where the running time belongs.
  var seconds = track.length ? Math.round(Number(track.length) / 1000) : 0
  return _row(track.uri, track.name, subtitle, "track", artist, album, seconds)
}

function fromAlbum(album) {
  if (!album || !album.uri) return null
  var artist = _artistNames(album)
  var year = album.date ? String(album.date).substring(0, 4) : ""
  var subtitle = artist && year ? (artist + " · " + year) : (artist || year)
  // The year, not the album's own name, goes where a track row would put its
  // album. A row headed "Unicorn" that reads "GUNSHIP · Unicorn" underneath
  // has said the record twice and the one thing that tells two pressings
  // apart not at all.
  return _row(album.uri, album.name, subtitle, "album", artist, year)
}

function fromArtist(artist) {
  if (!artist || !artist.uri) return null
  return _row(artist.uri, artist.name, "", "artist")
}

// browse() results, in the order Mopidy returned them.
function fromBrowse(refs) {
  var out = []
  for (var i = 0; i < (refs || []).length; i++) {
    var row = fromRef(refs[i])
    if (row) out.push(row)
  }
  return out
}

// search() returns one result object per backend. Flatten into sections so the
// UI can show "TRACKS / ALBUMS / ARTISTS" headers without re-deriving them.
// Section caps are per kind, not one number for all three.
//
// Ordering matters more than it looks. With twelve of each and tracks first,
// every search buried the artist you were plainly looking for under a dozen of
// their songs. Artists and albums are few, so they go first and fit on the
// screen together; tracks are many, so they take the rest of it. Apple Music
// and TIDAL both put people and records above individual songs for the same
// reason.
var SEARCH_LIMITS = { artists: 6, albums: 8, tracks: 12 }

function fromSearch(results, limitPerSection) {
  var caps = limitPerSection
    ? { artists: limitPerSection, albums: limitPerSection, tracks: limitPerSection }
    : SEARCH_LIMITS
  var tracks = [], albums = [], artists = []

  for (var i = 0; i < (results || []).length; i++) {
    var result = results[i]
    if (!result) continue

    var t = result.tracks || []
    for (var a = 0; a < t.length && tracks.length < caps.tracks; a++) {
      var tr = fromTrack(t[a])
      if (tr) tracks.push(tr)
    }

    var al = result.albums || []
    for (var b = 0; b < al.length && albums.length < caps.albums; b++) {
      var ab = fromAlbum(al[b])
      if (ab) albums.push(ab)
    }

    var ar = result.artists || []
    for (var c = 0; c < ar.length && artists.length < caps.artists; c++) {
      var an = fromArtist(ar[c])
      if (an) artists.push(an)
    }
  }

  var sections = []
  if (artists.length) sections.push({ title: "Artists", rows: artists })
  if (albums.length) sections.push({ title: "Albums", rows: albums })
  if (tracks.length) sections.push({ title: "Tracks", rows: tracks })
  return sections
}

// Flatten sections into a single list with header markers, so one ListView can
// render both without nesting.
function flatten(sections) {
  var out = []
  for (var i = 0; i < (sections || []).length; i++) {
    var section = sections[i]
    if (!section.rows || !section.rows.length) continue
    out.push({ header: true, name: section.title, uri: "", subtitle: "",
               type: "header", playable: false })
    for (var j = 0; j < section.rows.length; j++) {
      var row = section.rows[j]
      row.header = false
      out.push(row)
    }
  }
  return out
}

// browse() returns Refs with no artist or album. lookup() fills them in; this
// merges the result back onto the rows in place, preserving order.
function mergeLookup(rows, lookupResult) {
  if (!lookupResult) return rows
  for (var i = 0; i < rows.length; i++) {
    var found = lookupResult[rows[i].uri]
    if (!found || !found.length) continue
    var full = fromTrack(found[0])
    if (!full) continue
    rows[i].artist = full.artist
    rows[i].album = full.album
    rows[i].subtitle = full.subtitle
  }
  return rows
}

// The uris of every track row, for a batched lookup.
function trackUris(rows) {
  var out = []
  for (var i = 0; i < (rows || []).length; i++) {
    if (rows[i].type === "track" && rows[i].uri) out.push(rows[i].uri)
  }
  return out
}

// mopidy-tidal emits two URI shapes for the same track:
//   tidal:track:<id>
//   tidal:track:<artist_id>:<album_id>:<id>
// browse() returns the long form and search()/lookup() the short one, so a
// string compare would fail to mark the playing row. The id is last in both.
function trackKey(uri) {
  if (!uri) return ""
  var parts = String(uri).split(":")
  return parts.length ? parts[parts.length - 1] : ""
}

function sameTrack(a, b) {
  if (!a || !b) return false
  var ka = trackKey(a)
  return ka !== "" && ka === trackKey(b)
}

function withoutHeaders(rows) {
  var out = []
  for (var i = 0; i < (rows || []).length; i++) {
    if (!rows[i].header) out.push(rows[i])
  }
  return out
}

// A row built from the companion's own item shape (/home, /library, /album).
// These arrive complete -- artwork, artist, year -- so nothing downstream needs
// to go and ask what they are.
function fromEntry(item) {
  if (!item || !item.uri) return null
  var type = String(item.type || "directory")
  var artist = String(item.artist || "")
  // A record's year goes where a track's album goes: it is the other thing you
  // need to tell two pressings apart, and the row has one slot for it.
  var second = type === "album" && item.year ? String(item.year)
                                             : String(item.album || "")
  var row = _row(item.uri, item.name, artist, type, artist, second)
  row.image = String(item.image || "")
  row.duration = Number(item.duration) || 0
  row.hires = item.hires === true
  // Nothing left to look up.
  row.complete = true
  row.header = false
  return row
}

function fromEntries(items) {
  var out = []
  for (var i = 0; i < (items || []).length; i++) {
    var row = fromEntry(items[i])
    if (row) out.push(row)
  }
  return out
}

// Move one item within a list, the way both backends do it.
//
// Mopidy's core.tracklist.move and Tidal's playlist move_by_id agree on this,
// and both were checked against a live list rather than assumed: the item is
// lifted out and re-inserted at `to` in the list that is left. The distinction
// matters when moving downwards, where "position in the original list" and
// "position in the remaining list" differ by one.
function reindex(items, from, to) {
  var out = (items || []).slice()
  if (from < 0 || from >= out.length) return out
  var target = Math.max(0, Math.min(out.length - 1, to))
  out.splice(target, 0, out.splice(from, 1)[0])
  return out
}

// Where a drag has landed: the row index under a pointer that started on `from`
// and has travelled `dy` pixels down a list of rows `rowHeight` tall.
function dropIndex(from, dy, rowHeight, count) {
  if (!rowHeight || count <= 0) return from
  var moved = Math.round(dy / rowHeight)
  return Math.max(0, Math.min(count - 1, from + moved))
}

// Which of someone's favourites a sidebar target is, if it is one at all.
//
// These four are the same lists Tidal returns as objects, with artwork and
// metadata attached. Browsing them through Mopidy gets bare refs and then a
// lookup per row, so the companion answers for them instead -- and the rest of
// the tree (mixes, For You, Hi-Res) still goes through browse().
function librarySection(uri) {
  switch (String(uri || "")) {
    case "tidal:my_albums":    return "albums"
    case "tidal:my_artists":   return "artists"
    case "tidal:my_tracks":    return "tracks"
    case "tidal:my_playlists": return "playlists"
    default:                   return ""
  }
}

// The sidebar. Mopidy exposes the whole Tidal tree through browse(), so these
// are just browse targets -- no special-casing anywhere in the UI. Search is
// not among them: it has its own field in the page header, and a nav row that
// only moved focus into that field was a second door onto the same room.
//
// "For You" is not among them. It is not a different page: measured against a
// real account, `for_you` and `home` return twenty rows each of which
// seventeen are identical -- same titles, same items, same order -- and the
// remaining three differ only in which record a "Because you listened to"
// shelf was seeded from. Browsing it gave four folders with no artwork, which
// is what the Home page was rebuilt to stop doing. One door onto one room.
//
// "Hi-Res" is not among them either. It was TIDAL's own `tidal:hires` browse
// target, and a row whose name has to be explained is a row that has not
// earned its place: everything in this plugin is hi-res when the account and
// the record allow it, the quality badge says so on every track, and the
// listener has no separate library of hi-res things to visit.
function navigation() {
  return [
    { label: "Home",        uri: "tidal:home",        icon: "home" },
    { label: "My Tracks",   uri: "tidal:my_tracks",   icon: "track" },
    { label: "My Albums",   uri: "tidal:my_albums",   icon: "album" },
    { label: "My Artists",  uri: "tidal:my_artists",  icon: "artist" },
    { label: "My Playlists", uri: "tidal:my_playlists", icon: "playlist" },
    { label: "Mixes",       uri: "tidal:mixes",       icon: "mix" },
    { label: "Queue",       uri: "queue",             icon: "queue" }
  ]
}

// Nerd Font glyphs, matched to the icon keys above.
function glyph(icon) {
  switch (icon) {
    case "search":   return "\uf002"
    case "home":     return "\uf015"
    case "star":     return "\uf005"
    case "hires":    return "\uf001"
    case "track":    return "\uf001"
    case "album":    return "\uf51f"
    case "artist":   return "\uf007"
    case "playlist": return "\uf03a"
    case "mix":      return "\uf074"
    case "queue":    return "\uf03a"
    default:         return "\uf001"
  }
}

function typeGlyph(type) {
  switch (type) {
    case "track":     return "\uf001"
    case "album":     return "\uf51f"
    case "artist":    return "\uf007"
    case "playlist":  return "\uf03a"
    case "directory": return "\uf07b"
    default:          return "\uf001"
  }
}
