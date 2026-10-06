"""Make `core.library.lookup()` answer honestly for playlists and mixes.

Two of mopidy-tidal's caches share one directory on disk, and the collision
makes "play this playlist" queue nothing playable:

    TidalPlaylistsProvider._playlists_metadata = PlaylistMetadataCache()
    TidalLibraryProvider._playlist_cache       = PlaylistMetadataCache()

Both land on `<cache>/tidal/playlist_metadata/<xx>/tidal-playlist-<id>.cache`.
`as_list()` fills the first one through `refresh(include_items=False)`, which
does not fetch the tracks at all -- it writes `[mock_track] * num_tracks`, and
`mock_track` is `Track(uri="tidal:track:0:0:0", name=None)`. The library
provider then reads that same file, takes the cache-hit branch

    if item_type == "playlist" and not cache_miss:
        tracks += data.tracks

and returns a row of placeholders without ever consulting the session. Since
`core.tracklist.add(uris=[...])` is `core.library.lookup()` underneath, the
queue fills with `tidal:track:0:0:0` and playback has nothing real to start.
The cache persists to disk, so one listing of the playlists breaks every
play-all that follows, in this Mopidy run and every later one.

Mixes fail differently and just as quietly: the library provider has no
`_lookup_mix` at all, so a `tidal:mix:` uri expands to zero tracks.

Both are fixed here rather than worked around, because `core.library.lookup()`
is what every Mopidy client uses -- not only this plugin. The playlist cache is
replaced with one that never answers, so a lookup always asks Tidal; that costs
one round trip per play-all and buys freshness, which the cache could not offer
anyway (its entries are keyed by uri and never revalidated). `_lookup_mix` is
added alongside.

Like `gapless.py`, this rebinds mopidy-tidal in the process it already shares
with us, and it is deliberately defensive: anything unexpected leaves the
extension untouched and the patch simply stays off.
"""

from __future__ import annotations

import logging
import threading
from collections import OrderedDict

logger = logging.getLogger(__name__)

_PATCHED_FLAG = "_omarchy_tidal_playlist_lookup"

# Where the real cache would have lived. The descriptor below occupies the
# class attribute, so the per-instance object is parked under its own key.
_SLOT = "_omarchy_tidal_never_caches"

# ---- primed tracks ----------------------------------------------------------
#
# Filling the queue is `core.library.lookup()` once per uri, and mopidy-tidal's
# `_lookup_track` answers a cold uri with a request for the album and another
# for its tracks -- and, for the short `tidal:track:<id>` form this plugin
# sends, one for the track first. Forty tracks is over a hundred sequential
# API calls inside one "play all", which outlives the client's timeout or
# trips Tidal's rate limiter; either way playback never starts. A playlist
# whose tracks were recently browsed sits in mopidy-tidal's own cache and
# plays fine, which is exactly why the failure looked arbitrary.
#
# The companion has already fetched every one of those tracks, in full, when
# it expanded the playlist -- so it primes them here, and the wrapped lookup
# below answers from this table without touching the network at all.
_PRIMED_MAX = 5000
_primed: OrderedDict = OrderedDict()
_primed_lock = threading.Lock()


def prime(pairs) -> int:
    """Remember (uri, mopidy-track) pairs for the lookups about to happen."""
    count = 0
    with _primed_lock:
        for uri, track in pairs or []:
            if not uri or track is None:
                continue
            _primed.pop(uri, None)
            _primed[uri] = track
            count += 1
        while len(_primed) > _PRIMED_MAX:
            _primed.popitem(last=False)
    return count


def prime_items(items) -> int:
    """Best effort: map tidalapi tracks to Mopidy tracks and prime them.

    One odd item must not cost the rest their fast path, so mapping failures
    are skipped rather than raised. Returns how many were primed; zero means
    lookups fall back to mopidy-tidal's own (slow) path, which still works.
    """
    try:
        from mopidy_tidal import full_models_mappers
    except Exception:
        return 0
    pairs = []
    for item in items or []:
        if type(item).__name__.lower() != "track":
            continue
        ident = getattr(item, "id", None)
        if ident is None:
            continue
        try:
            track = full_models_mappers.create_mopidy_track(None, None, item)
        except Exception:
            continue
        pairs.append((f"tidal:track:{ident}", track))
    return prime(pairs)


