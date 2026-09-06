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

logger = logging.getLogger(__name__)

_PATCHED_FLAG = "_omarchy_tidal_playlist_lookup"

# Where the real cache would have lived. The descriptor below occupies the
# class attribute, so the per-instance object is parked under its own key.
_SLOT = "_omarchy_tidal_never_caches"


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
