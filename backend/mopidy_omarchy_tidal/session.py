"""Reuse of mopidy-tidal's authenticated tidalapi session.

Logging in twice would be user-hostile and would double the number of tokens
that can expire. mopidy-tidal persists its session as JSON in its own extension
data dir, and tidalapi can rehydrate a Session straight from that file, so this
extension borrows the credentials rather than owning any.

The file is re-read when its mtime changes, which is how a token refresh
performed by mopidy-tidal propagates here without a restart.
"""

from __future__ import annotations

import logging
import threading
from pathlib import Path

import tidalapi
from tidalapi import Quality

logger = logging.getLogger(__name__)

# mopidy-tidal's config values -> tidalapi's enum.
_QUALITY = {
    "HI_RES_LOSSLESS": Quality.hi_res_lossless,
    "LOSSLESS": Quality.high_lossless,
    "HIGH": Quality.low_320k,
    "LOW": Quality.low_96k,
}

# The session filename mopidy-tidal picks depends on its auth_method.
_SESSION_FILES = ("tidal-pkce.json", "tidal-oauth.json")


class SessionProvider:
    """Hands out a logged-in tidalapi Session, or None if not signed in."""

    def __init__(self, config) -> None:
        tidal_config = config.get("tidal") or {}
        quality_name = str(tidal_config.get("quality") or "HI_RES_LOSSLESS")
        self._quality = _QUALITY.get(quality_name, Quality.hi_res_lossless)

        core_config = config.get("core") or {}
        data_dir = core_config.get("data_dir")
        # mopidy-tidal stores its session under the *tidal* extension's data
        # dir, not the config dir -- a detail that is easy to get wrong.
        self._dir = Path(str(data_dir)) / "tidal" if data_dir else None

        self._session: tidalapi.Session | None = None
        self._mtime: float | None = None
        self._failed_mtime: float | None = None
        self._lock = threading.Lock()
        self._was_logged_in = False

    @property
    def quality(self) -> Quality:
        return self._quality

    def _session_file(self) -> Path | None:
        if self._dir is None:
            return None
        for name in _SESSION_FILES:
            candidate = self._dir / name
            if candidate.is_file():
                return candidate
        return None

    def get(self) -> tidalapi.Session | None:
        """Return a usable session, reloading it if the file changed.

        Handlers call this on Mopidy's IOLoop, so it must not keep retrying a
        load that has already failed: loading validates the credentials with
        Tidal, and a session that cannot be rebuilt would otherwise cost every
        request a blocking round trip. A failure is remembered for as long as
        the file is unchanged, and `logged_in()` -- which runs on the executor
        -- is what tries again.
        """
        with self._lock:
            return self._load(retry=False)

    def _load(self, retry: bool) -> tidalapi.Session | None:
        path = self._session_file()
        if path is None:
            return None

        try:
            mtime = path.stat().st_mtime
        except OSError:
            return None

        if self._session is not None and mtime == self._mtime:
            return self._session
        if not retry and mtime == self._failed_mtime:
            return None

        self._session = None
        self._mtime = None
        session = tidalapi.Session(tidalapi.Config(quality=self._quality))
        try:
            loaded = session.load_session_from_file(path)
        except Exception:
            # Said once per file, not once per probe.
            if mtime != self._failed_mtime:
                logger.warning("Could not load the Tidal session from %s", path, exc_info=True)
            self._failed_mtime = mtime
            return None

        if not loaded:
            if mtime != self._failed_mtime:
                logger.warning("Tidal session at %s did not load", path)
            self._failed_mtime = mtime
            return None

        self._session = session
        self._mtime = mtime
        self._failed_mtime = None
        logger.info("Loaded Tidal session from %s", path)
        return session

    def invalidate(self) -> None:
        """Forget the cached session so the next load rebuilds it from disk.

        The cache key is the file's mtime, and a session can stop being
        accepted without the file changing -- tidalapi only refreshes a token
        itself when Tidal's error says, verbatim, that it expired. Without
        this, a session Tidal had stopped accepting was handed out unchanged
        until Mopidy itself was restarted, and every surface built on the
        companion -- home, library, artwork, playlist pages -- sat empty until
        then. A rebuild loads and validates the credentials afresh; it was
        reported to clear the condition on a real account, and costs one
        request when it does not.
        """
        with self._lock:
            self._session = None
            self._mtime = None

    @staticmethod
    def _ask(session) -> bool | None:
        """Whether Tidal accepts this session: yes, no, or None for no answer.

        tidalapi's `check_login()` is `.ok` on one request, which is False for
        a 429 or a 503 exactly as it is for a 401. Only the last two say the
        session is not accepted; the rest say Tidal could not answer just now.
        """
        request = getattr(session, "request", None)
        user = getattr(session, "user", None)
        if request is None:
            return bool(session.check_login())
        if user is None or not getattr(user, "id", None):
            return False
        if not getattr(session, "session_id", None):
            return False
        response = request.basic_request("GET", f"users/{user.id}/subscription")
        if response.ok:
            return True
        return False if response.status_code in (401, 403) else None

    def logged_in(self) -> bool:
        """The health probe's question. Runs on the executor, never the loop."""
        with self._lock:
            session = self._load(retry=True)
        if session is None:
            self._was_logged_in = False
            return False
        try:
            answer = self._ask(session)
        except Exception:
            # A request to Tidal that could not be made is "could not ask",
            # not "no". Reporting it as signed out put the setup wizard over a
            # working player every time the network blinked; the last real
            # answer stands instead. The session is kept as well: rebuilding
            # it needs the same network that just failed.
            logger.debug("Could not reach Tidal to check the session", exc_info=True)
            return self._was_logged_in
        if answer is None:
            logger.debug("Tidal did not say whether the session is accepted")
            return self._was_logged_in
        if not answer:
            # Rebuilt here and now, so a stale session heals within the probe
            # that found it, and so the rebuild happens off the IOLoop. If it
            # does not take, get() answers None until the file changes or the
            # next probe tries again.
            self.invalidate()
            with self._lock:
                rebuilt = self._load(retry=True)
            try:
                answer = rebuilt is not None and self._ask(rebuilt) is True
            except Exception:
                answer = False
            if not answer:
                with self._lock:
                    self._session = None
                    self._mtime = None
                    try:
                        path = self._session_file()
                        self._failed_mtime = path.stat().st_mtime if path else None
                    except OSError:
                        self._failed_mtime = None
        self._was_logged_in = answer
        return answer


def track_id(uri: str) -> str | None:
    """Pull the Tidal track id out of a Mopidy URI.

    mopidy-tidal emits two shapes and both are valid:
        tidal:track:<track_id>
        tidal:track:<artist_id>:<album_id>:<track_id>
    The track id is the final component either way.
    """
    if not uri or not uri.startswith("tidal:track:"):
        return None
    parts = uri.split(":")
    return parts[-1] if len(parts) in (3, 5) else None


def entity_id(uri: str, kind: str) -> str | None:
    """Pull an id out of a `tidal:<kind>:<id>` URI."""
    prefix = f"tidal:{kind}:"
    if not uri or not uri.startswith(prefix):
        return None
    parts = uri.split(":")
    return parts[2] if len(parts) >= 3 else None
