"""The HTTP surface: routing, the two guards, and the player seam.

`http.py` is the largest file in the backend and had no tests at all, because
importing it needs tornado and a parent package for its relative imports. Both
are now supplied -- see `_backend.load_pkg` -- so the parts that do not need a
live Tidal session can be exercised for real, over a real server.

What is deliberately not here: anything that would need an authenticated
session. Those paths are reached through `session_or_503`, and asserting on the
503 is the honest limit of what can be checked without an account.
"""

from __future__ import annotations

import json
import tempfile

import tornado.testing
import tornado.web
from _backend import load_pkg

http = load_pkg("http")
player_mod = load_pkg("player")


# ---- fakes ----------------------------------------------------------------
#
# MopidyPlayer reaches through `core.playback.get_current_track().get()`; the
# `.get()` is pykka's future. Three small objects reproduce that shape without
# pulling in an actor framework.


class FakeTrack:
    def __init__(self, uri: str) -> None:
        self.uri = uri


class FakeFuture:
    def __init__(self, value) -> None:
        self._value = value

    def get(self):
        return self._value


class FakePlayback:
    def __init__(self, track) -> None:
        self._track = track

    def get_current_track(self):
        return FakeFuture(self._track)


class FakeCore:
    def __init__(self, track=None) -> None:
        self.playback = FakePlayback(track)


def make_config(tmp_path) -> dict:
    """The slice of mopidy.conf the extension actually reads."""
    return {
        "core": {"data_dir": str(tmp_path)},
        "tidal": {"quality": "HI_RES_LOSSLESS"},
        "omarchy_tidal": {"lrclib_fallback": False},
    }


# ---- the player seam ------------------------------------------------------


def test_mopidy_player_reports_the_current_uri():
    p = player_mod.MopidyPlayer(FakeCore(FakeTrack("tidal:track:12345")))
    assert p.current_track_uri() == "tidal:track:12345"


def test_mopidy_player_reports_none_when_nothing_is_playing():
    assert player_mod.MopidyPlayer(FakeCore(None)).current_track_uri() is None


def test_no_player_reports_none():
    assert player_mod.NoPlayer().current_track_uri() is None


def test_both_implementations_satisfy_the_protocol():
    # runtime_checkable Protocols check method presence, which is the whole
    # contract here: one method, no arguments.
    assert isinstance(player_mod.MopidyPlayer(FakeCore()), player_mod.Player)
    assert isinstance(player_mod.NoPlayer(), player_mod.Player)


# ---- routing --------------------------------------------------------------


def test_factory_mounts_every_endpoint(tmp_path):
    rules = http.factory(make_config(tmp_path), FakeCore())
    paths = {pattern for pattern, _handler, _kwargs in rules}
    assert paths == {
        "/health", "/auth/status", "/lyrics", "/home", "/favorite", "/radio",
        "/similar", "/artist", "/album", "/format", "/art", "/palette",
        "/art/file", "/entity", "/library", "/playlists", "/playlist/uris",
        "/playlist",
    }


def test_factory_gives_every_handler_a_player(tmp_path):
    rules = http.factory(make_config(tmp_path), FakeCore(FakeTrack("tidal:track:7")))
    for _pattern, _handler, kwargs in rules:
        assert isinstance(kwargs["player"], player_mod.Player)
        # The core itself is no longer handed to handlers.
        assert "core" not in kwargs


def test_playlist_routes_are_distinct(tmp_path):
    """`/playlist` and `/playlist/uris` are different endpoints.

    Tornado anchors a pattern with `$` when it has none, so `/playlist` cannot
    swallow `/playlist/uris` and the order they are listed in does not matter.
    This pins the pairing rather than the order.
    """
    rules = dict((pattern, handler) for pattern, handler, _kwargs in
                 http.factory(make_config(tmp_path), FakeCore()))
    assert rules["/playlist/uris"] is http.PlaylistUrisHandler
    assert rules["/playlist"] is http.PlaylistEditHandler


