"""TIDAL's editorial copy carries inline markup that must never reach the UI."""

from _backend import load

clean = load("text").clean


def test_strips_wimplink_and_keeps_label():
    text, links = clean('A visionary, [wimpLink artistId="16992"]Björk[/wimpLink] sings.')
    assert text == "A visionary, Björk sings."
    assert links == [{"type": "artist", "uri": "tidal:artist:16992", "label": "Björk"}]


def test_extracts_albums_and_playlists():
    _, links = clean('[wimpLink albumId="7"]Post[/wimpLink] and '
                     '[wimpLink playlistId="a-b"]Mix[/wimpLink]')
    assert [x["uri"] for x in links] == ["tidal:album:7", "tidal:playlist:a-b"]


def test_deduplicates_repeated_references():
    _, links = clean('[wimpLink artistId="1"]A[/wimpLink] then '
                     '[wimpLink artistId="1"]A[/wimpLink] again')
    assert len(links) == 1


def test_removes_unknown_tags_entirely():
    text, _ = clean("Before [somethingElse attr='x']inner[/somethingElse] after")
    assert "[" not in text and "]" not in text


def test_normalises_windows_newlines_and_blank_runs():
    text, _ = clean("One\r\n\r\n\r\n\r\nTwo")
    assert text == "One\n\nTwo"


def test_empty_input_is_safe():
    assert clean(None) == ("", [])
    assert clean("") == ("", [])


def test_multiline_label_inside_tag():
    text, links = clean('[wimpLink artistId="2"]Two\nWords[/wimpLink]')
    assert "Two\nWords" in text
    assert links[0]["label"] == "Two\nWords"
