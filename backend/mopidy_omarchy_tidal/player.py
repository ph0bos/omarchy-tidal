"""What is playing, asked without naming who is playing it.

`/format` is the one endpoint that needs to know the current track, and it needs
only the uri: it takes the id out of it and asks Tidal directly. That single
question was reaching straight into `core.playback`, which made it the only line
in 1,130 of `http.py` that could not run without a Mopidy core behind it.

Naming the question instead of the answerer costs one small class and buys two
things. A fake player is three lines, so the endpoint becomes testable. And when
the backend stops being Mopidy -- see `docs/design/removing-mopidy.md` -- this is
the seam the replacement plugs into, rather than a call site to go and find.

Every implementation here is **blocking**, deliberately. Mopidy's core is a
pykka actor and reading from it means waiting on a future; the caller already
has an executor for exactly this and `BaseHandler.run()` is how you reach it.
Making these async would move the blocking somewhere less obvious, not remove
it.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable


@runtime_checkable
class Player(Protocol):
    """The playback state this extension actually consumes."""

    def current_track_uri(self) -> str | None:
        """The uri of the track playing right now, or None if there is none.

        Blocking. Call it on an executor.
        """
        ...


class MopidyPlayer:
    """A `Player` backed by Mopidy's core actor."""

    def __init__(self, core) -> None:
        self._core = core

    def current_track_uri(self) -> str | None:
        # `.get()` waits on the pykka future. This is the blocking part.
        track = self._core.playback.get_current_track().get()
        return track.uri if track else None


class NoPlayer:
    """A `Player` for when there is nothing behind it.

    Answering "nothing is playing" is honest when no core was supplied, and it
    keeps `/format` returning its normal empty shape rather than a 500.
    """

    def current_track_uri(self) -> str | None:
        return None
