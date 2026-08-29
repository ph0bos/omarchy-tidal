"""Load a backend module without importing the package.

`mopidy_omarchy_tidal/__init__.py` imports mopidy, which is a full media server
and not something to install on a CI runner just to test string parsing. The
modules under test here have no mopidy dependency of their own, so they are
loaded straight from their file instead of through the package.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

_BACKEND = Path(__file__).resolve().parents[1] / "backend" / "mopidy_omarchy_tidal"


def load(name: str) -> ModuleType:
    key = f"_omarchy_tidal_{name}"
    if key in sys.modules:
        return sys.modules[key]
    spec = importlib.util.spec_from_file_location(key, _BACKEND / f"{name}.py")
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[key] = module
    spec.loader.exec_module(module)
    return module
