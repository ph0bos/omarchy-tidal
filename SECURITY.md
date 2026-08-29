# Security

Omarchy plugins run **unsandboxed inside the shell process**. Code here can do
anything your user can.

## Reporting

Open a [security advisory](https://github.com/ph0bos/omarchy-tidal/security/advisories/new)
rather than a public issue.

## What this plugin touches

- **Your TIDAL session** is written by `mopidy-tidal` to
  `~/.local/share/mopidy/tidal/tidal-pkce.json`. This plugin reads it to reuse
  the session; it never copies it elsewhere and never transmits it. Your
  password is only ever entered on TIDAL's own page.
- **The companion HTTP endpoints** are bound to `127.0.0.1` by Mopidy. Any page
  in your browser can reach localhost, so requests carrying a cross-origin
  `Origin` header are refused — they would otherwise expose your library and
  allow driving playback.
- **`omarchy-tidal-setup`** installs packages and writes config. It asks before
  escalating and backs up any existing `mopidy.conf`.
- **LRCLIB** is contacted only when TIDAL has no lyrics for a track, and
  receives just the artist, title, album and duration. Set
  `lrclib_fallback = false` in `mopidy.conf` to disable it.
