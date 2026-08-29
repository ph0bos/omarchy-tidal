"""Cover art for a Mopidy URI.

Mopidy has `core.library.get_images()`, and mopidy-tidal implements it -- but
only for tracks, and only in the long URI form. `browse()` hands back short
album and artist refs (`tidal:album:114331950`), and for those Mopidy returns
an empty list. A list of albums therefore has no art to draw, which is exactly
the case that most needs it.

So art is resolved here instead, against the same authenticated session the
rest of the companion uses. One round trip per entity is unavoidable -- Tidal's
image URLs are built from a cover id that only comes back with the object --
so the answers are cached: an album's sleeve does not change.

No tidalapi import: everything is duck-typed off the session that is passed in,
which keeps this file loadable (and testable) without the library installed.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

# One Tidal object answers two questions -- what does this look like, and what
# is it -- so both are cached together. An album's sleeve, artist and year do
# not change, and resolving them is a real API round trip either way. Cleared
# wholesale when full rather than evicted one at a time: this is a convenience
# cache, not a working set worth ranking.
_CACHE: dict[str, dict | None] = {}
_CACHE_MAX = 4096


def cache_size() -> int:
    return len(_CACHE)


def cached(key: str) -> tuple[bool, dict | None]:
    """(hit, payload). A cached None means "asked, and there is nothing there"."""
    if key in _CACHE:
        return True, _CACHE[key]
    return False, None


def remember(key: str, payload: dict | None) -> None:
    if len(_CACHE) >= _CACHE_MAX:
        _CACHE.clear()
    _CACHE[key] = payload


def forget_all() -> None:
    _CACHE.clear()


def split(uri: str) -> tuple[str, str] | None:
    """(kind, id) for a tidal URI, or None if this is not one we can resolve.

    Both of mopidy-tidal's shapes end in the entity's own id:
        tidal:track:<id>
        tidal:track:<artist_id>:<album_id>:<id>
    """
    if not uri or not uri.startswith("tidal:"):
        return None
    parts = uri.split(":")
    if len(parts) < 3 or not parts[1] or not parts[-1]:
        return None
    return parts[1], parts[-1]


def _image(obj, size: int) -> str | None:
    if obj is None:
        return None
    try:
        return obj.image(size)
    except Exception:
        return None


def year_of(obj) -> int | None:
    date = getattr(obj, "release_date", None) or getattr(obj, "year", None)
    if date is None:
        return None
    try:
        return int(str(getattr(date, "year", date))[:4])
    except (TypeError, ValueError):
        return None


def _artist_name(obj) -> str:
    artist = getattr(obj, "artist", None)
    if artist is not None and getattr(artist, "name", None):
        return str(artist.name)
    artists = getattr(obj, "artists", None) or []
    names = [str(a.name) for a in artists if getattr(a, "name", None)]
    return ", ".join(names)


def describe(session, uri: str, size: int = 320) -> dict | None:
    """What a URI is, in the shape the UI's rows already use.

    `browse()` returns refs carrying a name and a type and nothing else, so a
    list of albums has no artist and no year to show. This fills that in from
    the same object the artwork comes from -- one round trip answers both.
    """
    parsed = split(uri)
    if parsed is None:
        return None
    kind, ident = parsed

    try:
        if kind == "track":
            track = session.track(int(ident))
            album = getattr(track, "album", None)
            return {
                "uri": uri,
                "type": "track",
                "name": getattr(track, "name", "") or "",
                "artist": _artist_name(track),
                "album": getattr(album, "name", "") or "" if album is not None else "",
                "duration": getattr(track, "duration", None),
                # A track has no art of its own; the sleeve it came in does.
                "image": _image(album, size),
                "hires": bool(getattr(track, "is_hi_res_lossless", False)),
            }
        if kind == "album":
            album = session.album(int(ident))
            return {
                "uri": uri,
                "type": "album",
                "name": getattr(album, "name", "") or "",
                "artist": _artist_name(album),
                "year": year_of(album),
                "num_tracks": getattr(album, "num_tracks", None),
                "image": _image(album, size),
                "hires": "HIRES_LOSSLESS" in (getattr(album, "media_metadata_tags", None) or []),
            }
        if kind == "artist":
            artist = session.artist(int(ident))
            return {
                "uri": uri,
                "type": "artist",
                "name": getattr(artist, "name", "") or "",
                "artist": "",
                "image": _image(artist, size),
            }
        if kind == "playlist":
            # Playlists and mixes are keyed by uuid, not by a number.
            playlist = session.playlist(ident)
            creator = getattr(playlist, "creator", None)
            return {
                "uri": uri,
                "type": "playlist",
                "name": getattr(playlist, "name", "") or "",
                "artist": str(getattr(creator, "name", "") or "") if creator else "",
                "num_tracks": getattr(playlist, "num_tracks", None),
                "image": _image(playlist, size),
            }
        if kind == "mix":
            mix = session.mix(ident)
            return {
                "uri": uri,
                "type": "mix",
                "name": getattr(mix, "title", "") or getattr(mix, "name", "") or "",
                "artist": getattr(mix, "sub_title", "") or "",
                "image": _image(mix, size),
            }
    except Exception:
        return None
    return None


def resolve(session, uri: str, size: int = 320) -> str | None:
    """The cover art URL for one URI, or None when there is none to be had."""
    payload = describe(session, uri, size)
    return (payload or {}).get("image")


# ---------------------------------------------------------------- disk cache
#
# The cache above saves the round trip that *finds* a sleeve. This saves the one
# that downloads it. Art is immutable and a library view can ask for a hundred
# images in a single scroll, so the bytes are kept on disk and every later
# request -- including after a shell restart, which empties Qt's own in-memory
# pixmap cache -- is served locally.

CACHE_DIR_NAME = "omarchy-tidal/art"
DEFAULT_MAX_BYTES = 256 * 1024 * 1024


def cache_dir(env=None) -> Path:
    """Where the bytes live: $XDG_CACHE_HOME/omarchy-tidal/art, or ~/.cache."""
    env = os.environ if env is None else env
    base = env.get("XDG_CACHE_HOME") or ""
    if not base:
        base = str(Path(env.get("HOME", "/tmp")) / ".cache")
    return Path(base) / CACHE_DIR_NAME


def path_for(key: str, root: Path, suffix: str = ".img") -> Path:
    """A stable path for a cache key, fanned out one level.

    Thousands of files in a single directory is slow to stat on some
    filesystems, so the first two characters of the digest become a subdir --
    the same layout git uses for loose objects.
    """
    digest = hashlib.sha1(key.encode("utf-8")).hexdigest()
    return root / digest[:2] / f"{digest[2:]}{suffix}"


def write_atomic(path: Path, payload: bytes) -> None:
    """Write through a temporary file so a reader never sees half an image."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".part")
    tmp.write_bytes(payload)
    os.replace(tmp, path)


def prune(root: Path, max_bytes: int = DEFAULT_MAX_BYTES) -> int:
    """Drop the least recently used files until the cache fits. Returns bytes freed.

    Least recently *used*, not written: reads touch mtime below, because atime
    is unreliable under relatime and absent under noatime.
    """
    if not root.exists():
        return 0
    files = []
    total = 0
    for path in root.rglob("*"):
        if not path.is_file() or path.name.endswith(".part"):
            continue
        try:
            stat = path.stat()
        except OSError:
            continue
        files.append((stat.st_mtime, stat.st_size, path))
        total += stat.st_size

    if total <= max_bytes:
        return 0

    files.sort(key=lambda item: item[0])
    freed = 0
    for _mtime, size, path in files:
        if total - freed <= max_bytes:
            break
        try:
            path.unlink()
        except OSError:
            continue
        freed += size
    return freed


def touch(path: Path) -> None:
    """Mark a cache hit, so pruning can tell warm files from cold ones."""
    try:
        os.utime(path, None)
    except OSError:
        pass
