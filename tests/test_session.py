"""URI parsing. mopidy-tidal emits two shapes for the same track."""

from _backend import load

_session = load("session")
entity_id, track_id = _session.entity_id, _session.track_id


def test_short_track_uri():
    assert track_id("tidal:track:12345") == "12345"


def test_long_track_uri_takes_the_last_segment():
    assert track_id("tidal:track:1134:20505823:20505835") == "20505835"


def test_rejects_other_schemes_and_shapes():
    assert track_id("tidal:album:1") is None
    assert track_id("spotify:track:1") is None
    assert track_id("tidal:track:1:2") is None      # four parts is not a shape
    assert track_id("") is None
    assert track_id(None) is None


def test_entity_ids():
    assert entity_id("tidal:artist:16992", "artist") == "16992"
    assert entity_id("tidal:album:341273436", "album") == "341273436"
    assert entity_id("tidal:artist:1", "album") is None
    assert entity_id("", "artist") is None


# ---- session cache ----------------------------------------------------------


def test_a_session_tidal_no_longer_accepts_is_dropped(tmp_path):
    """The cache key is the file's mtime, and a session can stop being accepted
    without the file changing. logged_in() is the health probe's question, so a
    dead session must not survive it -- that was a reboot's worth of empty
    pages."""
    provider = _session.SessionProvider({"core": {"data_dir": str(tmp_path)}})

    (tmp_path / "tidal").mkdir()
    session_file = tmp_path / "tidal" / "tidal-pkce.json"
    session_file.write_text("{}")

    class Dead:
        def check_login(self):
            return False

    provider._was_logged_in = True
    provider._session = Dead()
    provider._mtime = session_file.stat().st_mtime

    assert provider.logged_in() is False
    assert provider._session is None, "the next get() must rebuild from disk"
    assert provider._mtime is None


def test_an_outage_keeps_the_last_answer_and_the_session_for_as_long_as_it_lasts(tmp_path):
    """check_login is a request to Tidal. Failing to make it is not the same as
    being told no -- and rebuilding the session needs the same network, so
    dropping it made the second probe of an outage a real "not signed in"."""
    provider = _session.SessionProvider({"core": {"data_dir": str(tmp_path)}})
    (tmp_path / "tidal").mkdir()
    session_file = tmp_path / "tidal" / "tidal-pkce.json"
    session_file.write_text("{}")

    class Flaky:
        offline = False

        def check_login(self):
            if self.offline:
                raise ConnectionError("network is down")
            return True

    session = Flaky()
    provider._session = session
    provider._mtime = session_file.stat().st_mtime
    assert provider.logged_in() is True

    session.offline = True
    for _probe in range(4):
        assert provider.logged_in() is True, "the last real answer stands"
        assert provider.get() is session, "and nothing is rebuilt while Tidal cannot be reached"

    session.offline = False
    assert provider.logged_in() is True


class _Response:
    def __init__(self, status):
        self.status_code = status
        self.ok = 200 <= status < 300


class _Asked:
    """A session shaped like tidalapi's where it matters: it answers the one
    request check_login() makes, with whatever status the test sets."""

    session_id = "s"

    def __init__(self, status=200):
        self.status = status
        self.user = type("User", (), {"id": 7})()
        self.request = self

    def basic_request(self, method, path):
        return _Response(self.status)


def _provider_with(tmp_path, session):
    provider = _session.SessionProvider({"core": {"data_dir": str(tmp_path)}})
    (tmp_path / "tidal").mkdir()
    session_file = tmp_path / "tidal" / "tidal-pkce.json"
    session_file.write_text("{}")
    provider._session = session
    provider._mtime = session_file.stat().st_mtime
    return provider


def test_tidal_being_busy_or_broken_is_not_being_signed_out(tmp_path):
    """check_login() is `.ok`, so a 429 and a 503 read the same as a 401. Only
    the 401 is about the session."""
    session = _Asked()
    provider = _provider_with(tmp_path, session)
    assert provider.logged_in() is True

    for status in (429, 500, 503):
        session.status = status
        assert provider.logged_in() is True, f"{status} is no answer; the last one stands"
        assert provider.get() is session, "and the session is kept"


def test_a_refused_session_is_rebuilt_by_the_probe_and_not_by_each_request(tmp_path, monkeypatch):
    """A rebuild validates the credentials with Tidal. get() is called on
    Mopidy's IOLoop by every handler, so a rebuild that failed must not be
    tried again there."""
    loads = []

    class Rebuilt:
        def __init__(self, config):
            pass

        def load_session_from_file(self, path):
            loads.append(path)
            raise ConnectionError("tidal refuses these credentials")

    monkeypatch.setattr(_session.tidalapi, "Session", Rebuilt)

    provider = _provider_with(tmp_path, _Asked(status=401))
    provider._was_logged_in = True
    assert provider.logged_in() is False
    assert len(loads) == 1, "rebuilt once, inside the probe"

    for _request in range(6):
        assert provider.get() is None
    assert len(loads) == 1, "requests do not retry it"

    assert provider.logged_in() is False
    assert len(loads) == 2, "the next probe does"


def test_a_refused_session_that_rebuilds_is_signed_in_within_the_same_probe(tmp_path, monkeypatch):
    class Rebuilt(_Asked):
        def __init__(self, config):
            super().__init__(status=200)

        def load_session_from_file(self, path):
            return True

    monkeypatch.setattr(_session.tidalapi, "Session", Rebuilt)

    provider = _provider_with(tmp_path, _Asked(status=403))
    assert provider.logged_in() is True
    assert isinstance(provider.get(), Rebuilt)
