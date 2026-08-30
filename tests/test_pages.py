"""Which personalised page a /home request means."""

from __future__ import annotations

from _backend import load

pages = load("pages")


def test_named_pages_map_to_one_getter_each():
    assert pages.home_pages("home") == ("home",)
    assert pages.home_pages("for_you") == ("for_you",)


def test_both_is_the_default_and_the_old_behaviour():
    assert pages.home_pages("both") == ("home", "for_you")
    assert pages.home_pages("") == ("home", "for_you")
    assert pages.home_pages(None) == ("home", "for_you")


def test_an_unknown_page_answers_with_everything_rather_than_erroring():
    assert pages.home_pages("front") == ("home", "for_you")
    assert pages.home_pages("../etc/passwd") == ("home", "for_you")


def test_the_argument_is_read_leniently():
    assert pages.home_pages("  For_You  ") == ("for_you",)
    assert pages.home_pages("HOME") == ("home",)
