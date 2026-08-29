# Contributing

Thanks for taking a look. This is an Omarchy shell plugin plus a small Mopidy
extension, so contributions land in one of two places.

## Getting set up

```bash
git clone https://github.com/ph0bos/omarchy-tidal.git
cd omarchy-tidal
./bin/omarchy-tidal-setup all        # backend, PipeWire rates, TIDAL sign-in
ln -s "$PWD" ~/.config/omarchy/plugins/quickshell.tidal
omarchy plugin enable quickshell.tidal
```

**The file watcher does not follow symlinks.** Editing through the symlink
above appears to do nothing — the shell keeps serving the QML it loaded first,
and `rescanPlugins` does not help. Use `omarchy restart shell`. This is the
single most common way to lose an hour on this codebase.

## Before opening a pull request

```bash
python3 scripts/validate-manifest.py .   # what the marketplace checks
python3 -m pytest tests -q               # backend
node --test tests/js.test.mjs            # QML JavaScript
omarchy plugin validate .                # on an Omarchy host
```

QML lint, against the shell's own modules:

```bash
mkdir -p /tmp/qsimports && ln -sfn /usr/share/omarchy/shell /tmp/qsimports/qs
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I /tmp/qsimports qml/**/*.qml
```

`Member ... not found on type "QObject"` and `Unqualified access` are expected —
the injected `bar` and the `Style`/`Color` singletons are untyped, and Omarchy's
own widgets produce hundreds of the same warnings. Anything else is worth
looking at.

## House rules

**Write Nerd Font glyphs as `\uXXXX` escapes.** Private-use codepoints get
silently stripped when a file is written through a shell heredoc, and the
failure mode is an invisible icon rather than an error. CI checks for this.

**Guard async callbacks.** Saving a file hot-reloads plugin code and destroys
live objects. An HTTP callback or timer that then writes a property is a
use-after-free, and Quickshell turns that into a fatal abort that takes the
whole shell down. Every async completion checks `root.alive` first.

**Derive from the argument, not from a binding, inside a change handler.**
`onFooChanged` runs before dependent bindings re-evaluate, so a `readonly
property` computed from `foo` still describes the *previous* value at that
point.

**Explain why, not what.** The comments that earn their place here are the ones
recording a constraint that is not visible in the code — why manifests are
written per-track, why the timeline runs off a wall clock, why the seek bar is
anchored rather than laid out in a Row.

## Reporting a bug

`omarchy-tidal-setup check` and `omarchy-shell tidal status` between them cover
most of what a report needs. Include both.
