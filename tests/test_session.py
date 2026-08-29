"""URI parsing. mopidy-tidal emits two shapes for the same track."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from mopidy_omarchy_tidal.session import entity_id, track_id  # noqa: E402


def test_short_track_uri():
    assert track_id("tidal:track:12345") == "12345"


def test_long_track_uri_takes_the_last_segment():
    assert track_id("tidal:track:1134:20505823:20505835") == "20505835"


def test_rejects_other_schemes_and_shapes():
    assert track_id("tidal:album:1") is None
    assert track_id("spotify:track:1") is None
    assert track_id("tidal:track:1:2") is None      # four parts is not a shape
    assert track_id("") is None
    assert track_id(None) is None


def test_entity_ids():
    assert entity_id("tidal:artist:16992", "artist") == "16992"
    assert entity_id("tidal:album:341273436", "album") == "341273436"
    assert entity_id("tidal:artist:1", "album") is None
    assert entity_id("", "artist") is None
