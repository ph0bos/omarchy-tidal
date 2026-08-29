"""Lyrics resolution: Tidal first, LRCLIB as a fallback.

tidalapi does expose lyrics -- `Track.lyrics()` returns a Lyrics object with
`.subtitles` (an LRC-format string with per-line timestamps) and `.text` (plain).
The published API docs omit it, but it is there and it is time-synced.

Tidal's catalogue is not complete, so anything it has no lyrics for falls back
to LRCLIB: a free, open, no-auth synced-lyrics database. Both sources are
normalised to the same shape so the UI never has to care which one answered.
"""

from __future__ import annotations

import logging
import re

import requests

logger = logging.getLogger(__name__)

LRCLIB_URL = "https://lrclib.net/api/get"
LRCLIB_TIMEOUT = 6

# LRCLIB asks clients to identify themselves.
USER_AGENT = "omarchy-tidal-plugin (https://github.com/stevenr/omarchy-tidal-plugin)"

# [mm:ss.xx] or [mm:ss:xx] or [mm:ss]. A line may carry several stamps.
_STAMP = re.compile(r"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]")


def parse_lrc(raw: str) -> list[dict]:
    """Turn an LRC string into [{time_ms, text}], sorted by time.

    Lines with several timestamps expand to one entry each, which is how LRC
    encodes a repeated chorus.
    """
    if not raw:
        return []

    out: list[dict] = []
    for line in raw.splitlines():
        stamps = list(_STAMP.finditer(line))
        if not stamps:
            continue
        text = _STAMP.sub("", line).strip()
        for stamp in stamps:
            minutes = int(stamp.group(1))
            seconds = int(stamp.group(2))
            frac = stamp.group(3) or "0"
            # LRC fractions are usually centiseconds but milliseconds appear too.
            frac_ms = int(frac.ljust(3, "0")[:3]) if len(frac) == 3 else int(frac) * 10
            out.append({
                "time_ms": (minutes * 60 + seconds) * 1000 + frac_ms,
                "text": text,
            })

    out.sort(key=lambda item: item["time_ms"])
    return out


def _empty(source: str | None = None) -> dict:
    return {"synced": [], "plain": "", "source": source}


def from_tidal(track) -> dict | None:
    """Lyrics straight from Tidal, or None when it has none for this track."""
    try:
        lyrics = track.lyrics()
    except Exception:
        # tidalapi raises MetadataNotAvailable for the (common) no-lyrics case.
        return None

    if lyrics is None:
        return None

    synced = parse_lrc(getattr(lyrics, "subtitles", "") or "")
    plain = (getattr(lyrics, "text", "") or "").strip()
    if not synced and not plain:
        return None

    return {"synced": synced, "plain": plain, "source": "tidal"}


def from_lrclib(artist: str, title: str, album: str = "", duration: int = 0) -> dict | None:
    """Lyrics from LRCLIB, or None when it has nothing usable."""
    if not artist or not title:
        return None

    params = {"artist_name": artist, "track_name": title}
    if album:
        params["album_name"] = album
    if duration:
        params["duration"] = int(duration)

    try:
        response = requests.get(
            LRCLIB_URL,
            params=params,
            timeout=LRCLIB_TIMEOUT,
            headers={"User-Agent": USER_AGENT},
        )
    except requests.RequestException:
        logger.debug("LRCLIB request failed for %s - %s", artist, title, exc_info=True)
        return None

    if response.status_code != 200:
        return None

    try:
        payload = response.json()
    except ValueError:
        return None

    synced = parse_lrc(payload.get("syncedLyrics") or "")
    plain = (payload.get("plainLyrics") or "").strip()
    if not synced and not plain:
        return None

    return {"synced": synced, "plain": plain, "source": "lrclib"}


def resolve(track, *, allow_lrclib: bool = True) -> dict:
    """Best available lyrics for a tidalapi Track."""
    result = from_tidal(track)
    if result is not None:
        return result

    if not allow_lrclib:
        return _empty()

    try:
        artist = track.artist.name if track.artist else ""
        title = track.name or ""
        album = track.album.name if track.album else ""
        duration = int(track.duration or 0)
    except Exception:
        return _empty()

    return from_lrclib(artist, title, album, duration) or _empty()
