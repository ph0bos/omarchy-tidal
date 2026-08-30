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

**qmllint cannot see a missing JS import.** A file that says `Design.clock(...)`
without `import "../lib/Design.js" as Design` lints clean and then throws
`ReferenceError: Design is not defined` at runtime -- on whichever code path
touches it, which may be a view nobody opens during a smoke test. It has bitten
twice. `scripts/check-js-imports.py` enforces it in CI.

**Guard every async callback with `root.alive`.** `scripts/check-async-guards.py`
enforces it in CI: a function literal handed to `Rpc.*` or `Tidal.*` may not
mention `root.` before it has mentioned `alive`. Mark a genuine exception with an
`async-guard: ok` comment rather than working around the check. Saving a file hot-reloads
plugin code and destroys live objects. A callback or timer that then writes a
property is a use-after-free, and Quickshell turns that into a fatal abort that
takes the entire shell down.

**Inside `onFooChanged`, derive from the argument, not from a binding.** Change
handlers run *before* dependent bindings re-evaluate, so a `readonly property`
computed from `foo` still describes the previous value. This produced a
"Not an artist or album: tidal:artist:16992" bug.

**A `keepLoaded` window can outlive the monitor it was created on.** The
overlay stays loaded between summons, so a display change leaves it holding a
screen that no longer exists: Quickshell logs "Layershell screen does not
correspond to a real screen" and the surface never maps again, while the bar --
recreated per output -- comes back fine. The symptom is a summon that returns
`ok` and shows nothing. `Overlay.pickScreen()` re-picks the focused screen on
every open, which also means the player opens where you are looking.

**A plugin gets exactly one panel-kind entry point.** `shell.qml`'s
`computePanelEntries()` picks `panel` over `overlay` over `menu` and loads only
that one. Player, now playing and setup are therefore views inside a single
`Overlay.qml`, switched by the summon payload.

**Every `Text` must set `textFormat: Text.PlainText`.** QML's default is
`Text.AutoText`, which sniffs the string and promotes anything that looks like
markup to rich text -- and most of what this shows is catalogue data from TIDAL
that the user did not author. Rich text can reference remote resources, so a
track named with an `<img>` tag would make the shell fetch it.
`scripts/check-textformat.py` enforces this and runs in CI. The same reasoning
covers anything leaving for another surface: `Service.osd()` strips angle
brackets, and "Open in TIDAL" checks the scheme and host before handing a url to
the desktop opener.

**Align text to its capitals, not to its line box.** A picture's top is a hard
edge; a Text's top carries the ascent above the capitals, so anchoring the two
leaves the words a few pixels low and two columns read as almost-but-not-quite
level. `FontMetrics.ascent - FontMetrics.capitalHeight` is the gap, and it is
measured rather than nudged -- see the now-playing eyebrow and the wordmark in
the overlay header.

**Text over album art needs measuring, not guessing.** The companion's
`/palette` reports a cover's luminance and dominant colour (GdkPixbuf, which
PyGObject already brings; there is no Pillow here). The now-playing wash and
the dimming of secondary text scale with that luminance, because a white sleeve
put the artist line at 1.15:1 where 4.5:1 is the floor. A colour taken from
artwork is lifted in lightness until it clears 3:1 rather than being swapped for
the theme accent -- `Design.contrastLightness()` -- and a greyscale cover
reports no colour at all, which is the honest answer.

**Two hover areas over the same pixels means only the top one hears anything.**
`TiltFrame` takes `active`/`pointerX`/`pointerY` from its caller rather than
listening itself, because every surface that wants a tilt already has a
MouseArea for its click, and a second one underneath would simply never fire.

**The plugin's own settings live in `~/.config/omarchy-tidal/settings.json`**,
read through a `FileView` in the service. Not the bar widget's schema: a
notification preference is not a bar concern, and that entry disappears if
someone removes the widget.

**Nothing is hardcoded black or white.** Omarchy ships light themes, so even
the washes over album art derive from `Color.menu.background` and
`Color.menu.text`. A literal `#000000` scrim is a bug on half the themes.

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
python3 -m pytest tests -q          # 39
node --test tests/js.test.mjs       # 44
python3 scripts/validate-manifest.py .
python3 scripts/check-textformat.py .
python3 scripts/check-async-guards.py .
python3 scripts/check-js-imports.py .   # qmllint cannot see a missing JS import
omarchy plugin validate .           # on an Omarchy host
omarchy-tidal-setup check           # dependencies, config, service, session
omarchy-shell tidal status          # live state as JSON
```

The marketplace's submission rules run in CI at a pinned commit
(`scripts/marketplace-baseline.json`), because finding out at submission time is
a slow loop and every fix moves the sha a maintainer would have to re-approve.
Findings fail the build; capabilities do not -- installing packages and managing
a user service is what the setup script is for, and the marketplace asks a human
to accept that. A weekly job says when the pin has fallen behind and whether the
newer rules would change the answer. Moving the pin is deliberate.

QML lint (expect `QObject` / `Unqualified access` warnings — Omarchy's own
widgets produce hundreds):

```bash
mkdir -p /tmp/qsimports && ln -sfn /usr/share/omarchy/shell /tmp/qsimports/qs
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I /tmp/qsimports qml/**/*.qml
```

## Memory, measured

`scripts/measure-memory.sh`. It restarts the shell, samples RSS at three points
and prints them. Find the pid with `qs list --all`, not by matching the command
line -- that also matches the shell running the measurement, which reports a
very reassuring 5 MB.

**Close the panel with `omarchy-shell shell toggle`, not another summon.**
Summoning an already-open panel is a no-op, so the first version of the script
measured an open panel it believed was closed, and reported the plugin holding
50 MB it had in fact already given back. The numbers below are the corrected
ones; the older `~615 MB at rest` figure was that mistake.

Medians of three runs, on one 5120x2160 output:

```
omarchy shell, plugin loaded, overlay never opened   ~530 MB
  ... every surface visited (home, the album grid, now playing, the record)
                                                          ~642 MB
  ... at rest, 45s after the panel actually closes         ~590 MB
