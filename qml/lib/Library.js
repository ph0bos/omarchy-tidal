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

function _row(uri, name, subtitle, type, artist, album) {
  return {
    uri: String(uri || ""),
    name: String(name || ""),
    subtitle: String(subtitle || ""),
    // Kept apart from `subtitle` so a row can show "artist · album" as two
    // distinct pieces of information rather than one pre-joined string.
    artist: String(artist || ""),
    album: String(album || ""),
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
  return _row(track.uri, track.name, subtitle, "track", artist, album)
}

function fromAlbum(album) {
  if (!album || !album.uri) return null
  var artist = _artistNames(album)
  var year = album.date ? String(album.date).substring(0, 4) : ""
  var subtitle = artist && year ? (artist + " · " + year) : (artist || year)
  return _row(album.uri, album.name, subtitle, "album", artist, album.name)
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
function fromSearch(results, limitPerSection) {
  var limit = limitPerSection || 12
  var tracks = [], albums = [], artists = []

  for (var i = 0; i < (results || []).length; i++) {
    var result = results[i]
    if (!result) continue

    var t = result.tracks || []
    for (var a = 0; a < t.length && tracks.length < limit; a++) {
      var tr = fromTrack(t[a])
      if (tr) tracks.push(tr)
    }

    var al = result.albums || []
    for (var b = 0; b < al.length && albums.length < limit; b++) {
      var ab = fromAlbum(al[b])
      if (ab) albums.push(ab)
    }

    var ar = result.artists || []
    for (var c = 0; c < ar.length && artists.length < limit; c++) {
      var an = fromArtist(ar[c])
      if (an) artists.push(an)
    }
  }

  var sections = []
  if (tracks.length) sections.push({ title: "Tracks", rows: tracks })
  if (albums.length) sections.push({ title: "Albums", rows: albums })
  if (artists.length) sections.push({ title: "Artists", rows: artists })
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

// The sidebar. Mopidy exposes the whole Tidal tree through browse(), so these
// are just browse targets -- no special-casing anywhere in the UI. Search is
// not among them: it has its own field in the page header, and a nav row that
// only moved focus into that field was a second door onto the same room.
function navigation() {
  return [
    { label: "Home",        uri: "tidal:home",        icon: "home" },
    { label: "For You",     uri: "tidal:for_you",     icon: "star" },
    { label: "Hi-Res",      uri: "tidal:hires",       icon: "hires" },
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
    case "search":   return ""
    case "home":     return ""
    case "star":     return ""
    case "hires":    return ""
    case "track":    return ""
    case "album":    return ""
    case "artist":   return ""
    case "playlist": return ""
    case "mix":      return ""
    case "queue":    return ""
    default:         return ""
  }
}

function typeGlyph(type) {
  switch (type) {
    case "track":     return ""
    case "album":     return ""
    case "artist":    return ""
    case "playlist":  return ""
    case "directory": return ""
    default:          return ""
  }
}
