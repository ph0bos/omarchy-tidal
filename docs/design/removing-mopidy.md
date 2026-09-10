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
that `about-to-finish` fires on a streaming thread and the next URI must be
assigned from that same thread -- see Risks, where this turns the prefetch from
an optimisation into a requirement.

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

`gst-plugins-bad` stays on both sides of that line: it decodes the AAC (`m4a`)
streams the HIGH and LOW tiers serve, which is why mopidy-tidal requires it as
well. It is not there for DASH -- see Risks 3.

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

## Prior art

Someone has built most of this already. `tidalamp` is a Python TIDAL client on
`tidalapi` with no media server under it: device-authorization login with the
session persisted to its own config dir, `HI_RES_LOSSLESS` requested by default,
BTS and MPD manifests handled separately, and
`org.mpris.MediaPlayer2.tidalamp` published on the session bus -- queue included,
as an MPRIS TrackList. It reaches 24-bit/192 kHz and it also ran into PipeWire
resampling and had to detect and fix it, which is the same ground
`omarchy-tidal-setup audio` covers.

It differs in the one place that matters here: it drives **mpv** over a Unix
socket rather than owning a GStreamer pipeline, and it rewrites the DASH
manifest into a local HLS playlist to get it into ffmpeg. We would not copy that
-- `gapless.py` already proves the manifest goes straight into GStreamer -- but
it is a working existence proof that everything except the pipeline is
reachable from `tidalapi` alone.

Two things it reports are worth taking as findings rather than rediscovering:

- **Requesting `LOSSLESS` through the device flow returns `HIGH`.** Only
  `HI_RES_LOSSLESS` yields FLAC where the record has it. Our `mopidy.conf`
  already sets `quality = HI_RES_LOSSLESS`, so we are on the right side of this
  by accident; whatever replaces that config must keep it.
- **Some tracks come back with Widevine-encrypted manifests** and cannot be
  played without a CDM. This is not a risk the move introduces -- `gapless.py`
  calls the same `get_stream()` today -- but we currently have no explicit
  handling for it, and a stall is a worse answer than an error.

## Risks, and how each is addressed

Researched rather than guessed. Where a mitigation rests on someone else's
documented behaviour, the source is named.

### 1. MPRIS -- smaller than it looked

The spec settles the part that worried me. `Position` is **exempt from
`PropertiesChanged`** -- the specification says the signal "is not emitted when
this property changes" -- and so is `CanControl`. A server is expected to
report position once at the start of a track and then stay quiet; the client
runs its own timer. The `Seeked` signal exists for the one case where playback
moves inconsistently with the rate.

That is not a Mopidy quirk we have been working around. It is the design, and
`Service.qml`'s wall-clock anchor is the client half of it, already correct.
Quickshell does the same thing internally -- it interpolates locally between
D-Bus updates rather than polling.

So the surface to implement is: `PlaybackStatus`, `Metadata`, the capability
flags, `Seeked` on explicit seeks, and `Position` readable on demand. Three
concrete gotchas, none of them subtle once known:

- **`mpris:trackid` must be a D-Bus object path**, not a string -- and TIDAL
  URIs contain colons, which are invalid in one. It has to be encoded, and
  `/org/mpris/MediaPlayer2/TrackList/NoTrack` is the reserved value for nothing
  playing. Our tlid maps onto this cleanly, since the spec wants the id unique
  per tracklist entry rather than per track, which is the same reason the queue
  needs tlids at all.
- **Quickshell combines each capability flag with `CanControl`.** Leave
  `CanControl` unset and every `canXyz` in the QML goes false at once, which
  would read as a dead player rather than as a missing property.
- **`SetPosition` takes a TrackId and must ignore stale calls** -- the spec's
  own race guard, and free to honour once trackids are right.

Discovery needs nothing more than a bus name matching `org.mpris.MediaPlayer2*`,
which Quickshell watches for.

Bring-up order: get it answering `playerctl -p <name> metadata` and
`playerctl --follow` before touching a line of QML. If the shell never has to
be part of the debugging loop, it will not be.

### 2. Gapless -- and a correction

An earlier draft of this document said the next URI "must be set in a
thread-safe way", implying it should be marshalled to the main loop. **That is
wrong, and it is the expensive kind of wrong.** `about-to-finish` is emitted on
a GStreamer streaming thread, and the URI must be assigned from *that* thread.
Forwarding the request to the application's main thread via the bus is the
documented failure: the next URI silently does not play and the pipeline wedges.

So prefetching is not the optimisation I described. It is the requirement. The
callback must do nothing but a dictionary lookup and a property assignment; all
of the network work -- `get_stream()`, `get_manifest_data()`, writing
`manifest-<id>.mpd` -- has to have happened already, off that thread, triggered
by the queue at N seconds remaining. Blocking the streaming thread on a TIDAL
round trip is what mopidy-tidal does today.