def _primed_hit(uris):
    """The primed track for a single-uri lookup, or None.

    Mopidy's core calls each backend's lookup one uri at a time, so the single
    string is the hot path; a one-element list is accepted for symmetry with
    mopidy-tidal's own signature. Anything else is not ours to answer.
    """
    if isinstance(uris, str):
        key = uris
    elif isinstance(uris, (list, tuple)) and len(uris) == 1 and isinstance(uris[0], str):
        key = uris[0]
    else:
        return None
    with _primed_lock:
        return _primed.get(key)


class NeverCaches(dict):
    """A cache that never answers and never remembers.

    `TidalLibraryProvider.lookup()` reads its caches inside a `try` that
    swallows `KeyError`, so raising is how a miss is spelled. The writes are
    dropped because there is nothing worth keeping: the entry this would store
    is the one the playlists provider overwrites with placeholders.
    """

    def __getitem__(self, key):
        raise KeyError(key)

    def __setitem__(self, key, value) -> None:
        return None

    def update(self, *args, **kwargs) -> None:
        return None


def _never_caches(self) -> NeverCaches:
    cache = self.__dict__.get(_SLOT)
    if cache is None:
        cache = NeverCaches()
        self.__dict__[_SLOT] = cache
    return cache


def _ignore_assignment(self, value) -> None:
    """Swallow `self._playlist_cache = PlaylistMetadataCache()` in __init__.

    A property is a data descriptor, so it wins over the instance dictionary in
    both directions: the assignment mopidy-tidal's own constructor makes comes
    through here and is dropped, and every read afterwards gets ours.
    """
    return None


def apply(provider_cls, mix_tracks) -> None:
    """Patch a `TidalLibraryProvider` class in place.

    `mix_tracks(session, mix_id)` returns the mopidy Tracks of one mix. It is a
    parameter rather than an import so this can be exercised without tidalapi.
    """
    cache = property(_never_caches, _ignore_assignment)
    provider_cls._playlist_cache = cache

    # `lookup()` derives the cache name from the uri -- `tidal:mix:x` wants
    # `_mix_cache` -- and the final `getattr(self, cache_name).update(...)` sits
    # outside the try that guards the rest, so a mix lookup without this
    # attribute would raise AttributeError straight out of lookup().
    provider_cls._mix_cache = cache

    def _lookup_mix(self, session, parts):
        return mix_tracks(session, parts[2])

    provider_cls._lookup_mix = _lookup_mix

    # Serve primed tracks before mopidy-tidal's own lookup gets to spend up to
    # three API round trips deriving what the companion already knows in full.
    orig_lookup = getattr(provider_cls, "lookup", None)
    if orig_lookup is not None and not getattr(orig_lookup, "_omarchy_primed", False):

        def lookup(self, uris=None):
            hit = _primed_hit(uris)
            if hit is not None:
                return [hit]
            return orig_lookup(self, uris)

        lookup._omarchy_primed = True
        provider_cls.lookup = lookup


def install() -> bool:
    """Rebind mopidy-tidal's library provider. True when the patch is active."""
    try:
        from mopidy_tidal import full_models_mappers
        from mopidy_tidal.library import TidalLibraryProvider
    except Exception:
        logger.warning(
            "mopidy-tidal internals not as expected; "
            "playlist and mix lookup left alone"
        )
        return False

    if getattr(TidalLibraryProvider, _PATCHED_FLAG, False):
        return True

    def mix_tracks(session, mix_id):
        return full_models_mappers.create_mopidy_tracks(session.mix(mix_id).items())

    try:
        apply(TidalLibraryProvider, mix_tracks)
    except Exception:
        logger.exception("could not patch mopidy-tidal's library provider")
        return False

    setattr(TidalLibraryProvider, _PATCHED_FLAG, True)
    logger.info("Omarchy TIDAL: playlist and mix lookup answer with real tracks")
    return True
