"""Which tracks are liked, answered without asking Tidal every time.

The heart beside the current track is asked about on every track change. Tidal
has no "is this one a favourite" call, only the list, so the honest way to
answer is to hold the ids. Walking the list per question was a large request
per track, and stopping at the first thousand -- which is what it did -- told
anyone with a bigger library that their older favourites were not liked.

No tidalapi import: the session is duck-typed, so this loads and tests without
the library installed.
"""

from __future__ import annotations

import logging
import threading
import time

logger = logging.getLogger(__name__)

_PAGE = 1000

# A like made in another client shows up here once this has lapsed. Likes made
# through the companion are noted as they happen and do not wait for it.
DEFAULT_TTL = 300.0


# After a refresh that failed, how long the old answer stands before another
# is tried. Without it every lookup retried the whole walk.
RETRY_AFTER = 30.0

# How long a first lookup waits for a walk someone else has in flight. Nothing
# times the walk itself out -- tidalapi sets no timeout on its requests -- so
# without a limit here every lookup behind a stalled one held a worker for as
# long as the socket took to die, and the companion has four.
FIRST_LOAD_WAIT = 10.0


class FavoriteIds:
    """The liked track ids of one account, refreshed when they go stale."""

    def __init__(self, ttl: float = DEFAULT_TTL, clock=time.monotonic) -> None:
        self._ttl = ttl
        self._clock = clock
        self._lock = threading.Lock()
        # Held for the length of a walk, so the list is fetched once however
        # many lookups arrive wanting it. Nobody waits on it who has an answer
        # already, and nobody waits on it for long: see _refresh.
        self._loading = threading.Lock()
        self._ids: set[int] = set()
        self._loaded_at: float | None = None
        self._user = None
        # Likes and unlikes made while a walk is in flight. The walk's answer
        # is a picture from before them, and would otherwise put them back.
        self._walking = False
        self._since_walk: dict[int, bool] = {}

    def _load(self, session) -> set[int]:
        """Every liked id.

        A favourite Tidal no longer offers keeps its place in the list and is
        left out of the page, so a short page can be the middle of the list.
        Tidal's own count includes those places and says where the end is;
        only without it is a short page taken for the end.
        """
        favorites = session.user.favorites
        try:
            total = int(favorites.get_tracks_count())
        except Exception:
            total = None
        ids: set[int] = set()
        offset = 0
        while True:
            page = list(favorites.tracks(limit=_PAGE, offset=offset) or [])
            ids.update(int(track.id) for track in page)
            offset += _PAGE
            if (offset >= total) if total is not None else (len(page) < _PAGE):
                return ids

    def _stale(self, user) -> bool:
        return (self._loaded_at is None or user != self._user
                or self._clock() - self._loaded_at >= self._ttl)

    def _refresh(self, session, user) -> None:
        with self._lock:
            have_answer = self._loaded_at is not None and user == self._user
        if have_answer:
            # Someone is already walking the list: the answer in hand will do.
            # Waiting here parked one of the companion's four workers behind
            # the walk for every track change that arrived during it.
            if not self._loading.acquire(blocking=False):
                return
        elif not self._loading.acquire(timeout=FIRST_LOAD_WAIT):
            raise TimeoutError("the favourites list is still loading")
        try:
            self._walk(session, user)
        finally:
            self._loading.release()

    def _walk(self, session, user) -> None:
        with self._lock:
            # Someone else walked the list while this waited for the lock.
            if not self._stale(user):
                return
            had_answer = self._loaded_at is not None and user == self._user
            age = self._clock() - self._loaded_at if had_answer else 0.0
            self._walking = True
            self._since_walk = {}
        try:
            ids = self._load(session)
        except Exception:
            with self._lock:
                self._walking = False
                if had_answer:
                    # An old answer beats none: the heart should not go out
                    # because one refresh failed. Try again shortly, not on
                    # the very next lookup -- and say so, or a refresh that
                    # never succeeds again is an old list served in silence.
                    self._loaded_at = self._clock() - self._ttl + min(self._ttl, RETRY_AFTER)
                    logger.warning(
                        "omarchy-tidal: could not refresh favourites; keeping the list "
                        "from %.0fs ago", age, exc_info=True)
                    return
            # With nothing to fall back on, say so.
            raise
        with self._lock:
            for track_id, liked in self._since_walk.items():
                (ids.add if liked else ids.discard)(track_id)
            self._ids = ids
            self._loaded_at = self._clock()
            self._user = user
            self._walking = False

    def contains(self, session, track_id) -> bool:
        """Whether a track is liked. Raises what Tidal raises on a first load."""
        wanted = int(track_id)
        user = getattr(getattr(session, "user", None), "id", None)
        with self._lock:
            stale = self._stale(user)
        if stale:
            self._refresh(session, user)
        with self._lock:
            return wanted in self._ids

    def note(self, track_id, liked: bool) -> None:
        """Record a like or an unlike made through the companion."""
        wanted = int(track_id)
        with self._lock:
            if self._walking:
                self._since_walk[wanted] = bool(liked)
            if self._loaded_at is None:
                return
            if liked:
                self._ids.add(wanted)
            else:
                self._ids.discard(wanted)
