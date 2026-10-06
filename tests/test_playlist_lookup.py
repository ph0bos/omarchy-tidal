"""The repair of `core.library.lookup()` for playlists and mixes.

Issue #1: none of a user's playlists would play, though picking a single track
out of one worked. `core.tracklist.add(uris=["tidal:playlist:<id>"])` is
`core.library.lookup()` underneath, and mopidy-tidal answers a playlist there
out of `PlaylistMetadataCache` -- the same on-disk store its *playlists*
provider fills with `[mock_track] * num_tracks`, where `mock_track` is
`Track(uri="tidal:track:0:0:0", name=None)`. The queue filled with placeholders
and playback had nothing real to start.

These exercise the patch against a stand-in for the provider that reproduces
the parts of `TidalLibraryProvider.lookup()` the patch has to survive: the
constructor that assigns its own cache, the cache read whose `KeyError` means
"miss", and the unguarded `getattr(self, cache_name).update(...)` at the end.
"""

from __future__ import annotations

from _backend import load

playlist_lookup = load("playlist_lookup")

PLAYLIST = "tidal:playlist:1234abcd-0000-1111-2222-333344445555"
MIX = "tidal:mix:0000deadbeef"

# What the playlists provider writes for a three-track playlist it has not
# fetched the tracks of.
PLACEHOLDER = "tidal:track:0:0:0"


class FakePlaylistWithPlaceholders:
    """A cached playlist as `refresh(include_items=False)` leaves it."""

    tracks = (PLACEHOLDER, PLACEHOLDER, PLACEHOLDER)


class Provider:
    """The shape of `TidalLibraryProvider` that `lookup()` depends on."""

    def __init__(self, poisoned=True):
        self.session = object()
        self.asked = []
        # mopidy-tidal's own constructor does exactly this, and the patch has
        # to make it a no-op rather than let it win.
        self._playlist_cache = {PLAYLIST: FakePlaylistWithPlaceholders()} if poisoned else {}

    def _lookup_playlist(self, session, parts):
        self.asked.append(parts[1])
        tracks = ["tidal:track:1", "tidal:track:2", "tidal:track:3"]
        # The real one returns (tracks, playlist-object) for the cache to keep.
        return tracks, FakePlaylistWithPlaceholders()

    def lookup(self, uri):
        """A faithful reduction of mopidy-tidal's lookup for one uri."""
        parts = uri.split(":")
        item_type = parts[1]
        cache_name = f"_{item_type}_cache"
        cache_miss = True
        data = []

        try:
            data = getattr(self, cache_name)[uri]
            cache_miss = not bool(data)
        except (AttributeError, KeyError):
            pass

        cache_updates = {}
        if cache_miss:
            try:
                looker = getattr(self, f"_lookup_{item_type}")
            except AttributeError:
                return []
            data = cache_data = looker(self.session, parts)
            if item_type == "playlist":
                data, cache_data = data
            cache_updates[cache_name] = {uri: cache_data}

        tracks = list(data.tracks) if (item_type == "playlist" and not cache_miss) else list(data)

        # Outside the try in the original: a missing cache attribute raises
        # straight out of lookup().
        for name, new_data in cache_updates.items():
            getattr(self, name).update(new_data)
        return tracks


def mix_tracks(session, mix_id):
    return [f"tidal:track:mix-{mix_id}-1", f"tidal:track:mix-{mix_id}-2"]


def patched():
    cls = type("Patched", (Provider,), {})
    playlist_lookup.apply(cls, mix_tracks)
    return cls


# ---- the bug ---------------------------------------------------------------


def test_unpatched_a_playlist_expands_to_placeholders():
    """The failure issue #1 reported, so the fix below has something to beat."""
    assert Provider().lookup(PLAYLIST) == [PLACEHOLDER] * 3


def test_unpatched_a_mix_expands_to_nothing():
    assert Provider().lookup(MIX) == []


# ---- the repair ------------------------------------------------------------


def test_a_playlist_expands_to_its_real_tracks():
    provider = patched()()
    assert provider.lookup(PLAYLIST) == ["tidal:track:1", "tidal:track:2", "tidal:track:3"]


def test_the_poisoned_cache_is_never_consulted():
    provider = patched()()
    provider.lookup(PLAYLIST)
    assert provider.asked == ["playlist"], "the session must be asked, not the cache"


def test_the_constructors_own_cache_assignment_is_dropped():
    """A property is a data descriptor, so `self._playlist_cache = ...` loses."""
    provider = patched()()
    assert isinstance(provider._playlist_cache, playlist_lookup.NeverCaches)


def test_writing_back_to_the_cache_is_harmless():
    """lookup() stores what it fetched; that must not make the next call stale."""
    provider = patched()()
    provider.lookup(PLAYLIST)
    provider.lookup(PLAYLIST)
    assert provider.asked == ["playlist", "playlist"]


