"""The liked-track ids behind the heart."""

import pytest
from _backend import load

favorites = load("favorites")


class Track:
    def __init__(self, ident):
        self.id = ident


class Favorites:
    def __init__(self, ids):
        self.ids = list(ids)
        self.calls = []
        self.fail = False

    def tracks(self, limit=50, offset=0):
        self.calls.append((limit, offset))
        if self.fail:
            raise RuntimeError("tidal said no")
        return [Track(i) for i in self.ids[offset:offset + limit]]


class Session:
    def __init__(self, ids, user_id=1):
        self.user = type("User", (), {})()
        self.user.id = user_id
        self.user.favorites = Favorites(ids)


def test_a_favourite_past_the_first_page_is_still_a_favourite(monkeypatch):
    monkeypatch.setattr(favorites, "_PAGE", 3)
    session = Session(range(1, 9))
    ids = favorites.FavoriteIds()
    assert ids.contains(session, "8") is True
    assert ids.contains(session, "99") is False
    assert session.user.favorites.calls == [(3, 0), (3, 3), (3, 6)], "walked once, to the end"


def test_the_list_is_walked_again_once_it_is_stale():
    now = [0.0]
    session = Session([1])
    ids = favorites.FavoriteIds(ttl=60, clock=lambda: now[0])
    assert ids.contains(session, 1) is True
    session.user.favorites.ids = [1, 2]
    assert ids.contains(session, 2) is False, "still inside the ttl"
    now[0] = 61
    assert ids.contains(session, 2) is True


def test_a_like_made_here_does_not_wait_for_the_refresh():
    session = Session([1])
    ids = favorites.FavoriteIds()
    assert ids.contains(session, 2) is False
    ids.note("2", True)
    assert ids.contains(session, 2) is True
    ids.note("1", False)
    assert ids.contains(session, 1) is False
    assert len(session.user.favorites.calls) == 1


def test_a_failed_refresh_keeps_the_old_answer_and_a_failed_first_load_raises():
    now = [0.0]
    session = Session([1])
    ids = favorites.FavoriteIds(ttl=60, clock=lambda: now[0])
    assert ids.contains(session, 1) is True
    session.user.favorites.fail = True
    now[0] = 61
    assert ids.contains(session, 1) is True

    with pytest.raises(RuntimeError):
        favorites.FavoriteIds().contains(session, 1)


def test_another_account_does_not_inherit_the_list():
    ids = favorites.FavoriteIds()
    assert ids.contains(Session([1], user_id=1), 1) is True
    assert ids.contains(Session([], user_id=2), 1) is False


def test_a_like_made_while_the_list_is_being_walked_survives_the_walk():
    """The walk's answer is a picture from before the like. Installing it whole
    put the heart out on a track Tidal had just been told to like."""
    import threading

    started, release = threading.Event(), threading.Event()

    class Slow(Favorites):
        def tracks(self, limit=50, offset=0):
            started.set()
            release.wait(2)
            return super().tracks(limit, offset)

    for first_load in (True, False):
        now = [0.0]
        session = Session([1])
        ids = favorites.FavoriteIds(ttl=60, clock=lambda now=now: now[0])
        if not first_load:
            assert ids.contains(session, 1) is True
            now[0] = 61
        session.user.favorites = Slow([1, 3])
        started.clear()
        release.clear()
        walker = threading.Thread(target=ids.contains, args=(session, 1))
        walker.start()
        assert started.wait(2)
        ids.note(2, True)       # liked here, after the walk's picture was taken
        ids.note(3, False)      # and unliked
        release.set()
        walker.join(2)
        assert ids.contains(session, 2) is True
        assert ids.contains(session, 3) is False


def test_the_list_is_walked_once_however_many_ask_at_the_same_moment():
    import threading

    release = threading.Event()

    class Slow(Favorites):
        def tracks(self, limit=50, offset=0):
            release.wait(2)
            return super().tracks(limit, offset)

    session = Session([1])
    session.user.favorites = Slow([1])
    ids = favorites.FavoriteIds()
    answers = []
    askers = [threading.Thread(target=lambda: answers.append(ids.contains(session, 1)))
              for _ in range(4)]
    for asker in askers:
        asker.start()
    release.set()
    for asker in askers:
        asker.join(2)
    assert answers == [True] * 4
    assert len(session.user.favorites.calls) == 1


