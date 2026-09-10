"""Load a backend module without importing the package.

`mopidy_omarchy_tidal/__init__.py` imports mopidy, which is a full media server
and not something to install on a CI runner just to test string parsing. The
modules under test here have no mopidy dependency of their own, so they are
loaded straight from their file instead of through the package.

`load()` is enough for a module that imports nothing from its siblings. `http`
does -- `from . import expand`, and five more -- and a relative import needs a
parent package to resolve against, which loading a bare file does not give it.
`load_pkg()` supplies one: a synthetic package whose `__path__` points at the
backend directory, so the siblings resolve normally while `__init__.py`, and
therefore mopidy, is never executed.
"""

from __future__ import annotations

import importlib
import importlib.machinery
import importlib.util
import sys
from pathlib import Path
from types import ModuleType

_BACKEND = Path(__file__).resolve().parents[1] / "backend" / "mopidy_omarchy_tidal"

# Deliberately not the real package name: shadowing it would mean a test that
# imported the real thing got this one instead, silently.
_PKG = "_omarchy_tidal_pkg"


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


def _parent() -> ModuleType:
    """A package rooted at the backend directory, minus its `__init__`."""
    existing = sys.modules.get(_PKG)
    if existing is not None:
        return existing
    spec = importlib.machinery.ModuleSpec(_PKG, None, is_package=True)
    module = importlib.util.module_from_spec(spec)
    # submodule_search_locations is what `from . import x` walks.
    module.__path__ = [str(_BACKEND)]
    sys.modules[_PKG] = module
    return module


def load_pkg(name: str) -> ModuleType:
    """Load a backend module that imports its siblings."""
    _parent()
    return importlib.import_module(f"{_PKG}.{name}")
