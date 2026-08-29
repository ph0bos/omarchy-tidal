# Omarchy TIDAL — working notes

Quickshell plugin putting TIDAL inside the Omarchy shell, plus a companion
Mopidy extension. Hi-res lossless is the whole point: 24-bit/192kHz FLAC, and
the output path is verified rather than assumed.

Repo: `ph0bos/omarchy-tidal` · plugin id `quickshell.tidal` · discovered as
**TIDAL** · MIT.

## Shape

```
qml/          the plugin. Service (headless singleton) + BarWidget + Overlay
  views/      PlayerView, DetailView, NowPlayingView
  components/ TrackRow, PlayerBar, Visualizer, QuickMenu, SetupWizard, ...
  lib/        MopidyRpc.js, TidalApi.js, Library.js, Lrc.js — plain JS, tested
backend/      mopidy_omarchy_tidal — companion Mopidy extension (Python)
bin/          omarchy-tidal-setup, omarchy-tidal-auth, omarchy-tidal-cava
tests/        pytest (backend) + node --test (QML JavaScript)
```

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

**MPRIS only signals position on an explicit seek.** The timeline runs off a
wall-clock anchor (`anchorPos` + elapsed), re-anchored every 5s. An
incrementing counter drifts.

**Scrubbing previews locally and commits one seek on release.** A seek per
mouse-move floods Mopidy and stutters the audio.

**Starting/stopping cava re-negotiates the PipeWire graph**, which is audible.
Views stay loaded once visited and the capture is held open for a grace period.

## Checks

```bash
python3 -m pytest tests -q          # 19
node --test tests/js.test.mjs       # 15
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
bar widget, player with search and browse over the whole TIDAL tree, artist and
album pages with bios and reviews, synced lyrics, spectrum analyser, quick
menu, in-shell sign-in, keybindings, CI green.

Next, in the order that makes sense:

1. **Visual design pass.** The brief is "how would Apple designers build this
   for Omarchy" — restraint, typography, density, motion. This should drive
   2 and 3 rather than trail them.
2. **Home page.** Currently a folder list from `browse(tidal:home)`. Should be
   personalised rows with artwork, like the real client. The companion's
   `/home` endpoint already returns 20 rows with images in under a second.
3. **Now playing.** Art centred by default; lyrics and album info revealed on
   click, the way TIDAL native and Roon do it.
4. **Click-through to detail** from every surface.
5. **Screenshots** for the README using Sleep Token, PRESIDENT, Gunship,
   Deftones.

Not started: mini player, playlist editing, sleep timer, TIDAL Connect device
switching, settings UI. Memory is ~130 MB for the Mopidy backend, against
~60 MB for the Spotify plugin's Rust daemon — that gap closes only by replacing
the backend, which is its own project.