mopidy + companion extension                          ~169 MB
```

So the interface costs about 110 MB at peak and 60 MB at rest, against a shell
that is already 530 MB before it opens. Closing the panel returns most of it on
its own -- the compositor drops the hidden surface's resources -- which is the
single largest effect and needs no code.

**Run-to-run variance on identical code is ~8 MB**, which is the floor for
believing any change: a 2 MB "improvement" is noise, and two of those cost an
hour to chase.

### Two things that did not work

Artwork is decoded at the size it is drawn (`RoundedImage.decodeSize`) rather
than at the size of the file -- a 34px row thumbnail retaining a 320x320 pixmap
is wrong on principle and wasteful of decode time. It did not move RSS: Qt's
pixmap cache was already evicting under its own cap. Keep the property, do not
expect the next such change to show up either.

**Releasing the views after an idle period does not either.** `keepLoaded`
holds this window for the life of the shell, so a player opened at nine in the
morning is still built at six in the evening; unloading both Loaders five
minutes after the panel closes looks like the obvious win. Measured over three
runs each it is worth 2 MB -- 588 against 590 -- because the ~50 MB that
closing returns has already been returned by then, and what is left is heap
glibc does not hand back. It was tried, measured, and taken out again; it cost
the reader their place in the library for nothing. Do not re-add it without a
number.

## Where it stands

Working and verified against a real account: hi-res playback, gapless, seeking,
bar widget with a mini player, a personalised Home page of artwork shelves,
search and browse over the whole TIDAL tree with artwork on every row, artist
and album pages with bios and reviews, a now-playing view with artwork, synced
lyrics and credits, a spectrum analyser, quick menu, in-shell sign-in,
keybindings, CI green. Your own albums, artists, tracks and playlists come from
the companion whole and paged, rather than as browse refs plus a lookup per row.
The queue can be reordered by removal: jump to an entry, take one out, empty it.
Any track can be filed into a playlist, or into a new one, with `P`, and
playlists have pages of their own that you can take tracks back out of.

The visual design pass is done and drove the rest of it: one motion vocabulary,
one artwork tile, one playhead, one grid. Screenshots in `docs/screenshots/` are
current.

0.8 was a fidelity pass against Apple Music and the native TIDAL client:

- The sleeve's hover lighting is drawn with `QtQuick.Shapes`, so the shading has
  a real direction and no banding, and only the one sleeve you are listening to
  leans -- shelf tiles are static.
- Search answers while you type (320ms debounce) and orders artists, then
  albums, then tracks. Every track row carries its running time.
- An album with no editorial review -- four in five of them -- falls back to the
  artist's biography rather than showing an empty page, on both the album page
  and the now-playing info face. The info face also lists the album's tracks.
- Detail pages open at the top rather than at the last page's scroll position.

Next, in the order that makes sense:

1. **A settings surface** for the plugin's own options -- sign in and out,
   which account is signed in, and the widget settings that currently live only
   in the bar's schema.
2. **Not TIDAL Connect.** Checked against tidalapi 0.8.11: it exposes nothing
   for it. The only `device` in the whole package is `deviceType=BROWSER` on
   page requests and the OAuth device-code login. Connect is a device-side
   protocol that TIDAL's own clients speak to targets found on the network, and
   reaching it would mean reverse-engineering that protocol -- a different
   project, and not one this plugin should carry. The nearest thing within
   reach is routing our *audio* elsewhere, which is PipeWire's job and Omarchy's
   audio panel already does it.

My Albums and My Artists open on a wall of covers (`LibraryGrid`), indexing the
same rows and the same selected index as the list they stand in for, so the
sidebar, Tab, paging and every action keep working and only the geometry
differs. Tracks and playlists stay lists.

The memory numbers above are the honest ceiling: at rest the interface is about
60 MB over a shell that is already 530, and the backend is the larger half of
what is left, which only comes down by replacing Mopidy -- its own project.
