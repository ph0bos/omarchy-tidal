"""Mopidy-Omarchy-Tidal.

A companion extension for the Omarchy Tidal plugin. It adds the handful of
Tidal capabilities Mopidy's core API does not model -- lyrics, the personalised
home page, radio seeds, favourites, and the negotiated stream format -- as plain
HTTP endpoints under /omarchy-tidal/.

It runs in-process with mopidy-tidal so it can reuse that extension's
authenticated tidalapi session instead of asking the user to log in twice.
"""

from __future__ import annotations

import pathlib

from mopidy import config, ext

__version__ = "0.1.0"


class Extension(ext.Extension):
    dist_name = "Mopidy-Omarchy-Tidal"
    ext_name = "omarchy_tidal"
    version = __version__

    def get_default_config(self) -> str:
        return config.read(pathlib.Path(__file__).parent / "ext.conf")

    def get_config_schema(self):
        schema = super().get_config_schema()
        schema["lrclib_fallback"] = config.Boolean(optional=True)
        schema["gapless"] = config.Boolean(optional=True)
        return schema

    def setup(self, registry) -> None:
        from . import gapless, http  # noqa: PLC0415 - deferred so config errors surface first

        # The app name becomes the URL prefix: /omarchy-tidal/<endpoint>.
        registry.add("http:app", {"name": "omarchy-tidal", "factory": http.factory})

        # Hi-res tracks arrive as MPEG-DASH and mopidy-tidal writes every
        # manifest to one shared file, which collides at every track boundary.
        # See gapless.py for the full explanation.
        gapless.install()
