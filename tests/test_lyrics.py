"""LRC parsing: what drives the synced-lyrics highlight."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from mopidy_omarchy_tidal.lyrics import parse_lrc  # noqa: E402


def test_parses_centiseconds():
    lines = parse_lrc("[00:13.48]Well, are you gonna dance")
    assert lines == [{"time_ms": 13480, "text": "Well, are you gonna dance"}]


def test_parses_milliseconds():
    assert parse_lrc("[00:13.480]x")[0]["time_ms"] == 13480


def test_colon_fraction_separator():
    assert parse_lrc("[01:02:50]x")[0]["time_ms"] == 62500


def test_no_fraction():
    assert parse_lrc("[02:05]x")[0]["time_ms"] == 125000


def test_repeated_stamps_expand_to_one_entry_each():
    lines = parse_lrc("[00:10.00][01:10.00]Chorus")
    assert [l["time_ms"] for l in lines] == [10000, 70000]
    assert all(l["text"] == "Chorus" for l in lines)


def test_output_is_sorted_by_time():
    lines = parse_lrc("[00:30.00]late\n[00:10.00]early")
    assert [l["time_ms"] for l in lines] == [10000, 30000]


def test_lines_without_stamps_are_dropped():
    assert parse_lrc("[ar:Artist]\n[00:01.00]real") == [{"time_ms": 1000, "text": "real"}]


def test_empty_and_none():
    assert parse_lrc("") == []
    assert parse_lrc(None) == []
