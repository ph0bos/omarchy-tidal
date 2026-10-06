#!/usr/bin/env python3
"""Every JS namespace a QML file uses must be imported in that file.

qmllint does not catch this. A QML file that says `Design.clock(...)` without
`import "../lib/Design.js" as Design` passes every check we have and then fails
at runtime with `ReferenceError: Design is not defined` -- but only on the code
path that touches it, which can be a view nobody opens during a smoke test.
This has bitten twice: SetupWizard calling into TidalApi, and Service using
Quickshell.env. So it is a check.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# alias -> the module file the alias must come from
ALIASES = {
    "Design": "Design.js",
    "Library": "Library.js",
    "Lrc": "Lrc.js",
    "Rpc": "MopidyRpc.js",
    "Tidal": "TidalApi.js",
}

# One pass, left to right, taking whichever of these starts first. Three
# separate passes cannot be ordered correctly: each kind can contain the opening
# of another, and whichever is stripped first eats into the ones after it.
#
#   - an apostrophe in a comment -- "the view's own handler" -- opened a
#     "string" that ran to the next apostrophe anywhere in the file, and blanked
#     every use of a namespace between the two;
#   - a `/*` in a line comment -- "see lib/*.js" -- opened a block comment that
#     ran to the next `*/` in the file;
#   - a `//` in a string -- "https://..." -- cut the line off before its closing
#     quote.
#
# A quoted string ends on the line it began.
TOKEN = re.compile(
    r"""
      //[^\n]*                      # line comment
    | /\*.*?\*/                     # block comment
    | "(?:[^"\\\n]|\\.)*"           # double-quoted string
    | '(?:[^'\\\n]|\\.)*'           # single-quoted string
    | `(?:[^`\\]|\\.)*`             # template literal, which may span lines
    """,
    re.S | re.X,
)


def code_only(text: str) -> str:
    """The file with comments and string literals blanked out.

    A namespace named in a comment is not a use, and neither is one inside a
    string -- both produced false positives the first time this ran. Line
    breaks are kept, so what is left still has the line numbers it had.
    """

    def blank(match: re.Match) -> str:
        token = match.group(0)
        lines = "\n" * token.count("\n")
        return lines if token.startswith("/") else '""' + lines

    return TOKEN.sub(blank, text)


def main(root: str = ".") -> int:
    base = Path(root)
    failures = []
    checked = 0
    for path in sorted(base.glob("qml/**/*.qml")):
        source = path.read_text(encoding="utf-8")
        body = code_only(source)
        checked += 1
        for alias, module in ALIASES.items():
            used = re.search(rf"\b{alias}\.[A-Za-z_]", body)
            if not used:
                continue
            imported = re.search(
                rf'^\s*import\s+"[^"]*{re.escape(module)}"\s+as\s+{alias}\s*$',
                source,
                re.M,
            )
            if not imported:
                failures.append(f"{path}: uses {alias}.* but does not import {module}")

    if failures:
        for line in failures:
            print(line, file=sys.stderr)
        return 1
    print(f"ok: every JS namespace used is imported ({checked} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
