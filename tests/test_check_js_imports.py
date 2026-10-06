"""check-js-imports must not be talked out of a missing import by a comment.

The script blanks comments and strings before it looks for uses of a namespace.
Each case here is a way that blanking once swallowed real code, and with it the
use the check exists to find.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "check-js-imports.py"
_spec = importlib.util.spec_from_file_location("check_js_imports", SCRIPT)
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)


def run(tmp_path, source: str) -> int:
    qml = tmp_path / "qml"
    qml.mkdir()
    (qml / "Thing.qml").write_text(source, encoding="utf-8")
    return check.main(str(tmp_path))


USE = "Item { Behavior on x { NumberAnimation { duration: Design.fast } } }\n"
IMPORT = 'import "lib/Design.js" as Design\n'


def test_a_use_without_its_import_fails(tmp_path):
    assert run(tmp_path, "import QtQuick\n" + USE) == 1


def test_a_use_with_its_import_passes(tmp_path):
    assert run(tmp_path, "import QtQuick\n" + IMPORT + USE) == 0


def test_an_apostrophe_in_a_comment_does_not_open_a_string(tmp_path):
    source = (
        "import QtQuick\n"
        "// the view's own handler\n"
        + USE
        + "// and the list's, further down\n"
    )
    assert run(tmp_path, source) == 1


def test_a_block_opener_in_a_line_comment_does_not_open_a_comment(tmp_path):
    source = (
        "import QtQuick\n"
        "// the constants live in lib/*.js\n"
        + USE
        + "/* a real block comment, later in the file */\n"
    )
    assert run(tmp_path, source) == 1


def test_a_url_in_a_string_does_not_start_a_comment(tmp_path):
    source = (
        "import QtQuick\n"
        'Item { property string home: "https://tidal.com"; '
        "property int d: Design.fast }\n"
    )
    assert run(tmp_path, source) == 1


def test_a_namespace_named_in_a_comment_or_a_string_is_not_a_use(tmp_path):
    source = (
        "import QtQuick\n"
        "// Design.fast is the short one\n"
        "/* Design.base\n   is the middle one */\n"
        'Item { property string note: "Design.slow" }\n'
    )
    assert run(tmp_path, source) == 0


def test_blanking_keeps_line_numbers():
    text = "a\n/* one\n two */\nb // c\n'd'\n"
    assert check.code_only(text).count("\n") == text.count("\n")
