"""Turning a playlist into the uris that get queued.

`/playlist` draws a page; `/playlist/uris` plays the whole thing, so this walks
to the end and answers only with what Mopidy can actually stream.
"""

from __future__ import annotations

from _backend import load

expand = load("expand")


class Track:
    def __init__(self, ident):
        self.id = ident


class Video:
    def __init__(self, ident):
        self.id = ident


class Playlist:
    """Offset paging only -- an older tidalapi, without tracks_paginated()."""

    def __init__(self, items):
        self.items = items
        self.calls = []

    def tracks_paginated(self):
        raise AttributeError("tracks_paginated")

    def tracks(self, limit=None, offset=0):
        self.calls.append((limit, offset))
        return self.items[offset:offset + (limit or len(self.items))]


class PaginatedPlaylist(Playlist):
    def tracks_paginated(self):
        return list(self.items)


# ---- uris ------------------------------------------------------------------


def test_track_order_is_the_playlists_order():
    assert expand.track_uris([Track(3), Track(1), Track(2)]) == [
        "tidal:track:3", "tidal:track:1", "tidal:track:2"]


def test_videos_are_left_out():
    """They have no stream Mopidy takes; queueing one reads as stopping halfway."""
    assert expand.track_uris([Track(1), Video(9), Track(2)]) == [
        "tidal:track:1", "tidal:track:2"]


def test_an_item_with_no_id_is_left_out():
    assert expand.track_uris([Track(1), Track(None)]) == ["tidal:track:1"]


def test_nothing_in_is_nothing_out():
    assert expand.track_uris([]) == []
    assert expand.track_uris(None) == []


# ---- paging ----------------------------------------------------------------


def test_tracks_paginated_is_used_when_it_exists():
    playlist = PaginatedPlaylist([Track(i) for i in range(5)])
    assert len(expand.playlist_items(playlist)) == 5
    assert playlist.calls == [], "no need to page by hand"


def test_a_playlist_longer_than_one_page_is_walked_to_the_end():
    """The bug this endpoint exists to avoid is a truncated queue."""
    playlist = Playlist([Track(i) for i in range(250)])
    assert expand.playlist_track_uris(playlist) == [f"tidal:track:{i}" for i in range(250)]
    assert playlist.calls == [(100, 0), (100, 100), (100, 200)]


def test_a_short_playlist_takes_one_request():
    playlist = Playlist([Track(i) for i in range(7)])
    assert len(expand.playlist_track_uris(playlist)) == 7
    assert playlist.calls == [(100, 0)]


def test_an_exactly_full_page_asks_once_more_and_stops():
    playlist = Playlist([Track(i) for i in range(100)])
    assert len(expand.playlist_track_uris(playlist)) == 100
    assert playlist.calls == [(100, 0), (100, 100)]


def test_an_empty_playlist_terminates():
    playlist = Playlist([])
    assert expand.playlist_track_uris(playlist) == []


def test_a_failing_page_ends_the_walk_rather_than_raising():
    class Broken(Playlist):
        def tracks(self, limit=None, offset=0):
            raise RuntimeError("tidal said no")

    assert expand.playlist_track_uris(Broken([])) == []


# ---- mixes -----------------------------------------------------------------


class Mix:
    """A mix answers everything in one call; there is no paging."""

    def __init__(self, items):
        self._items = items

    def items(self):
        return self._items


def test_a_mix_expands_like_a_playlist():
    mix = Mix([Track(1), Video(9), Track(2)])
    assert expand.mix_track_uris(mix) == ["tidal:track:1", "tidal:track:2"]


def test_a_mix_that_fails_to_answer_is_empty_rather_than_an_error():
    class Broken:
        def items(self):
            raise RuntimeError("tidal hiccup")

    assert expand.mix_track_uris(Broken()) == []
