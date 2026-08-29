#!/usr/bin/env python3
"""Validate manifest.json against Omarchy's plugin manifest contract.

`omarchy plugin validate` only exists on an Omarchy machine, so CI needs an
equivalent that runs anywhere. This mirrors the checks in Omarchy's
PluginRegistry.validateManifest plus the marketplace's listing requirements.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED = ("schemaVersion", "id", "name", "version", "author", "description",
            "kinds", "entryPoints")
VALID_KINDS = {"bar-widget", "panel", "overlay", "menu", "service", "bar"}
# entryPoints is keyed by kind, except bar-widget which the host looks up as
# "barWidget" (shell.qml: entryPointUrl(manifest, "barWidget")).
KIND_TO_ENTRY = {"bar-widget": "barWidget", "panel": "panel", "overlay": "overlay",
                 "menu": "menu", "service": "service", "bar": "bar"}


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    path = root / "manifest.json"
    errors: list[str] = []

    if not path.is_file():
        print(f"error: {path} not found")
        return 1

    try:
        manifest = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        print(f"error: manifest.json is not valid JSON: {exc}")
        return 1

    if not isinstance(manifest, dict):
        print("error: manifest.json must be an object")
        return 1

    for field in REQUIRED:
        if field not in manifest:
            fail(errors, f"missing required field: {field}")

    if manifest.get("schemaVersion") != 1:
        fail(errors, "schemaVersion must be 1")

    plugin_id = str(manifest.get("id", ""))
    if "." not in plugin_id:
        fail(errors, f"id must be namespaced (e.g. author.plugin): {plugin_id!r}")

    kinds = manifest.get("kinds")
    if not isinstance(kinds, list) or not kinds:
        fail(errors, "kinds must be a non-empty array")
    else:
        for kind in kinds:
            if kind not in VALID_KINDS:
                fail(errors, f"unknown kind: {kind!r}")

    entry_points = manifest.get("entryPoints")
    if not isinstance(entry_points, dict):
        fail(errors, "entryPoints must be an object")
    else:
        for value in entry_points.values():
            text = str(value)
            # Mirrors PluginRegistry.isSafeEntryPoint.
            if text.startswith("/") or ".." in text or text == "":
                fail(errors, f"unsafe entry point: {text!r}")
            elif not (root / text).is_file():
                fail(errors, f"entry point does not exist: {text}")

        # Every declared kind needs a file to load.
        for kind in (kinds if isinstance(kinds, list) else []):
            key = KIND_TO_ENTRY.get(kind)
            if key and key not in entry_points:
                fail(errors, f"kind {kind!r} declared but entryPoints.{key} is missing")

    # Marketplace listing expectations.
    for field in ("license",):
        if not manifest.get(field):
            fail(errors, f"marketplace listing wants a {field} field")
    if not (root / "README.md").is_file():
        fail(errors, "marketplace listing requires README.md")
    if not any((root / n).is_file() for n in ("LICENSE", "LICENSE.md", "COPYING")):
        fail(errors, "marketplace listing requires a LICENSE file")

    version = str(manifest.get("version", ""))
    if len(version) > 64:
        fail(errors, "version must be 64 characters or fewer")

    if errors:
        for message in errors:
            print(f"error: {message}")
        return 1

    print(f"ok: {plugin_id} v{version} — {len(kinds)} kinds, "
          f"{len(entry_points)} entry points")
    return 0


if __name__ == "__main__":
    sys.exit(main())
