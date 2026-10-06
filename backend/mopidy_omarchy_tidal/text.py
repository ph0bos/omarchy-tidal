"""Cleanup for TIDAL's editorial copy.

Bios and album reviews come back with TIDAL's own inline markup:

    [wimpLink artistId="16992"]Björk[/wimpLink]

Rendering that raw looks broken, and throwing the whole tag away loses a real
cross-reference. So the tag is reduced to its display text, and the reference is
returned alongside as a link the UI can offer.
"""

from __future__ import annotations

import re

# [wimpLink artistId="123"]Label[/wimpLink] / albumId / playlistId
_WIMP = re.compile(
    r'\[wimpLink\s+(?P<kind>artist|album|playlist)Id="(?P<id>[^"]+)"\]'
    r'(?P<label>.*?)\[/wimpLink\]',
    re.IGNORECASE | re.DOTALL,
)

# Any tag we do not recognise, so nothing bracketed leaks into the UI.
_ANY_TAG = re.compile(r"\[/?[a-zA-Z][^\]]*\]")


def clean(raw: str | None) -> tuple[str, list[dict]]:
    """Return (plain_text, links).

    links is a list of {type, uri, label} in the order they appear, so the UI
    can render "mentions" without having to parse anything itself.
    """
    if not raw:
        return "", []

    links: list[dict] = []

    def replace(match: re.Match) -> str:
        kind = match.group("kind").lower()
        label = match.group("label").strip()
        links.append({
            "type": kind,
            "uri": f"tidal:{kind}:{match.group('id')}",
            "label": label,
        })
        return label

    text = _WIMP.sub(replace, raw)
    text = _ANY_TAG.sub("", text)
    # TIDAL's copy uses \r\n and stacks blank lines; normalise to plain
    # paragraphs so the UI can just word-wrap it.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"[ \t]{2,}", " ", text)

    # De-duplicate links, keeping first appearance.
    seen = set()
    unique = []
    for link in links:
        if link["uri"] in seen:
            continue
        seen.add(link["uri"])
        unique.append(link)

    return text.strip(), unique


_UNREACHABLE = ("ConnectionError", "Timeout", "ReadTimeout", "ConnectTimeout")


def reason(exc: BaseException) -> str:
    """Why a call to Tidal failed, in words safe to put on screen.

    Never `str(exc)`: a requests error carries the url it was for, and Tidal's
    urls carry the session id. The views put their own "Could not ...:" in
    front of this, so it says why, not what.
    """
    name = type(exc).__name__
    if name == "TooManyRequests":
        return "TIDAL is limiting requests; try again shortly"
    if name == "ObjectNotFound":
        return "TIDAL has nothing by that id"
    if name == "AuthenticationError":
        return "TIDAL did not accept the session"
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if isinstance(status, int):
        return f"TIDAL answered {status}"
    if isinstance(exc, (ConnectionError, TimeoutError)) or name in _UNREACHABLE:
        return "TIDAL could not be reached"
    return "the request to TIDAL failed"