Nothing else may happen in that callback either: a state change from a
streaming thread can deadlock, and the documented escape -- post a message on
the bus, or `g_idle_add` -- is exactly the thing that does not work for the URI
itself. Set the URI, return.

`playbin3` is the right element: it keeps one `uridecodebin3` and reuses
compatible decoders across URI changes, where `playbin2` had to drop to
`READY`. The `instant-uri` property covers the separate case of switching
tracks on demand rather than at a boundary, which is what "play this now" is.

Verification is unchanged and non-negotiable:
`scripts/verify-playlist-playback.sh`, zero non-playing samples across a hi-res
boundary.

### 3. Seek during DASH -- pin a floor

There are two DASH implementations. The legacy `dashdemux` lives in
`gst-plugins-bad`; `dashdemux2`, part of the `adaptivedemux2` plugin, ships in
**gst-plugins-good** and carries rank `primary + 1`, so autoplugging already
prefers it wherever it is installed. The seeking CLAUDE.md records as broken was
almost certainly the shared-manifest bug rather than the demuxer, but the newer
one is where the fixes are landing.

Two releases matter. **GStreamer 1.26.10 (25 December 2025) added support for
FLAC audio in DASH manifests** -- which is precisely what a TIDAL hi-res stream
is -- and shipped stream-selection fixes for `adaptivedemux2` covering
disabling and re-enabling streams.

So: state a GStreamer floor of 1.26.10, confirm with `gst-inspect-1.0
dashdemux2` which implementation is actually being used, and test seek
explicitly rather than assuming it. Note that `gst-plugins-bad` does **not**
come off the dependency list -- it is what decodes the AAC (`m4a`) streams the
HIGH and LOW tiers serve, which is why mopidy-tidal requires it too.

### 4. Two event loops -- solved upstream

**PyGObject 3.50 added native asyncio integration**, so GLib and asyncio no
longer need bridging by hand or by a third-party library:

```python
from gi.events import GLibEventLoopPolicy
asyncio.set_event_loop_policy(GLibEventLoopPolicy())
```

That is one import from a package we already depend on -- `gbulb` is archived
and `asyncio-glib` is unnecessary. PyGObject marks the API experimental, which
is the reason to pin a floor and to keep the wiring in `__main__.py` where it
can be swapped rather than spread through the daemon.

The thread discipline pykka was giving us for free becomes one explicit rule:
tidalapi calls on the existing executor (which `BaseHandler.run()` already
does), GStreamer state changes on the GLib loop, and the one exception carved
out above -- setting the URI inside `about-to-finish`, on the streaming thread,
from data prepared in advance.

### 5. `restore_state` -- fully specified, and not pristine

Mopidy writes gzipped JSON to `<data_dir>/core/state.json.gz` on stop and reads
it on start, persisting the tracklist (`_tl_tracks`, `_next_tlid`), the four
tracklist options, the play history capped at 500, the current tl_track and its
time position, and the volume. That is the whole contract, and reimplementing
it is an afternoon.

Worth knowing before treating it as a standard to meet: Mopidy's own version has
open bugs -- a missing state file on load, and tracks that fail to play when
restoring. We are not inheriting something that works perfectly.

### 6. Widevine-encrypted manifests -- inherited, not introduced

Carried over from Prior art above: a track whose manifest is Widevine-encrypted
cannot be decoded without a CDM. We already call the same `get_stream()`, so the
exposure exists today; what is missing is an honest failure. Detect the
encryption type at resolve time and surface it as a skipped track with a reason,
rather than handing GStreamer something that will stall at the boundary.

## Security

Owning the daemon is what makes this section possible. Mopidy loads arbitrary
Python extensions by config, so its syscall and filesystem profile is whatever
the installed extensions need; a purpose-built daemon has a knowable one and can
be locked to it.

Read `SECURITY.md` alongside this. Its framing stays true -- plugin QML runs
unsandboxed inside the shell process and nothing here changes that -- but the
*backend* is a separate process under our own unit, and that is a boundary worth
using.

### What the daemon actually eats

Every one of these is attacker-influenced to some degree:

| Input | Parsed by | Note |
|---|---|---|
| TIDAL catalogue JSON | `tidalapi` | Unofficial API; shape can change without notice |
| DASH XML manifests | GStreamer | Fetched per track, written to disk, handed to a demuxer |
| Cover art bytes | **GdkPixbuf** | Image decoding in-process is the sharpest edge here |
| Lyrics | `lyrics.py`, LRCLIB | Third-party service, off by default via `lrclib_fallback` |
| Local HTTP requests | tornado | Any page in the user's browser can reach 127.0.0.1 |

The guards that already exist must survive the move intact, because each was
put there for a reason:

