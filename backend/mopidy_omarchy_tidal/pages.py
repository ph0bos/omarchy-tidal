"""Which of TIDAL's personalised pages a request is asking for.

Kept out of `http.py` so it can be tested: that module imports tornado, which
is a web server and not something to install on a CI runner in order to check
a lookup table.
"""

from __future__ import annotations

# Home and For You are separate pages in TIDAL's own client and separate
# entries in our sidebar. `both` is what /home answered before this argument
# existed, and remains the default so an older UI against a newer companion
# gets exactly what it used to.
HOME_PAGES: dict[str, tuple[str, ...]] = {
    "home": ("home",),
    "for_you": ("for_you",),
    "both": ("home", "for_you"),
}


def home_pages(requested: str | None) -> tuple[str, ...]:
    """The tidalapi page getters named by a `?page=` argument.

    Anything unrecognised falls back to `both` rather than erroring: a query
    string is user input, and answering a front page with a 400 is a worse
    outcome than answering it with everything.
    """
    key = (requested or "").strip().lower()
    return HOME_PAGES.get(key or "both", HOME_PAGES["both"])
