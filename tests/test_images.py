"""Cover art and entity resolution.

The session is faked: these exercise our URI parsing, payload shaping and disk
cache, not tidalapi.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from _backend import load

images = load("images")


class FakeArtist:
    name = "GUNSHIP"

    def image(self, size):
        return f"https://resources.tidal.com/artist/{size}.jpg"


class FakeAlbum:
    name = "Dark All Day"
    num_tracks = 13
    media_metadata_tags = ["HIRES_LOSSLESS"]
    artist = FakeArtist()

    class release_date:
        year = 2018

    def image(self, size):
        return f"https://resources.tidal.com/album/{size}.jpg"


class FakeTrack:
    name = "Woken Furies"
    duration = 307
    is_hi_res_lossless = False
    album = FakeAlbum()
    artists = [FakeArtist()]


class FakeSession:
    def track(self, ident):
        return FakeTrack()

    def album(self, ident):
        return FakeAlbum()

    def artist(self, ident):
        return FakeArtist()


@pytest.fixture(autouse=True)
def clear_cache():
    images.forget_all()
    yield
    images.forget_all()


def test_split_takes_the_id_from_both_uri_shapes():
    assert images.split("tidal:track:91367052") == ("track", "91367052")
    assert images.split("tidal:track:6853265:91367051:91367052") == ("track", "91367052")
    assert images.split("tidal:album:114331950") == ("album", "114331950")


def test_split_rejects_what_it_cannot_resolve():
    assert images.split("") is None
    assert images.split("spotify:track:123") is None
    assert images.split("tidal:track") is None


def test_describe_album_carries_what_a_row_needs():
    payload = images.describe(FakeSession(), "tidal:album:1")
    assert payload["name"] == "Dark All Day"
    assert payload["artist"] == "GUNSHIP"
    assert payload["year"] == 2018
    assert payload["hires"] is True
    assert payload["image"].endswith("/320.jpg")


def test_describe_track_borrows_its_albums_sleeve():
    payload = images.describe(FakeSession(), "tidal:track:1")
    assert payload["album"] == "Dark All Day"
    assert payload["image"] == "https://resources.tidal.com/album/320.jpg"


def test_describe_passes_the_requested_size_through():
    payload = images.describe(FakeSession(), "tidal:album:1", size=640)
    assert payload["image"].endswith("/640.jpg")


def test_describe_survives_a_session_that_raises():
    class Broken:
        def album(self, ident):
            raise RuntimeError("network gone")

    assert images.describe(Broken(), "tidal:album:1") is None
    assert images.resolve(Broken(), "tidal:album:1") is None


def test_resolve_is_just_the_image_from_describe():
    assert images.resolve(FakeSession(), "tidal:artist:1") == \
        "https://resources.tidal.com/artist/320.jpg"


def test_cache_remembers_a_miss_as_well_as_a_hit():
    assert images.cached("k") == (False, None)
    images.remember("k", None)
    assert images.cached("k") == (True, None)
    images.remember("k", {"name": "x"})
    assert images.cached("k") == (True, {"name": "x"})


def test_cache_dir_follows_xdg():
    assert images.cache_dir({"XDG_CACHE_HOME": "/x"}) == Path("/x/omarchy-tidal/art")
    assert images.cache_dir({"HOME": "/home/who"}) == Path("/home/who/.cache/omarchy-tidal/art")


def test_path_for_fans_out_and_is_stable(tmp_path):
    first = images.path_for("key", tmp_path)
    assert first == images.path_for("key", tmp_path)
    assert first != images.path_for("other", tmp_path)
    assert first.parent.parent == tmp_path
    assert len(first.parent.name) == 2


def test_write_atomic_leaves_no_partial_file(tmp_path):
    path = images.path_for("k", tmp_path, ".jpg")
    images.write_atomic(path, b"bytes")
    assert path.read_bytes() == b"bytes"
    assert list(tmp_path.rglob("*.part")) == []


def test_prune_drops_the_coldest_files_first(tmp_path):
    for i in range(4):
        path = images.path_for(f"k{i}", tmp_path, ".jpg")
        images.write_atomic(path, b"x" * 1000)
        os.utime(path, (i, i))

    freed = images.prune(tmp_path, max_bytes=2000)

    assert freed == 2000
    left = sorted(p.stat().st_size for p in tmp_path.rglob("*.jpg"))
    assert left == [1000, 1000]


def test_prune_leaves_a_cache_that_already_fits(tmp_path):
    images.write_atomic(images.path_for("k", tmp_path, ".jpg"), b"x" * 10)
    assert images.prune(tmp_path, max_bytes=1000) == 0


def test_prune_copes_with_a_cache_that_does_not_exist(tmp_path):
    assert images.prune(tmp_path / "nothing-here") == 0


# ---- palette ---------------------------------------------------------------

palette = load("palette")


def test_luminance_spans_black_to_white():
    assert palette.relative_luminance((0, 0, 0)) == 0
    assert palette.relative_luminance((255, 255, 255)) == 1
    assert palette.contrast_ratio((255, 255, 255), (0, 0, 0)) == 21


def test_a_greyscale_sleeve_has_no_colour():
    # Bring Me The Horizon's L.I.V.E. cover is black shapes on white; tinting
    # the interface grey would be worse than leaving the theme alone.
    pixels = [(250, 250, 250)] * 200 + [(12, 12, 12)] * 56
    result = palette.analyse_pixels(pixels)
    assert result["color"] is None
    assert result["isLight"] is True


def test_a_coloured_sleeve_reports_its_hue():
    result = palette.analyse_pixels([(230, 120, 30)] * 180 + [(20, 20, 20)] * 76)
    assert result["color"].startswith("#")
    hue, saturation, value = palette.to_hsv(
        tuple(int(result["color"][i:i + 2], 16) for i in (1, 3, 5)))
    assert 20 < hue < 45          # still orange
    assert saturation >= 0.55     # lifted into a usable accent
    assert result["isLight"] is False


def test_the_dominant_hue_wins_rather_than_the_average():
    # Half red, half blue: averaging gives purple, a colour in neither half.
    pixels = [(220, 40, 40)] * 140 + [(40, 60, 220)] * 116
    hue, _, _ = palette.to_hsv(
        tuple(int(palette.analyse_pixels(pixels)["color"][i:i + 2], 16) for i in (1, 3, 5)))
    assert hue < 30 or hue > 330  # red, not purple


def test_hsv_round_trips():
    for rgb in [(230, 120, 30), (40, 60, 220), (12, 200, 90)]:
        hue, saturation, value = palette.to_hsv(rgb)
        assert max(abs(a - b) for a, b in zip(palette.from_hsv(hue, saturation, value), rgb, strict=True)) <= 2


def test_analyse_pixels_copes_with_nothing():
    assert palette.analyse_pixels([])["color"] is None
