<img src="assets/icon.svg" width="56" alt="">

# Omarchy TIDAL

TIDAL as a native part of the [Omarchy](https://omarchy.org/) desktop — hi-res
lossless playback, search, lyrics, and discovery, with no TIDAL window anywhere.

Now-playing lives in the bar. Search is `SUPER+M`. Lyrics are `SUPER+SHIFT+M`.
Media keys, the OSD, and the volume panel work the way they already do for
everything else, and every surface follows the active Omarchy theme.

## Why not just run the TIDAL app?

There isn't one for Linux. The realistic options each fail in a specific way:

| Option | Problem |
|---|---|
| `tidal-hifi` (Electron + Widevine) | Plays through a browser engine — **capped at 16-bit/44.1**, so no hi-res |
| `sone`, `high-tide`, `hiresti` | Reach 24/192, but each owns its own window and its own UI |

This plugin takes a third path: a **headless** playback backend
(Mopidy + `mopidy-tidal`, which supports `HI_RES_LOSSLESS`) with the entire
user interface built natively into the Omarchy shell.

## Why not a Spotify plugin?

There are several good ones — `quickshell.spotify` is excellent. But every
Spotify client on Linux plays through `spotifyd`, which tops out at **320 kbps
Ogg Vorbis**. No amount of UI work changes that.

Omarchy TIDAL plays **24-bit / 192 kHz FLAC**, and takes the output path
seriously enough to verify it: it configures PipeWire to follow the source
sample rate, and reports the format actually negotiated rather than the tier
that was requested.

It is also, as of this writing, the only TIDAL plugin in a catalogue of 1,724.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  quickshell.tidal — Quickshell plugin                       │
│  Service · BarWidget · Overlay (search / lyrics / setup)  │
└───────┬─────────────────────────────────┬────────────────┘
        │ MPRIS over D-Bus (push state)   │ HTTP JSON-RPC (commands)
┌───────▼─────────────────────────────────▼────────────────┐
│  Mopidy (systemd --user)                                  │
│   ├─ mopidy-tidal    auth · search · library · streaming  │
│   ├─ mopidy-mpris    D-Bus MPRIS2 surface                 │
│   └─ mopidy-omarchy-tidal   lyrics · home · radio · format│
└──────────────────────────────────────────────────────────┘
              GStreamer → PipeWire → your DAC
```

Playback state arrives over **MPRIS**, which is push-based and free — no
polling and no WebSocket dependency (Quickshell ships no WebSocket module).
Commands go out over Mopidy's HTTP JSON-RPC using QML's built-in
`XMLHttpRequest`. Tidal-specific extras that Mopidy's core API has no concept
of — lyrics, favorites, radio seeds, the negotiated stream format — come from a
small companion Mopidy extension that reuses `mopidy-tidal`'s already
authenticated session rather than logging in twice.

## Status

Phases 0–2 complete and verified against a live shell and a real TIDAL account.

- [x] Plugin manifest and repo layout
- [x] `Service.qml` — MPRIS binding, IPC surface, transport, favorites, radio
- [x] `BarWidget.qml` — now-playing, album art, hi-res quality badge
- [x] `Overlay.qml` — summoned surface with the setup/status view
- [x] "Crest" mark, drawn natively in QML so it takes the theme color
- [x] `bin/omarchy-tidal-setup` — deps, config, service, PipeWire rates, login
- [x] Companion Mopidy extension — lyrics, home, radio, similar, favorites, format
- [x] In-shell sign-in — clipboard-watching PKCE, no terminal
- [x] Full player — sidebar, search, browse, drill-down, queue, transport
- [ ] Lyrics and now-playing view
- [ ] Mini player and playlist editing
- [ ] Menu, keybindings, hooks, notifications, scrobbling, settings
- [ ] TIDAL Connect device switching
- [ ] Signal-path inspector and output advisor

`omarchy-shell tidal status` reports live state:

```json
{
  "connected": true, "backend": "up", "companion": true,
  "title": "Hunter", "artist": "Björk",
  "quality": "FLAC 24/96", "hiRes": true
}
```

### Player

`SUPER+M` opens the player: a sidebar over Mopidy's TIDAL tree (Home, For You,
Hi-Res, My Tracks/Albums/Artists/Playlists, Mixes, Queue), search, drill-down
into albums and artists, and a transport bar with seek, favourite, and the
hi-res quality badge.

| Key | Action |
|---|---|
| `/` or `Ctrl+F` | Focus search |
| `Up` / `Down` | Move |
| `Enter` | Play now |
| `Shift+Enter` | Add to queue |
| `Right` | Open album / artist / folder |
| `Left` or `Backspace` | Back |
| `Tab` | Switch sidebar ↔ list |
| `Space` | Play/pause |
| `Esc` | Close |

### Signing in

TIDAL's PKCE flow redirects to `https://tidal.com/android/login/auth` — a remote
URL, so no local server can catch the callback. Every Linux TIDAL client
therefore asks you to paste the address into a form.

`omarchy-tidal-auth` watches the clipboard instead. Sign in, press
`Ctrl+L` `Ctrl+C`, and it completes on its own. A paste field remains as a
fallback. The session is written straight to mopidy-tidal's own path, so there
is no second login to maintain.

### Verified on real hardware

| Check | Result |
|---|---|
| TIDAL stream | `HI_RES_LOSSLESS` — 24-bit, up to 96 kHz |
| Decode | `S24LE @ 96000` |
| PipeWire → DAC | 96000 → 96000, **no resampling** |
| Lyrics | Time-synced LRC from TIDAL, millisecond stamps |
| Home | 20 personalised rows in < 1 s |
| Radio | 100-track queue from any seed |
| Favorites | Round-trip through `SUPER+ALT+M` |

## Backend gotchas

Three things bite on a fresh Arch install. `omarchy-tidal-setup` handles all of
them, but they are worth knowing:

1. **Mopidy must come from `aur/mopidy4`, not `extra/mopidy`.** The repo package
   is `4.0.0a2`, a *pre-release*, and `mopidy-mpris` requires `mopidy>=4.0.0`.
   On the alpha it dies at import with `cannot import name 'CoreEvent'` and MPRIS
   never registers — which silently breaks the bar widget, the media keys, and
   the OSD, since all three read state over MPRIS.
2. **`aur/mopidy4` conflicts with `extra/mopidy`,** and `yay --noconfirm`
   answers *no* to the removal prompt, so the install aborts with a zero exit
   code. The replacement has to be done explicitly.
3. **The `mopidy-mpris` PKGBUILD omits `setuptools-scm`** from its makedepends,
   so its wheel build fails unless `python-setuptools-scm` is already installed.

## Setup

Requires a TIDAL subscription that includes hi-res FLAC.

```bash
./bin/omarchy-tidal-setup check   # what's missing
./bin/omarchy-tidal-setup all     # install, configure, start, log in, verify
```

Run the steps individually if you'd rather see each one:
`deps`, `configure`, `service`, `audio`, `backend`, `login`, `verify`.

`configure` backs up any existing `~/.config/mopidy/mopidy.conf` before writing.

Then install the plugin itself:

```bash
omarchy plugin add <this-repo-url>
omarchy plugin enable quickshell.tidal
```

## Keybindings

| Key | Action |
|---|---|
| `SUPER + M` | Search / browse |
| `SUPER + SHIFT + M` | Now playing + lyrics |
| `SUPER + ALT + M` | Favorite current track |
| `SUPER + CTRL + M` | Start radio from current track |

Media keys (`XF86Audio*`) need no configuration — they already drive MPRIS.

## The mark

"Crest" — level-meter bars whose tops trace a breaking wave.

It is deliberately *not* TIDAL's wave-and-triangle logo, which is their
trademark and would make this plugin unshippable. The mark is drawn on a 32-unit
grid with a 3.2 stroke so every line lands on a whole pixel when halved to 16px,
the size it actually runs at in the bar.

`qml/components/TideMark.qml` redraws it as five rounded rectangles rather than
loading the SVG, which keeps it crisp at any bar height and lets it take a theme
color directly. `assets/icon.svg` is the same geometry in `currentColor`;
`assets/app-icon.svg` is a 512px version with explicit colors, for `.desktop`
entries where there is no theme to inherit.

## Development

Plugin code hot-reloads on save once the plugin lives in
`~/.config/omarchy/plugins/`. Force a reload with:

```bash
omarchy-shell shell rescanPlugins
```

**If you develop through a symlink** — `ln -s ~/dev/omarchy-tidal-plugin
~/.config/omarchy/plugins/quickshell.tidal` — the file watcher does not follow
it into the repo, so edits appear to do nothing and the shell keeps serving the
previously loaded QML. `rescanPlugins` does not help either. Restart the shell:

```bash
omarchy restart shell
```

This costs real debugging time if you do not know it: the UI looks like your
code is broken when it simply has not been loaded.

Lint QML against the shell's own modules:

```bash
mkdir -p /tmp/qsimports && ln -sfn /usr/share/omarchy/shell /tmp/qsimports/qs
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I /tmp/qsimports qml/*.qml
```

`Member ... not found on type "QObject"` warnings are expected — the shell's
injected `bar` and the `Style`/`Color` singletons are untyped `QtObject`s that
qmllint cannot introspect. Omarchy's own widgets produce the same warnings.

## Output quality caveat

`omarchy-tidal-setup audio` configures PipeWire to follow the source sample
rate, but the output device has the final say. Many displays advertise only
`44100 48000 96000 192000` over HDMI or DisplayPort and reject the 44.1 kHz
family, so 88.2 kHz albums are resampled to 96 kHz no matter what PipeWire is
told. Check yours:

```bash
cat /proc/asound/card*/eld#* | grep sad0_rates
```

A USB or S/PDIF DAC generally accepts the full set.
