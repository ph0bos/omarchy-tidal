# Omarchy TIDAL — working notes

Quickshell plugin putting TIDAL inside the Omarchy shell, plus a companion
Mopidy extension. Hi-res lossless is the whole point: 24-bit/192kHz FLAC, and
the output path is verified rather than assumed.

Repo: `ph0bos/omarchy-tidal` · plugin id `quickshell.tidal` · discovered as
**TIDAL** · MIT.

## Shape

```
qml/          the plugin. Service (headless singleton) + BarWidget + Overlay
  views/      HomeView, PlayerView, DetailView, NowPlayingView
  components/ ArtCard, Shelf, TrackRow, SeekBar, PlayerBar, MiniPlayer,
              ScrollHint, Visualizer, QuickMenu, SetupWizard, ...
  lib/        MopidyRpc.js, TidalApi.js, Library.js, Lrc.js, Design.js
              — plain JS, no QML imports, tested
backend/      mopidy_omarchy_tidal — companion Mopidy extension (Python)
                http.py (endpoints) · images.py (art + entity resolution,
                URL cache and disk cache) · lyrics.py · session.py · gapless.py
bin/          omarchy-tidal-setup, omarchy-tidal-auth, omarchy-tidal-cava
tests/        pytest (backend) + node --test (QML JavaScript)
```

`Design.js` holds the three motion durations and the artwork grid maths. Use
them rather than literals: a hover, a shelf fading in and a lyric taking focus
only read as one machine if they move at the same speeds.

Playback state arrives over **MPRIS** (push, free). Commands go out over
Mopidy's **HTTP JSON-RPC** via QML's built-in `XMLHttpRequest` — Quickshell
ships no WebSocket module and we do not want the Qt dependency. Anything
Mopidy's core API has no concept of (lyrics, TIDAL home, radio, favourites,
artist/album pages, stream format) lives in the companion extension, which
reuses `mopidy-tidal`'s authenticated session rather than logging in twice.

## Things that will cost you an hour if you don't know them

**The file watcher does not follow symlinks.** Developing through
`~/.config/omarchy/plugins/quickshell.tidal -> this repo` means edits appear to
do nothing: the shell keeps serving the QML it loaded first, and
`rescanPlugins` does not help either. Use `omarchy restart shell`.

**Write Nerd Font glyphs as `\uXXXX` escapes.** Private-use codepoints are
silently stripped when a file is written through a shell heredoc. The symptom
is an invisible icon, not an error. CI checks for this.

**Guard every async callback with `root.alive`.** Saving a file hot-reloads
plugin code and destroys live objects. A callback or timer that then writes a
property is a use-after-free, and Quickshell turns that into a fatal abort that
takes the entire shell down.

**Inside `onFooChanged`, derive from the argument, not from a binding.** Change
handlers run *before* dependent bindings re-evaluate, so a `readonly property`
computed from `foo` still describes the previous value. This produced a
"Not an artist or album: tidal:artist:16992" bug.

**A plugin gets exactly one panel-kind entry point.** `shell.qml`'s
`computePanelEntries()` picks `panel` over `overlay` over `menu` and loads only
that one. Player, now playing and setup are therefore views inside a single
`Overlay.qml`, switched by the summon payload.

**Do not name a property `data` or `enabled`** — they shadow `QQuickItem`
members. `data` is the default property; shadowing it breaks child assignment.

**An elided `Text` reports the width of the *elided* string.** Sizing a clip to
`labelText.implicitWidth` and the text to the clip's width is a shrinking
feedback loop: it settled on a bar label cut to a third of the space it had.
Measure with `TextMetrics`, which depends on nothing downstream.

**A `Behavior` on an `anchors.*` property never runs.** Anchors are a grouped
property. Animate a `Translate` transform instead.

**`repeater.itemAt(i)` in a binding needs `repeater.count` read alongside it.**
It is a function call, so the binding has no other reason to re-evaluate when
the delegates come into existence — the underline under the now-playing tabs sat
at zero width until you switched face.