- **Origin rejection** (`http.py:73`). A browser sets `Origin` on cross-origin
  requests and the QML client sets none, so anything carrying one is refused.
  This is what stops a web page driving playback or reading the library. Note
  the shape it depends on: every state-changing endpoint is a POST, so a
  "simple" cross-origin form post still carries `Origin` and still gets refused.
  A state-changing GET added later would quietly step outside that guarantee.
- **The artwork host allowlist** (`http.py:764`). `/art` will fetch only from
  hosts in `_ART_HOSTS`, checked server-side against the parsed hostname -- not
  merely by the client-side prefix test in `TidalApi.artProxy`. This is the
  SSRF guard, and it is correct as written; keep the check on the server.
- **`Text.PlainText` everywhere**, the `Service.osd()` bracket stripping, and
  the scheme-and-host check before handing a URL to the desktop opener.

### Sandboxing the unit

Today's generated `mopidy.service` has no hardening at all -- `Type=simple`,
`ExecStart`, `Restart`, nothing else. A unit we own can start from a real
baseline.

Be clear about the threat model first, because it is easy to overclaim: this is
a **user** unit running as the user, so sandboxing it does not protect the user
from themselves and is not a privilege boundary. What it does is bound the blast
radius if the daemon is compromised through one of the inputs above -- a
malformed sleeve reaching GdkPixbuf, a hostile response from an API we do not
control. That is worth having, and it is honest about what it is.

A starting point, to be measured rather than trusted:

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only          # plus ReadWritePaths for our own dirs
ReadWritePaths=%h/.local/share/omarchy-tidal %h/.cache/omarchy-tidal
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0077
```

Four things to know before pasting that anywhere:

- **Some directives are system-only.** The man page marks a set of them "not
  supported for services running in per-user instances of the service manager",
  and others need user namespaces, which several distributions disable. Every
  line above needs checking against an actual `systemd --user` on an Omarchy
  host rather than being assumed.
- **`ProtectSystem=strict` will break things until `ReadWritePaths` is right.**
  The daemon writes per-track manifests, the art cache and the session file. The
  session file wants `UMask=0077` regardless -- it is an OAuth token at rest.
- **Do not set `MemoryDenyWriteExecute`.** GStreamer `dlopen`s its plugins and
  some decoders JIT; this is the classic directive that turns a hardening pass
  into an afternoon of confusing crashes.
- **`RestrictAddressFamilies` must keep `AF_UNIX`** -- the D-Bus session bus and
  the PipeWire socket both need it. Dropping it takes MPRIS and audio out
  together.

Bring it up with `SystemCallErrorNumber=EPERM` set, so a too-tight filter
produces an ordinary error in the journal instead of an instant kill, and remove
that line once the profile is settled.

### Measuring it

`systemd-analyze security --user omarchy-tidald.service` scores exposure from
0.0 to 10.0 and labels the unit OK / MEDIUM / EXPOSED / UNSAFE. Most unhardened
units land around 8-9. That number belongs next to the memory figure in the
Stage 0 baseline: today's `mopidy.service` scores whatever it scores, and if the
replacement does not beat it, this section did not earn its place.

## The plan

Each stage ships on its own and can be reverted on its own.

**Stage 0 -- Measure.** `scripts/measure-memory.sh` for the backend at rest and
under playback, plus startup-to-first-playable, plus
`systemd-analyze security --user mopidy.service` for the exposure score we are
starting from. Per CLAUDE.md, anything under 8 MB is noise and does not count as
a result. Without these numbers the memory and hardening claims in this document
are assumptions, and should be treated as such until they are numbers.

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

**Stage 5 -- Harden.** The unit is ours now, so give it the sandbox profile from
Security above, one directive at a time with `SystemCallErrorNumber=EPERM` on,
checking each against a real `systemd --user`. Score it against the Stage 0
baseline. This is its own stage rather than a footnote to Stage 3, because a
hardening pass that lands with a functional change is a hardening pass nobody
can bisect.

**Stage 6 -- Delete.** The monkeypatches, `MopidyRpc.js`, the AUR dependencies,
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
- `systemd-analyze security --user` scores the new unit better than the
  `mopidy.service` it replaces, and the daemon still plays, seeks and answers
  MPRIS with the profile on.
- A Widevine-encrypted track reports itself as skipped with a reason, rather
  than stalling at the boundary.
- `gst-inspect-1.0 dashdemux2` confirms which DASH implementation is in use.

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
- **GdkPixbuf.** Cover art decoding is the one place the daemon parses hostile
  bytes in-process. The unit sandbox bounds it; decoding in a short-lived
  subprocess would contain it properly, at the cost of a fork per palette. Worth
  it only if `/palette` stays as rare as it is now -- once per sleeve, cached.
- **GStreamer floor.** 1.26.10 is what FLAC-in-DASH needs. Whether to require it
  outright or degrade is a question about what Omarchy ships, which needs
  checking on a host rather than deciding here.