# ---- content sniffing -----------------------------------------------------


def test_content_type_is_sniffed_not_trusted():
    assert http._content_type(b"\x89PNG\r\n\x1a\n rest") == "image/png"
    assert http._content_type(b"RIFF____WEBPVP8 ") == "image/webp"
    # Tidal serves jpeg today and the URL says nothing, so jpeg is the fallback.
    assert http._content_type(b"\xff\xd8\xff\xe0 whatever") == "image/jpeg"
    assert http._content_type(b"") == "image/jpeg"


# ---- served endpoints -----------------------------------------------------


# Cleaned up when the interpreter exits.
_SIGNED_OUT = tempfile.TemporaryDirectory(prefix="omarchy-tidal-test-")


class HttpSurfaceTest(tornado.testing.AsyncHTTPTestCase):
    """The real handlers, over a real server, with no Tidal session behind them.

    `data_dir` points at a directory with no saved session in it, so
    `SessionProvider.get()` answers None and every session-backed endpoint takes
    its 503 branch. That is the state a machine is in before sign-in, and it
    should not be a crash.
    """

    def get_app(self):
        # get_app() runs once per test method, so the directory is made once for
        # the module rather than once per test. Nothing is written into it --
        # it only has to be a data_dir with no saved session in it.
        return tornado.web.Application(http.factory(make_config(_SIGNED_OUT.name), FakeCore()))

    # -- the cross-origin guard --

    def test_health_answers_without_an_origin(self):
        response = self.fetch("/health")
        assert response.code == 200
        payload = json.loads(response.body)
        assert payload["ok"] is True
        assert payload["logged_in"] is False

    def test_an_origin_header_is_refused(self):
        """Any page in the user's browser can reach 127.0.0.1.

        A browser sets Origin on a cross-origin request and the QML client sets
        none, so anything carrying one is not our client. Without this a web
        page could read someone's library or drive their playback.
        """
        response = self.fetch("/health", headers={"Origin": "https://evil.example"})
        assert response.code == 403

    def test_an_origin_header_is_refused_on_a_post(self):
        # A cross-origin form post is a "simple request": no preflight, but the
        # Origin header still goes, and this is what refuses it.
        response = self.fetch(
            "/playlist", method="POST", body=json.dumps({"action": "create", "name": "x"}),
            headers={"Origin": "https://evil.example"})
        assert response.code == 403

    def test_same_origin_style_requests_without_origin_are_allowed(self):
        # Referer alone is not Origin and must not trip the guard.
        response = self.fetch("/health", headers={"Referer": "https://evil.example/"})
        assert response.code == 200

    # -- the artwork host allowlist (SSRF) --

    def test_art_refuses_a_foreign_host(self):
        response = self.fetch("/art?url=https://evil.example/cover.jpg")
        assert response.code == 400
        assert b"refusing to fetch art" in response.body

    def test_art_refuses_link_local_metadata_addresses(self):
        response = self.fetch("/art?url=http://169.254.169.254/latest/meta-data/")
        assert response.code == 400

    def test_art_refuses_loopback(self):
        response = self.fetch("/art?url=http://127.0.0.1:6680/mopidy/rpc")
        assert response.code == 400

    def test_art_needs_a_uri_or_a_url(self):
        response = self.fetch("/art")
        assert response.code == 400
        assert b"expected a uri or a url" in response.body

    # -- the unauthenticated shape --

    def test_format_reports_503_without_a_session(self):
        response = self.fetch("/format")
        assert response.code == 503
        assert json.loads(response.body)["error"] == "not signed in to Tidal"

    def test_auth_status_answers_while_signed_out(self):
        response = self.fetch("/auth/status")
        assert response.code == 200
        payload = json.loads(response.body)
        assert payload["logged_in"] is False
        # No account fields are invented for a signed-out session.
        assert "email" not in payload

    def test_an_unknown_path_is_a_404(self):
        assert self.fetch("/nonsense").code == 404
