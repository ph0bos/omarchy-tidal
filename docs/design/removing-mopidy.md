# Removing Mopidy

Status: proposed. Nothing below is built yet.

The plugin runs on a stack of three AUR packages -- `mopidy4`,
`python-mopidy-tidal-git`, `mopidy-mpris` -- and 407 lines of this repository
exist only to patch bugs in two of them. This document is the case for owning
the backend outright, what that costs, and the order to do it in.

## The inventory that started this

Counting every call site, the plugin uses twenty-two Mopidy core methods:

```
core.playback.*    play pause next previous stop seek get_state
core.tracklist.*   clear add get_tl_tracks remove move
                   set/get_ consume random repeat single
core.library.*     search browse lookup
core.get_version   (reachability ping)
```

Three more are defined in `qml/lib/MopidyRpc.js` and called from nowhere:
`core.mixer.get_volume`, `core.mixer.set_volume`, `core.library.get_images`.
The mixer wrappers are dead code. `get_images` was replaced by the companion's
`/art` when it turned out Mopidy cannot answer for a browse ref at all.

The companion extension is 1,130 lines of `http.py` and touches Mopidy in
exactly one place -- `http.py:544` -- where it asks for the current track and
then uses only its URI, throwing the rest away to call
`session.track(int(tid))` instead.

Then there is `bin/omarchy-tidal-auth`. It runs the TIDAL PKCE flow against
`tidalapi` itself and writes the session file. It writes it to *mopidy-tidal's*
path, so that extension will pick it up -- which means we are not borrowing
mopidy-tidal's authentication. We are performing the authentication and
donating the result.

So the honest ledger of what Mopidy contributes:

| Already ours | Mopidy's |
|---|---|
| Sign-in (PKCE, session file, refresh) | The GStreamer pipeline |
| Catalogue -- artist, album, playlist, home, favourites | MPRIS registration |
| Artwork resolution, disk cache, palette | The queue model |
| Lyrics | `library.browse` |
| Stream resolution (`gapless.py` already calls `get_stream()`) | `library.search` |

Five things. And of the two library calls, `browse` is down to serving
`tidal:mixes` plus two fallback paths: `Library.librarySection()` already routes
My Tracks, My Albums, My Artists and My Playlists to the companion, and the
Home shelf page owns `tidal:home`.

We are paying for a pluggable media server and using none of the pluggability.
The generated `mopidy.conf` sets `[file] enabled = false`, `[m3u] enabled =
false` and `[stream] enabled = false`, and never enables MPD. It is already a
single-backend TIDAL player.

## What it costs today

**Three AUR packages, and the trap around them.** `aur/mopidy4` declares
`conflicts=(mopidy)`, and `yay --noconfirm` answers no to "Remove mopidy?", so
the transaction aborts -- `bin/omarchy-tidal-setup` carries a `MOPIDY_PROVIDER`
variable and a `have_mopidy4()` helper to work around it. `extra/mopidy` is
`4.0.0a2`, a pre-release, and `mopidy-mpris` requires `mopidy>=4.0.0`, which the
alpha does not satisfy; on it, MPRIS never registers and the bar widget, the
media keys and the OSD all go quiet with no error anyone will find.
`python-setuptools-scm` is in the dependency list for one reason: the AUR
`mopidy-mpris` PKGBUILD omits it from `makedepends` and its wheel build fails
without it.

**407 lines of pure workaround.** `gapless.py` (103) rebinds
`mopidy_tidal.playback.as_stream` because mopidy-tidal writes every DASH
manifest to one shared filename. `playlist_lookup.py` (136) repairs
`core.library.lookup()` because two of mopidy-tidal's caches resolve to the same
directory and playlists come back as rows of `Track(uri="tidal:track:0:0:0")`.
`tests/test_playlist_lookup.py` (168) tests the repair. None of this is our
feature work. All of it is a fork we did not want to maintain, performed by
monkeypatch at runtime.

