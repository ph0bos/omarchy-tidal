"""Turning a container into the tracks it means.

`/playlist` fetches a page's worth of tracks so the view has something to draw.
Playing one means all of it, however long it is, so this is a separate walk to
the end of the playlist rather than the same call with a bigger limit.

Kept out of `http.py` because that module imports tornado and its siblings, and
this is plain iteration worth testing on its own.
"""

from __future__ import annotations

_PAGE = 100


def _safe(fn, default=None):
    """tidalapi raises for absent optional metadata; treat that as "not there"."""
    try:
        return fn()
    except Exception:
        return default


def playlist_items(playlist) -> list:
    """Every item in a playlist, in order.

    `tracks_paginated()` is tidalapi's own loop over the offset form. Older
    releases only have `tracks(limit, offset)`, and paging by hand is cheaper
    than requiring a version for one method.
    """
    items = _safe(playlist.tracks_paginated)
    if items is not None:
        return list(items)

    items = []
    offset = 0
    while True:
        # Bind the offset: the lambda is called before the next iteration,
        # but a free variable in a loop is a bug waiting for the day it is not.
        page = _safe(lambda at=offset: playlist.tracks(limit=_PAGE, offset=at), []) or []
        items.extend(page)
        if len(page) < _PAGE:
            return items
        offset += len(page)


def track_uris(items) -> list[str]:
    """The uris Mopidy can play, in order.

    A playlist can hold videos too, and those have no stream Mopidy takes.
    Leaving one out is better than queueing something that fails at the
    boundary, which reads as the playlist stopping halfway.
    """
    uris = []
    for item in items or []:
        if type(item).__name__.lower() != "track":
            continue
        ident = getattr(item, "id", None)
        if ident is not None:
            uris.append(f"tidal:track:{ident}")
    return uris


def playlist_track_uris(playlist) -> list[str]:
    return track_uris(playlist_items(playlist))
