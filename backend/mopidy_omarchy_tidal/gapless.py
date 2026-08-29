"""Gapless playback for hi-res TIDAL streams.

Hi-res tracks are delivered as MPEG-DASH, and mopidy-tidal writes every
manifest to one shared filename:

    mpd_path = Path(get_cache_dir(config), "manifest.mpd")
    return f"file://{mpd_path}"

GStreamer's `about-to-finish` fires while the current track is still playing, so
resolving the next track overwrites the manifest the current one is still
reading. The result is a stall at every hi-res track boundary, tracks that
report as "infinite source", and seeking that silently stops playback.

Giving each track its own manifest file removes the collision. This patches
`mopidy_tidal.playback.as_stream` in place -- our extension is loaded into the
same process, so this is a live rebinding rather than a fork of mopidy-tidal.

It is deliberately defensive: any change in mopidy-tidal's internals leaves the
original function untouched and gapless simply stays off.
"""

from __future__ import annotations

import logging
import time
from pathlib import Path

logger = logging.getLogger(__name__)

# Manifests older than this are removed on each resolve; they are only needed
# for the lifetime of the track that references them.
_MANIFEST_TTL_SECONDS = 3600

_PATCHED_FLAG = "_omarchy_tidal_gapless"


def _prune(cache_dir: Path) -> None:
    cutoff = time.time() - _MANIFEST_TTL_SECONDS
    try:
        for stale in cache_dir.glob("manifest-*.mpd"):
            if stale.stat().st_mtime < cutoff:
                stale.unlink(missing_ok=True)
    except OSError:
        pass


def install() -> bool:
    """Rebind as_stream so each DASH manifest gets its own file.

    Returns True when gapless is active.
    """
    try:
        from mopidy_tidal import Extension as TidalExtension
        from mopidy_tidal import context
        from mopidy_tidal import playback as tidal_playback
        from tidalapi.media import ManifestMimeType
    except Exception:
        logger.warning("mopidy-tidal internals not as expected; gapless not enabled")
        return False

    if getattr(tidal_playback, _PATCHED_FLAG, False):
        return True

    original = getattr(tidal_playback, "as_stream", None)
    if original is None:
        logger.warning("mopidy_tidal.playback.as_stream is missing; gapless not enabled")
        return False

    def as_stream(track):
        try:
            stream = track.get_stream()
            if stream.manifest_mime_type != ManifestMimeType.MPD:
                # BTS streams are plain URLs and never collided in the first place.
                return original(track)

            data = stream.get_manifest_data()
            if not data:
                return original(track)

            cache_dir = Path(TidalExtension.get_cache_dir(context.get_config()))
            cache_dir.mkdir(parents=True, exist_ok=True)
            _prune(cache_dir)

            # One manifest per track: the next track can be prepared while the
            # current one is still reading its own file.
            path = cache_dir / f"manifest-{track.id}.mpd"
            tmp = path.with_suffix(".mpd.tmp")
            tmp.write_text(data)
            tmp.replace(path)

            logger.debug(
                "gapless manifest for track %s (%s %sbit/%sHz)",
                track.id, stream.audio_quality, stream.bit_depth, stream.sample_rate,
            )
            return f"file://{path}"
        except Exception:
            logger.exception("gapless as_stream failed; falling back to mopidy-tidal")
            return original(track)

    tidal_playback.as_stream = as_stream
    setattr(tidal_playback, _PATCHED_FLAG, True)
    logger.info("Omarchy TIDAL: per-track DASH manifests enabled (gapless hi-res)")
    return True