**Round trips.** `browse()` returns bare refs, so `PlayerView.enrich()` fires a
second `lookup()` for artist and album, and artwork needs a third call to
`/art`. Three round trips to draw one list.

**Untested code.** `http.py` is the largest file in the backend and has no test
file, because importing it needs Mopidy installed. `tests/_backend.py:3` says so
outright: mopidy "is not something to install on a CI runner just to test string
parsing". CI installs `ruff pytest requests tidalapi` and nothing else. The
queue behaviour -- tlid semantics, move, consume -- is likewise untestable,
because it lives in a process we do not own.

**A wheel build for a plugin directory.** `cmd_backend` requires `python-build`
and `python-installer`, builds a wheel and installs it into user site-packages,
purely so Mopidy's extension loader will find it.

## What replaces it

One asyncio daemon, `omarchy-tidald`, running the HTTP surface the plugin
already talks to plus the three things Mopidy was doing.

**Process shape.** Tornado is already a transitive dependency and already serves
`/omarchy-tidal/*`; it keeps doing that. GStreamer arrives through PyGObject,
which is also already present -- `palette.py:142` imports `gi` for GdkPixbuf.
A GLib main loop and Tornado's IOLoop coexist; the simplest arrangement is
GLib on the main thread and Tornado's IOLoop bridged to it, with tidalapi's
blocking calls staying on the existing executor exactly as `BaseHandler.run()`
does now.

**Playback.** `playbin3` with `pipewiresink`, which is what Mopidy is configured
to do already (`[audio] output = pipewiresink`). Stream resolution is the code
already in `gapless.py:66-88`:

```python
stream = track.get_stream()
data = stream.get_manifest_data()          # MPEG-DASH for hi-res
# write manifest-<id>.mpd, hand back file://...
```

That is the whole of mopidy-tidal's playback provider. Owning it turns
`gapless.py` from a defensive monkeypatch into fifteen lines of the design.

Gapless comes from `about-to-finish`, the same signal mopidy-tidal is at the
mercy of -- but with one improvement available only to whoever owns the queue:
we know the next track well before the boundary, so its manifest can be resolved
on a prefetch at N seconds remaining rather than inside the callback. Today the
resolve happens on the streaming thread with a network round trip in it. Note
that `about-to-finish` does not fire on the main loop; the next URI must be set
in a thread-safe way.

**Queue.** A list of `(tlid, track)` with a monotonic tlid counter, which is the
semantic the UI already depends on: `PlayerView.loadQueue()` keeps `tlid` on
every row precisely because the same track can sit in the queue twice and a URI
cannot tell the two apart. Plus consume, random, repeat and single. Roughly 150
lines, and -- unlike today -- importable and testable on a CI runner with no
media server present.

**MPRIS.** Implemented directly over `Gio.DBus`, which PyGObject already
provides, rather than pulling in `dbus-next` or `pydbus`. The surface the UI
actually consumes is small and fully enumerable:

```
Properties   PlaybackStatus, Metadata, Position, CanGoNext, CanGoPrevious,
             CanPlay, CanPause, CanSeek, Identity
Metadata     xesam:title, xesam:artist, xesam:album, xesam:url,
             mpris:artUrl, mpris:length, mpris:trackid
Methods      PlayPause, Next, Previous, Play, Pause, Stop, Seek, SetPosition
Signals      PropertiesChanged, Seeked
```

`Service.qml:56-58` currently matches the player by looking for `"mopidy"` in
the bus name or identity. That becomes our bus name, which should be chosen once
and then never changed.

**Catalogue.** `/browse` and `/search` join the companion's existing endpoints,
served from `tidalapi` and returning the same entry shape `/library` already
returns -- complete objects, not refs. `Library.fromEntry()` already consumes
that shape.

This is where the round trips go. A row arrives knowing its artist, its album,
its duration and its artwork URL, so `enrich()` and its `lookup()` disappear,
and so does the dual-URI-shape problem: `Library.trackKey()` and
`sameTrack()` exist because mopidy-tidal emits `tidal:track:<id>` from search
and `tidal:track:<artist>:<album>:<id>` from browse. We would emit one form.

