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


def enabled(config) -> bool:
    """Whether `[omarchy_tidal] gapless` is on. On unless it says otherwise.

    Read each time a track is resolved rather than once at startup: an
    extension's `setup()` is not handed the config, and the option was in the
    schema and the defaults for a long time without anything reading it.
    """
    try:
        section = (config or {}).get("omarchy_tidal") or {}
        value = section.get("gapless")
    except Exception:
        return True
    return True if value is None else bool(value)


def install() -> bool:
    """Rebind as_stream so each DASH manifest gets its own file.

    Returns True when the patch is in place. Whether it is then used is
    `enabled()`'s question, asked per track.
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
            wanted = enabled(context.get_config())
        except Exception:
            wanted = True
        if not wanted:
            # Said once, and as a warning: Mopidy shows nothing quieter by
            # default, and this is the only sign that the option was honoured.
            if not getattr(as_stream, "said_off", False):
                as_stream.said_off = True
                logger.warning(
                    "Omarchy TIDAL: [omarchy_tidal] gapless = false, so streams are "
                    "resolved by mopidy-tidal unchanged; expect a stall where one "
                    "hi-res track meets the next")
            # Outside the try below: with gapless off, what mopidy-tidal does
            # and what it raises are its own, once, and not ours to report.
            return original(track)
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
    # "Ready", not "enabled": whether it is used is the config's to say, and
    # that is read per track. Someone who has turned gapless off should not be
    # told at startup that it is on.
    logger.info("Omarchy TIDAL: per-track DASH manifests ready (gapless hi-res, "
                "unless [omarchy_tidal] gapless = false)")
    return True
