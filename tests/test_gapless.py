"""Gapless, without mopidy-tidal: the option, and the function that asks it.

install() reaches into mopidy-tidal for four names. Standing those in is enough
to run the rebound as_stream on a runner that has neither Mopidy nor
mopidy-tidal installed.
"""

import sys
import types

import pytest
from _backend import load
from tidalapi.media import ManifestMimeType

gapless = load("gapless")


def test_gapless_is_on_unless_the_config_says_otherwise():
    assert gapless.enabled({}) is True
    assert gapless.enabled(None) is True
    assert gapless.enabled({"omarchy_tidal": {}}) is True
    assert gapless.enabled({"omarchy_tidal": {"gapless": None}}) is True
    assert gapless.enabled({"omarchy_tidal": {"gapless": True}}) is True


def test_gapless_can_be_turned_off():
    assert gapless.enabled({"omarchy_tidal": {"gapless": False}}) is False


def test_a_config_that_cannot_be_read_leaves_gapless_on():
    assert gapless.enabled("not a mapping") is True


class _Stream:
    manifest_mime_type = ManifestMimeType.MPD
    audio_quality = "HI_RES_LOSSLESS"
    bit_depth = 24
    sample_rate = 96000

    def get_manifest_data(self):
        return "<MPD/>"


class _Track:
    id = 42

    def get_stream(self):
        return _Stream()


@pytest.fixture
def tidal(monkeypatch, tmp_path):
    seen = types.SimpleNamespace(calls=0, fail=False)

    def original(track):
        seen.calls += 1
        if seen.fail:
            raise ConnectionError("tidal is down")
        return "file:///shared/manifest.mpd"

    config = {"core": {"cache_dir": str(tmp_path)}}
    playback = types.ModuleType("mopidy_tidal.playback")
    playback.as_stream = original
    context = types.ModuleType("mopidy_tidal.context")
    context.get_config = lambda: config
    package = types.ModuleType("mopidy_tidal")
    package.Extension = types.SimpleNamespace(get_cache_dir=lambda _config: tmp_path / "tidal")
    package.context = context
    package.playback = playback
    monkeypatch.setitem(sys.modules, "mopidy_tidal", package)

    assert gapless.install() is True
    return types.SimpleNamespace(
        as_stream=playback.as_stream, config=config, seen=seen, cache=tmp_path / "tidal")


def test_by_default_each_track_gets_a_manifest_of_its_own(tidal):
    assert tidal.as_stream(_Track()) == f"file://{tidal.cache / 'manifest-42.mpd'}"
    assert tidal.seen.calls == 0


def test_turned_off_it_is_mopidy_tidals_own_function_and_nothing_else(tidal):
    tidal.config["omarchy_tidal"] = {"gapless": False}
    assert tidal.as_stream(_Track()) == "file:///shared/manifest.mpd"
    assert tidal.seen.calls == 1
    assert not list(tidal.cache.glob("manifest-*.mpd"))


def test_turned_off_a_failure_is_mopidy_tidals_to_report_and_is_not_retried(tidal, caplog):
    tidal.config["omarchy_tidal"] = {"gapless": False}
    tidal.seen.fail = True
    with pytest.raises(ConnectionError):
        tidal.as_stream(_Track())
    assert tidal.seen.calls == 1
    assert "gapless as_stream failed" not in caplog.text


def test_turned_off_it_says_so_once_and_loudly_enough_to_be_seen(tidal, caplog):
    tidal.config["omarchy_tidal"] = {"gapless": False}
    with caplog.at_level("WARNING"):
        tidal.as_stream(_Track())
        tidal.as_stream(_Track())
    assert caplog.text.count("gapless = false") == 1
