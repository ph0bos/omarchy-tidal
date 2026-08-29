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

# Sleeves do not change, so a hit here saves a real API round trip for the rest
# of the session. Cleared wholesale when full rather than evicted one at a
# time: this is a convenience cache, not a working set worth ranking.
_CACHE: dict[str, str | None] = {}
_CACHE_MAX = 4096


def cache_size() -> int:
    return len(_CACHE)


def cached(uri: str) -> tuple[bool, str | None]:
    """(hit, url). A cached None means "asked, and there is no art"."""
    if uri in _CACHE:
        return True, _CACHE[uri]
    return False, None


def remember(uri: str, url: str | None) -> None:
    if len(_CACHE) >= _CACHE_MAX:
        _CACHE.clear()
    _CACHE[uri] = url


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


def resolve(session, uri: str, size: int = 320) -> str | None:
    """The cover art URL for one URI, or None when there is none to be had."""
    parsed = split(uri)
    if parsed is None:
        return None
    kind, ident = parsed

    try:
        if kind == "track":
            # A track has no art of its own; the sleeve it came in does.
            return _image(getattr(session.track(int(ident)), "album", None), size)
        if kind == "album":
            return _image(session.album(int(ident)), size)
        if kind == "artist":
            return _image(session.artist(int(ident)), size)
        # Playlists and mixes are keyed by uuid, not by a number.
        if kind == "playlist":
            return _image(session.playlist(ident), size)
        if kind == "mix":
            return _image(session.mix(ident), size)
    except Exception:
        return None
    return None


# ---------------------------------------------------------------- disk cache
#
# The URL cache above saves the round trip that *finds* a sleeve. This saves
# the one that downloads it. Art is immutable and a library view can ask for a
# hundred images in a scroll, so the bytes are kept on disk and every later
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

    Least recently *used*, not written: the filesystem's atime is unreliable
    (relatime, noatime), so reads touch mtime instead and this stays a plain
    mtime sort.
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
