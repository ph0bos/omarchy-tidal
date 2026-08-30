#!/usr/bin/env python3
"""Every async callback that touches the component must check `alive` first.

Saving a file under ~/.config/omarchy/plugins/ hot-reloads plugin code, which
destroys live objects while HTTP callbacks and timers may still be in flight. A
callback that then reads or writes a property is a use-after-free, and
Quickshell turns that into a fatal abort -- it takes the whole shell down, not
just this plugin.

The rule this enforces: a function literal passed to one of the async helpers
(Rpc.* or Tidal.*) may not mention `root.` before it has mentioned `alive`.
Callbacks that touch nothing are fine, and so is any line carrying an
`async-guard: ok` comment for the cases where the rule genuinely does not apply.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

CALL = re.compile(r"\b(?:Rpc|Tidal)\.\w+\(")
OPENS_CALLBACK = re.compile(r"function\s*\([^)]*\)\s*\{\s*$")
ESCAPE = "async-guard: ok"


def offenders(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").split("\n")
    found = []
    for index, line in enumerate(lines):
        if not OPENS_CALLBACK.search(line):
            continue
        # Only callbacks handed to the async helpers: a plain handler that runs
        # inline cannot outlive anything.
        window = "\n".join(lines[max(0, index - 4):index + 1])
        if not CALL.search(window):
            continue
        if ESCAPE in line:
            continue

        depth = 0
        for offset, body in enumerate(lines[index:]):
            depth += body.count("{") - body.count("}")
            if offset > 0:
                if ESCAPE in body:
                    break
                if "alive" in body:
                    break
                if "root." in body:
                    found.append((index + offset + 1, body.strip()))
                    break
            if depth <= 0:
                break
    return found


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    failures = 0
    for path in sorted(root.glob("qml/**/*.qml")):
        for line, text in offenders(path):
            print(f"::error file={path},line={line}::async callback touches "
                  f"the component before checking alive: {text[:70]}")
            failures += 1
    if failures:
        print(f"\n{failures} unguarded async callback(s). A callback that runs after a "
              f"hot reload and touches this object takes the shell down with it.")
        return 1
    print("ok: every async callback checks alive before it touches anything")
    return 0


if __name__ == "__main__":
    sys.exit(main())
