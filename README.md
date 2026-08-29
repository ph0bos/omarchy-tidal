<img src="assets/icon.svg" width="60" alt="">

# TIDAL for Omarchy

**True hi-res lossless TIDAL, native to the Omarchy desktop.** 24-bit/192kHz
FLAC, a full player, artist and album pages, time-synced lyrics, and a live
spectrum analyser — with no TIDAL window anywhere.

![The player](docs/screenshots/player.png)

---

## Why this exists

Every other way of playing TIDAL on Linux gives something up:

| | Problem |
|---|---|
| `tidal-hifi` (Electron + Widevine) | Plays through a browser engine — **capped at 16-bit/44.1** |
| Native clients (`sone`, `high-tide`) | Reach 24/192, but each owns its own window and its own UI |
| Spotify plugins | `spotifyd` is **capped at 320 kbps Ogg**. No UI work changes that |

This takes a third path: a **headless** backend with the entire interface built
into the Omarchy shell. Now-playing lives in the bar. Search is `SUPER+M`.
Media keys, the OSD and the volume panel behave exactly as they do for
everything else, and every surface follows your active theme.

It is also the only TIDAL plugin in a catalogue of 1,700+.

## Install

```bash
omarchy plugin add https://github.com/ph0bos/omarchy-tidal.git
omarchy plugin enable quickshell.tidal
```

Then press `SUPER+M`. The plugin detects what is missing and walks you through
installing the backend and signing in — no terminal required.

Prefer to do it yourself:

```bash
./bin/omarchy-tidal-setup all
```

**Requirements:** Omarchy 4+, and a TIDAL subscription that includes hi-res.

## Signing in

TIDAL's PKCE flow redirects to `https://tidal.com/android/login/auth` — a remote
URL, so nothing local can catch the callback. That is why every Linux TIDAL
client ends up asking you to paste the address into a form.

This watches your clipboard instead. Sign in, press `Ctrl+L` `Ctrl+C`, and it
completes on its own.

## What you get

### Player

Sidebar over the whole TIDAL tree — Home, For You, **Hi-Res**, your tracks,
albums, artists, playlists and mixes — with search, drill-down, and a queue.
Every row shows track, artist and album, and the playing row is marked.

### Artist and album pages

![An artist page](docs/screenshots/artist.png)

Photography, biography, editorial reviews, credits, top tracks, discography and
similar artists. TIDAL's inline markup is cleaned up and the artists it
references become chips you can jump to.

### Now playing

![Now playing](docs/screenshots/nowplaying.png)

Album art, time-synced lyrics that scroll with playback — click any line to seek
to it — and a live spectrum analyser reading PipeWire's own output, so it stays
in time with what you hear.

Click the artwork in the player bar to expand, click it again to contract.

### Hi-res, verified

The quality badge reports the format TIDAL **actually negotiated** — not the
tier that was requested. `omarchy-tidal-setup audio` also configures PipeWire to
follow the source sample rate, because the default (`allowed-rates = [48000]`)
silently resamples every hi-res stream before it reaches your DAC.

## Keys

| Key | Action |
|---|---|
| `SUPER + M` | Player |
| `SUPER + SHIFT + M` | Now playing and lyrics |
| `SUPER + ALT + M` | Favourite current track |
| `SUPER + CTRL + M` | Start radio from current track |

Inside the player: `/` search · `↑`/`↓` move · `Enter` play · `Shift+Enter`
queue · `→` open · `←`/`Backspace` back · `Tab` switch pane · `Space`
play/pause · `Esc` close.

Media keys need no configuration — they already drive MPRIS.

Bar widget: **left click opens the app**, right click jumps to now playing,
middle click plays/pauses, scroll changes track.

## How it works

```
┌──────────────────────────────────────────────────────────┐
│  quickshell.tidal — Quickshell plugin                    │
│  Service · BarWidget · Player · Now Playing · Setup       │
└───────┬─────────────────────────────────┬────────────────┘
        │ MPRIS over D-Bus (push state)   │ HTTP JSON-RPC (commands)
┌───────▼─────────────────────────────────▼────────────────┐
│  Mopidy (systemd --user)                                  │
│   ├─ mopidy-tidal    auth · search · library · streaming  │
│   ├─ mopidy-mpris    D-Bus MPRIS2 surface                 │
│   └─ mopidy-omarchy-tidal  lyrics · pages · radio · format│
└──────────────────────────────────────────────────────────┘
              GStreamer → PipeWire → your DAC
```

Playback state arrives over **MPRIS**, which is push-based and free. Commands go
out over Mopidy's HTTP JSON-RPC using QML's built-in `XMLHttpRequest` — no
WebSocket dependency, because Quickshell ships no WebSocket module. Lyrics,
TIDAL's home page, radio, favourites and stream format come from a small
companion Mopidy extension that reuses `mopidy-tidal`'s authenticated session
rather than logging in twice.

## Known constraints

**Your output device has the final say on sample rate.** Many displays advertise
only `44100 48000 96000 192000` over HDMI or DisplayPort and reject the 44.1 kHz
family, so 88.2 kHz albums are resampled to 96 kHz regardless of configuration:

```bash
cat /proc/asound/card*/eld#* | grep sad0_rates
```

A USB or S/PDIF DAC generally accepts the full set.

**Mopidy must come from `aur/mopidy4`, not `extra/mopidy`.** The repo package is
`4.0.0a2`, a pre-release, and `mopidy-mpris` requires `mopidy>=4.0.0`. On the
alpha it fails to import and MPRIS never registers — which breaks the bar
widget, the media keys and the OSD. The setup script handles this.

**Memory:** roughly 130 MB for the Mopidy backend. That is more than a Rust
daemon like `spotifyd` uses, and it is the price of lossless — still around 7×
lighter than the official desktop client, with no Electron window.

`tidalapi` is unofficial and TIDAL can change its API. That is true of every
TIDAL client on Linux.

## Development

Code hot-reloads on save under `~/.config/omarchy/plugins/`. Force a reload with
`omarchy-shell shell rescanPlugins`.

**If you develop through a symlink**, the file watcher does not follow it into
your repo — edits appear to do nothing and the shell keeps serving the QML it
loaded first. `rescanPlugins` does not help either. Use `omarchy restart shell`.

```bash
mkdir -p /tmp/qsimports && ln -sfn /usr/share/omarchy/shell /tmp/qsimports/qs
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I /tmp/qsimports qml/*.qml
omarchy plugin validate .
```

`Member ... not found on type "QObject"` warnings are expected — the injected
`bar` and the `Style`/`Color` singletons are untyped. Omarchy's own widgets
produce the same warnings.

Write Nerd Font glyphs as `\uXXXX` escapes. Shell heredocs silently strip
private-use codepoints, which shows up as invisible icons.

## Diagnostics

```bash
omarchy-tidal-setup check     # every dependency, config and service
omarchy-shell tidal status    # live playback state as JSON
```

## Licence

MIT. Not affiliated with or endorsed by TIDAL.