def test_a_mix_expands_to_its_tracks():
    provider = patched()()
    assert provider.lookup(MIX) == [
        "tidal:track:mix-0000deadbeef-1",
        "tidal:track:mix-0000deadbeef-2",
    ]


def test_a_mix_lookup_has_a_cache_to_write_back_to():
    """Without `_mix_cache` the final update() raises out of lookup()."""
    provider = patched()()
    provider.lookup(MIX)  # would be AttributeError


def test_patching_is_idempotent():
    cls = patched()
    playlist_lookup.apply(cls, mix_tracks)
    assert cls().lookup(PLAYLIST) == ["tidal:track:1", "tidal:track:2", "tidal:track:3"]


# ---- the cache itself ------------------------------------------------------


def test_never_caches_always_misses():
    cache = playlist_lookup.NeverCaches()
    cache["k"] = "v"
    cache.update({"k": "v"})
    try:
        cache["k"]
    except KeyError:
        return
    raise AssertionError("a read must raise KeyError -- that is how lookup() spells a miss")


# ---- primed tracks -----------------------------------------------------------


class MopidyTrack:
    """Stands in for a mopidy Track model: opaque, truthy, not iterable."""

    def __init__(self, uri):
        self.uri = uri


class LookupProvider:
    """A provider whose original lookup counts how often it was consulted."""

    def __init__(self):
        self.asked = []

    def lookup(self, uris=None):
        self.asked.append(uris)
        return ["slow-path"]


def _patched_lookup_provider():
    cls = type("P", (LookupProvider,), {})
    playlist_lookup.apply(cls, mix_tracks=lambda session, mix_id: [])
    return cls()


def test_a_primed_uri_is_answered_without_the_slow_path():
    provider = _patched_lookup_provider()
    track = MopidyTrack("tidal:track:7:8:9")
    playlist_lookup.prime([("tidal:track:9", track)])
    assert provider.lookup("tidal:track:9") == [track]
    assert provider.asked == [], "a primed track must cost no API calls"


def test_an_unprimed_uri_still_takes_the_original_path():
    provider = _patched_lookup_provider()
    assert provider.lookup("tidal:track:404404404") == ["slow-path"]
    assert provider.asked == ["tidal:track:404404404"]


def test_a_one_element_list_counts_as_a_single_uri():
    provider = _patched_lookup_provider()
    track = MopidyTrack("tidal:track:1:2:3")
    playlist_lookup.prime([("tidal:track:3", track)])
    assert provider.lookup(["tidal:track:3"]) == [track]


def test_a_many_uri_lookup_is_left_to_the_original():
    """Order across a mixed hit/miss batch is the original's problem to solve
    correctly; ours is only the per-uri hot path Mopidy's core actually uses."""
    provider = _patched_lookup_provider()
    playlist_lookup.prime([("tidal:track:1", MopidyTrack("t"))])
    assert provider.lookup(["tidal:track:1", "tidal:track:2"]) == ["slow-path"]


def test_the_primed_table_is_bounded():
    playlist_lookup.prime(
        [(f"tidal:track:bound{i}", MopidyTrack(str(i))) for i in range(6000)])
    assert len(playlist_lookup._primed) <= playlist_lookup._PRIMED_MAX


def test_prime_items_maps_tracks_and_skips_the_rest(monkeypatch):
    """Against a stand-in mapper, so the path that primes is the one tested
    whether or not mopidy-tidal is installed where this runs."""
    import sys
    import types

    class Track:
        def __init__(self, ident, odd=False):
            self.id = ident
            self.odd = odd

    class Video:
        id = 99

    def create_mopidy_track(artist, album, item):
        if item.odd:
            raise ValueError("a track the mapper cannot read")
        return MopidyTrack(f"tidal:track:0:0:{item.id}")

    mappers = types.ModuleType("mopidy_tidal.full_models_mappers")
    mappers.create_mopidy_track = create_mopidy_track
    package = types.ModuleType("mopidy_tidal")
    package.full_models_mappers = mappers
    monkeypatch.setitem(sys.modules, "mopidy_tidal", package)
    monkeypatch.setitem(sys.modules, "mopidy_tidal.full_models_mappers", mappers)

    items = [Track(9001), Video(), Track(9002, odd=True), Track(9003)]
    assert playlist_lookup.prime_items(items) == 2, "the video and the odd one are left out"

    provider = _patched_lookup_provider()
    assert provider.lookup("tidal:track:9003")[0].uri == "tidal:track:0:0:9003"
    assert provider.lookup("tidal:track:9002") == ["slow-path"]
    assert provider.asked == ["tidal:track:9002"]


def test_prime_items_without_mopidy_tidal_primes_nothing_and_does_not_raise(monkeypatch):
    import sys

    monkeypatch.setitem(sys.modules, "mopidy_tidal", None)

    class Track:
        id = 1

    assert playlist_lookup.prime_items([Track()]) == 0
