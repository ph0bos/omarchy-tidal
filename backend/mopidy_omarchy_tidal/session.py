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
        self._lock = threading.Lock()

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
        """Return a usable session, reloading it if the file changed."""
        with self._lock:
            path = self._session_file()
            if path is None:
                return None

            try:
                mtime = path.stat().st_mtime
            except OSError:
                return None

            if self._session is not None and mtime == self._mtime:
                return self._session

            session = tidalapi.Session(tidalapi.Config(quality=self._quality))
            try:
                loaded = session.load_session_from_file(path)
            except Exception:
                logger.exception("Could not load the Tidal session from %s", path)
                return None

            if not loaded:
                logger.warning("Tidal session at %s did not load", path)
                return None

            self._session = session
            self._mtime = mtime
            logger.info("Loaded Tidal session from %s", path)
            return session

    def logged_in(self) -> bool:
        session = self.get()
        if session is None:
            return False
        try:
            return bool(session.check_login())
        except Exception:
            return False


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
