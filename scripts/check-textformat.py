#!/usr/bin/env python3
"""Every `Text` element must set `textFormat`.

QML's Text defaults to `Text.AutoText`, which sniffs its content and promotes
anything that looks like markup to rich text. Most of what this plugin displays
is catalogue data from TIDAL -- track, artist, album and playlist names the user
did not author -- and rich text can reference remote resources, which would make
the shell fetch them.

Nothing here wants rich text, so every Text says so explicitly. This is the
check that keeps that true: a reviewer should be able to establish it by
grepping, and a new Text element should not be able to slip through without it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPENS = re.compile(r"^(\s*)(?:delegate:\s*|sourceComponent:\s*)?Text\s*\{\s*$")


def missing_in(path: Path) -> list[int]:
    """Line numbers of Text blocks with no textFormat before their closing brace."""
    lines = path.read_text(encoding="utf-8").split("\n")
    missing = []
    for index, line in enumerate(lines):
        opened = OPENS.match(line)
        if not opened:
            continue
        # Walk to the matching close, tracking depth so a nested block's
        # properties are not mistaken for this one's.
        depth = 0
        found = False
        for candidate in lines[index:]:
            depth += candidate.count("{") - candidate.count("}")
            if depth == 1 and re.match(r"^\s*textFormat\s*:", candidate):
                found = True
                break
            if depth <= 0:
                break
        if not found:
            missing.append(index + 1)
    return missing


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    failures = 0
    checked = 0
    for path in sorted(root.glob("qml/**/*.qml")):
        for line in missing_in(path):
            print(f"::error file={path},line={line}::Text without textFormat")
            failures += 1
        checked += 1
    if failures:
        print(f"{failures} Text element(s) without textFormat")
        return 1
    print(f"ok: every Text sets textFormat ({checked} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