def test_a_failed_refresh_is_not_retried_on_the_very_next_lookup():
    now = [0.0]
    session = Session([1])
    ids = favorites.FavoriteIds(ttl=300, clock=lambda: now[0])
    assert ids.contains(session, 1) is True
    session.user.favorites.fail = True
    now[0] = 301
    for _ in range(5):
        assert ids.contains(session, 1) is True
    assert len(session.user.favorites.calls) == 2, "one walk, then one failed refresh"
    now[0] = 301 + favorites.RETRY_AFTER
    session.user.favorites.fail = False
    session.user.favorites.ids = [1, 2]
    assert ids.contains(session, 2) is True


def test_a_lookup_with_an_answer_does_not_wait_behind_a_walk():
    """The walk holds a lock for as long as Tidal takes, and nothing times a
    stalled request out. Every lookup that waited on it held one of the
    companion's four workers, and the health probe queued behind them."""
    import threading

    now = [0.0]
    started, release = threading.Event(), threading.Event()

    class Stalled(Favorites):
        stall = False

        def tracks(self, limit=50, offset=0):
            if self.stall:
                started.set()
                release.wait(5)
            return super().tracks(limit, offset)

    session = Session([1])
    session.user.favorites = Stalled([1])
    ids = favorites.FavoriteIds(ttl=60, clock=lambda: now[0])
    assert ids.contains(session, 1) is True

    now[0] = 61
    session.user.favorites.stall = True
    walker = threading.Thread(target=ids.contains, args=(session, 1))
    walker.start()
    assert started.wait(2)
    try:
        answers = []
        asker = threading.Thread(target=lambda: answers.append(ids.contains(session, 1)))
        asker.start()
        asker.join(1)
        assert answers == [True], "answered from the list in hand while the walk is stuck"
    finally:
        release.set()
        walker.join(2)


def test_a_first_lookup_gives_up_on_a_walk_that_does_not_finish(monkeypatch):
    import threading

    monkeypatch.setattr(favorites, "FIRST_LOAD_WAIT", 0.05)
    started, release = threading.Event(), threading.Event()

    class Stalled(Favorites):
        def tracks(self, limit=50, offset=0):
            started.set()
            release.wait(5)
            return super().tracks(limit, offset)

    session = Session([1])
    session.user.favorites = Stalled([1])
    ids = favorites.FavoriteIds()
    walker = threading.Thread(target=ids.contains, args=(session, 1))
    walker.start()
    assert started.wait(2)
    try:
        with pytest.raises(TimeoutError):
            ids.contains(session, 1)
    finally:
        release.set()
        walker.join(2)


def test_another_accounts_first_load_failing_does_not_answer_from_the_last_account():
    ids = favorites.FavoriteIds()
    assert ids.contains(Session([1], user_id=1), 1) is True
    other = Session([], user_id=2)
    other.user.favorites.fail = True
    with pytest.raises(RuntimeError):
        ids.contains(other, 1)


def test_a_refresh_that_fails_says_so(caplog):
    now = [0.0]
    session = Session([1])
    ids = favorites.FavoriteIds(ttl=60, clock=lambda: now[0])
    ids.contains(session, 1)
    session.user.favorites.fail = True
    now[0] = 61
    with caplog.at_level("WARNING"):
        assert ids.contains(session, 1) is True
    assert "could not refresh favourites" in caplog.text
    assert "61s ago" in caplog.text


def test_a_short_page_in_the_middle_does_not_end_the_walk(monkeypatch):
    """Tidal leaves an unavailable favourite out of the page but keeps its
    position, so the first page of a long list can come back short."""
    monkeypatch.setattr(favorites, "_PAGE", 3)

    class Gappy(Favorites):
        def get_tracks_count(self):
            return 8

        def tracks(self, limit=50, offset=0):
            page = super().tracks(limit, offset)
            return page[1:] if offset == 0 else page

    session = Session(range(1, 9))
    session.user.favorites = Gappy(range(1, 9))
    ids = favorites.FavoriteIds()
    assert ids.contains(session, 8) is True
    assert session.user.favorites.calls == [(3, 0), (3, 3), (3, 6)]
