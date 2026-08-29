# Mopidy-Omarchy-Tidal

Companion Mopidy extension for the [Omarchy TIDAL plugin](../README.md).

Mopidy's core API covers search, browse, and playback. It has no concept of
lyrics, TIDAL's personalised home, radio seeds, favourites, or the sample rate a
stream negotiated — so this extension adds them under `/omarchy-tidal/`.

It runs in-process with `mopidy-tidal` and reuses that extension's authenticated
`tidalapi` session, so there is no second login to perform or keep alive.

| Endpoint | Returns |
|---|---|
| `GET /health` | Liveness plus whether a TIDAL session is loaded |
| `GET /auth/status` | Login state, quality tier, user id |
| `GET /lyrics?uri=` | Time-synced lyrics — TIDAL first, LRCLIB fallback |
| `GET /home` | TIDAL's personalised rows, flattened |
| `GET /favorite?uri=` | Whether a track is favourited |
| `POST /favorite` | `{uri, favorite}` — add or remove |
| `GET /radio?uri=` | Track or artist radio, as playable URIs |
| `GET /similar?uri=` | Similar artists or albums |
| `GET /format` | Negotiated stream format for what is playing |

## Install

```bash
pip install --user ./backend
```

Then restart Mopidy. `omarchy-tidal-setup check` reports whether the shell can
see it.

## Notes

Every `tidalapi` call is blocking and some take seconds, so all of them run on
an executor — Mopidy serves its whole HTTP API from a single Tornado IOLoop, and
blocking it would stall the JSON-RPC endpoint the rest of the plugin depends on.

Requests carrying a cross-origin `Origin` header are refused. Mopidy binds to
127.0.0.1, but any page in the user's browser can reach localhost, and these
endpoints expose library data and can drive playback.