**Only one thing may hold focus.** The overlay's key catcher used to call
`forceActiveFocus()` on every summon; it is an ancestor of the player view, so
it took the keys and the view's own handler never ran. Focus the view that is
showing; keys it does not accept bubble up to the catcher anyway. Likewise,
never focus a `ListView` to "give the list the keyboard" — its own arrow-key
navigation swallows Up and Down before the parent sees them.

## Backend constraints

**Mopidy must be `aur/mopidy4`, not `extra/mopidy`.** The repo package is
`4.0.0a2`, a pre-release, and `mopidy-mpris` requires `mopidy>=4.0.0`. On the
alpha it fails to import and MPRIS never registers — which silently breaks the
bar widget, the media keys and the OSD.

**Hi-res is MPEG-DASH, and mopidy-tidal writes every manifest to one shared
filename.** `about-to-finish` fires while the current track plays, so resolving
the next one overwrote the manifest the current one was reading: a stall at
every boundary, tracks reporting as "infinite source", and seeking that stopped
playback. `backend/gapless.py` rebinds `as_stream` to write per-track
manifests. Verified: 0 non-playing samples of 77 across a boundary.

**PipeWire defaults to `allowed-rates = [48000]`** and silently resamples every
hi-res stream. `omarchy-tidal-setup audio` fixes it. The *output device* still
has the last word — many displays reject 88.2 kHz over HDMI/DisplayPort.

**Mopidy cannot supply artwork for a browse ref.** `core.library.get_images()`
answers for tracks in the long uri form (`tidal:track:<artist>:<album>:<id>`)
and returns an empty list for the short album and artist refs `browse()` hands
back. The companion's `/art` and `/entity` resolve those against the session,
and cache both the address and the bytes — one API round trip per entity is
unavoidable, since Tidal's image URLs are built from a cover id that only comes
back with the object.

**MPRIS only signals position on an explicit seek.** The timeline runs off a
wall-clock anchor (`anchorPos` + elapsed), re-anchored every 5s. An
incrementing counter drifts.

**Scrubbing previews locally and commits one seek on release.** A seek per
mouse-move floods Mopidy and stutters the audio.

**Starting/stopping cava re-negotiates the PipeWire graph**, which is audible.
Views stay loaded once visited and the capture is held open for a grace period.

## Checks

```bash
python3 -m pytest tests -q          # 33
node --test tests/js.test.mjs       # 19
python3 scripts/validate-manifest.py .
omarchy plugin validate .           # on an Omarchy host
omarchy-tidal-setup check           # dependencies, config, service, session
omarchy-shell tidal status          # live state as JSON
```

QML lint (expect `QObject` / `Unqualified access` warnings — Omarchy's own
widgets produce hundreds):

```bash
mkdir -p /tmp/qsimports && ln -sfn /usr/share/omarchy/shell /tmp/qsimports/qs
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I /tmp/qsimports qml/**/*.qml
```

## Where it stands

Working and verified against a real account: hi-res playback, gapless, seeking,
bar widget with a mini player, a personalised Home page of artwork shelves,
search and browse over the whole TIDAL tree with artwork on every row, artist
and album pages with bios and reviews, a now-playing view with artwork, synced
lyrics and credits, a spectrum analyser, quick menu, in-shell sign-in,
keybindings, CI green. Your own albums, artists, tracks and playlists come from
the companion whole and paged, rather than as browse refs plus a lookup per row.
The queue can be reordered by removal: jump to an entry, take one out, empty it.
Any track can be filed into a playlist, or into a new one, with `P`.

The visual design pass is done and drove the rest of it: one motion vocabulary,
one artwork tile, one playhead, one grid. Screenshots in `docs/screenshots/` are
current.

Next, in the order that makes sense:

1. **Playlist reordering**, and removing a track from a playlist page. Adding
   and creating are done (`/playlists`, `/playlist`); tidalapi has
   `move_by_index` and `remove_by_index` for the rest, and a playlist detail
   page is the surface they belong on -- DetailView only knows artists and
   albums today.
3. **Sleep timer**, and **TIDAL Connect device switching**.
4. **A settings surface** for the plugin's own options, rather than the widget
   schema being the only place to change anything.

Not started: memory is ~130 MB for the Mopidy backend, against ~60 MB for the
Spotify plugin's Rust daemon — that gap closes only by replacing the backend,
which is its own project.