`/format` stops being a round trip at all. Today it asks Mopidy for the current
track, extracts the ID, calls `session.track()`, calls `get_stream()` again and
caches the answer against `_FORMAT_CACHE`. When we resolve the stream ourselves
we already hold `bit_depth`, `sample_rate` and `audio_quality` at the moment we
hand the URI to GStreamer. It becomes a property read.

**Auth.** `bin/omarchy-tidal-auth` keeps doing what it does; only
`session_path()` changes, from mopidy-tidal's data directory to ours.
`session.py`'s mtime-watching stays -- token refresh still has to propagate --
but the `_SESSION_FILES` tuple and the comment explaining which of
mopidy-tidal's two auth methods named the file both go away.

## Dependency ledger

```
before   repo   python-tidalapi gst-plugins-bad playerctl python-setuptools-scm
         AUR    mopidy4 python-mopidy-tidal-git mopidy-mpris
         build  python-build python-installer

after    repo   python-tidalapi gst-plugins-bad python-gobject python-tornado
         AUR    (none)
         build  (none -- the daemon runs from the plugin directory)
```

`python-gobject` and `python-tornado` are already installed on every machine
running this today, as transitive dependencies of Mopidy. Naming them
explicitly is bookkeeping, not a new install. `playerctl` is used only by
`omarchy-tidal-setup` for diagnostics (`:184`, `:428`) and can stay or go on its
own merits. `python-setuptools-scm` was only ever there for the `mopidy-mpris`
wheel build.

The AUR set goes to zero, which is the point.

## What gets deleted, what gets written

Deleted:

```
backend/mopidy_omarchy_tidal/gapless.py            103   monkeypatch
backend/mopidy_omarchy_tidal/playlist_lookup.py    136   monkeypatch
tests/test_playlist_lookup.py                      168   tests for a monkeypatch
qml/lib/MopidyRpc.js                               139
qml/views/PlayerView.qml  enrich()                  ~20
qml/lib/Library.js        fromRef, fromBrowse,      ~60
                          mergeLookup, trackUris,
                          trackKey, sameTrack
bin/omarchy-tidal-setup   mopidy.conf, MOPIDY_       ~90
                          PROVIDER, have_mopidy4,
                          the wheel build
```

Written:

```
player.py     playbin3, stream resolution, prefetch, position, seek   ~200
queue.py      tlid model, move/remove/jump, consume/random/repeat     ~150
mpris.py      the surface listed above, over Gio.DBus                 ~250
browse.py     /browse and /search from tidalapi                       ~150
__main__.py   main loop, config, wiring                                ~80
```

Roughly a wash on line count. The difference is that every line of it is ours,
testable, and not a bet on another project's internals staying where they are.

## What we give up

**Other Mopidy clients.** Iris, `mopidy-mpd`, anything speaking Mopidy's
JSON-RPC. The generated config enables none of them, so nothing breaks today,
but it closes a door: someone running this alongside a Mopidy web client would
lose that. Decided: this daemon is TIDAL-only, for this plugin.

**Other sources.** No local files, no radio streams, no other backends -- all
three already `enabled = false`.

**mopidy-tidal's catalogue caching.** We would need our own, and the companion
already has the pattern for it in `images.py` (URL cache plus disk cache).

**Someone else's bug fixes.** When TIDAL changes its API, mopidy-tidal's
maintainers currently absorb some of that. Against which: two of their bugs cost
us 407 lines, one of them corrupted a persistent on-disk cache such that a
single listing of the playlists broke every play-all after it, permanently, and
that shipped as issue #1.

## Risks, in the order they will hurt

