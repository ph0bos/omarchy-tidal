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

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")
STRING = re.compile(r"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'")


def code_only(text: str) -> str:
    """The file with comments and string literals blanked out.

    A namespace named in a comment is not a use, and neither is one inside a
    string -- both produced false positives the first time this ran.

    Strings go first, and that order is the whole correctness of this
    function: strip line comments first and a URL in a QML string ("https://
    ...") loses everything from its `//` to the end of the line, including its
    closing quote. The next quote in the file then pairs with the wrong one
    and blanks whole functions -- which is exactly how the first version of
    this check passed a file it should have failed.
    """
    text = STRING.sub('""', text)
    text = BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    return LINE_COMMENT.sub("", text)


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