**1. MPRIS.** Everything reactive in the plugin reads it -- `Service.qml:49` and
down. Getting `PropertiesChanged` batching, `Position` semantics and the
`Seeked` signal right is fiddly, and the failure mode is a bar widget that goes
subtly stale rather than an error anyone sees. Mitigation: implement it against
the enumerated surface above, and check with `playerctl -p <name> metadata`
and `--follow` before touching the QML at all. The wall-clock anchor in
`Service.qml:71-88` is unaffected -- it exists precisely because MPRIS does not
tick, and it will keep working.

**2. Gapless hi-res.** This is where the project has been bitten before, and
`about-to-finish` on a DASH manifest is the exact bite. Mitigation: prefetch
rather than resolving in the callback, and hold the bar the repo already set --
`scripts/verify-playlist-playback.sh`, zero non-playing samples across a
boundary.

**3. `restore_state = true`.** Mopidy restores the queue across restarts and we
would have to reimplement it. Small, but easy to forget until someone notices
their queue is gone.

**4. Seek during DASH.** CLAUDE.md records that seeking "silently stopped
playback" under the shared-manifest bug. With per-track manifests it works, but
seek behaviour on `dashdemux` deserves its own check rather than an assumption.

**5. The blocking-call boundary.** Mopidy's pykka actors gave a crude thread
discipline for free. Losing it means being deliberate about which tidalapi calls
run on the executor and which GStreamer calls run on the GLib loop.

## The plan

Each stage ships on its own and can be reverted on its own.

**Stage 0 -- Measure.** `scripts/measure-memory.sh` for the backend at rest and
under playback, plus startup-to-first-playable. Per CLAUDE.md, anything under
8 MB is noise and does not count as a result. Without this number the memory
claim in this document is an assumption, and it should be treated as one until
the number exists.

**Stage 1 -- Decouple the companion.** Put a `Player` protocol in front of
`http.py:544`, with a Mopidy-backed implementation. One touchpoint, no
user-visible change -- and `http.py` becomes importable, so 1,130 lines get
tests for the first time.

**Stage 2 -- Take the catalogue path.** Add `/browse`, `/search` and `/mixes` to
the companion, returning complete entries. Switch `PlayerView` off
`Rpc.browse`, `Rpc.search` and `Rpc.lookup`. Delete `enrich()`.

Stages 1 and 2 are worth doing whether or not the rest happens: they buy test
coverage and remove two of the three round trips while Mopidy is still in place.

**Stage 3 -- The player.** `playbin3`, the queue model, prefetched per-track
manifests. Behind a config flag so both paths coexist and a bad night can be
switched back. Verified with the existing playback script.

**Stage 4 -- MPRIS.** `Gio.DBus`. One-line change to the matcher in
`Service.qml`.

**Stage 5 -- Delete.** The monkeypatches, `MopidyRpc.js`, the AUR dependencies,
the `mopidy.conf` generation, the wheel build, and the parts of `SetupWizard`
that exist to explain the `aur/mopidy4` distinction.

## How we will know it worked

- `omarchy-tidal-setup deps` installs from official repositories only.
- `scripts/verify-playlist-playback.sh` -- zero non-playing samples across a
  hi-res boundary.
- `omarchy-tidal-setup verify` still reports 24-bit/192 kHz on a track that
  carries it.
- CI imports and tests the whole backend, `http.py` included.
- Memory measured against the Stage 0 baseline, with the 8 MB noise floor
  respected.
- A list draws in one round trip with artwork on the first paint.

## Open questions

- **Port.** The companion answers on 6680 today because that is Mopidy's. A
  dedicated port avoids colliding with a real Mopidy on the same machine, at the
  cost of touching the `BASE` constant in `qml/lib/TidalApi.js`. Both are single
  constants; the question is only which surprise is worse.
- **Bus name.** Needs choosing once. `org.mpris.MediaPlayer2.omarchy_tidal` is
  the obvious candidate and cannot be changed afterwards without breaking
  anyone's `playerctl` scripts.
- **Catalogue cache.** Reuse `images.py`'s two-tier pattern, or something
  smaller.
