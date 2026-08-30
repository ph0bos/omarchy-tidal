#!/usr/bin/env bash
# Resident memory of the shell with this plugin in it, measured the same way
# every time.
#
# `ps -o rss` against the live shell, found through `qs list --all` rather than
# by matching a command line -- that also matches the shell running the
# measurement, which reports a very reassuring 5 MB.
#
# Three samples per run:
#
#   baseline  plugin loaded, no surface ever opened
#   peak      after home, the library grid and now playing have been drawn
#   rest      after the panel closes and the idle release has had its turn
#
# Run-to-run variance on identical code is around 8 MB, so a single run proves
# nothing. Take three of each and compare the medians; a 2 MB "improvement" is
# noise and costs an hour to chase.
#
#   scripts/measure-memory.sh [seconds-to-rest]

set -euo pipefail

rest_wait="${1:-40}"

shell_pid() {
  qs list --all 2>/dev/null | awk '/Process ID:/ { print $3; exit }'
}

sample() {
  local pid="$1"
  ps -o rss= -p "$pid" 2>/dev/null | awk '{ printf "%.0f", $1 / 1024 }'
}

echo "restarting the shell"
omarchy restart shell >/dev/null 2>&1
for _ in $(seq 1 90); do
  omarchy-shell tidal ping >/dev/null 2>&1 && break
  sleep 0.5
done

pid="$(shell_pid)"
[ -z "$pid" ] && { echo "no shell found" >&2; exit 1; }
sleep 6
echo "baseline  $(sample "$pid") MB   (pid $pid)"

omarchy-shell tidal overlay >/dev/null 2>&1
sleep 6
omarchy-shell tidal nowPlaying >/dev/null 2>&1
sleep 5
omarchy-shell tidal info >/dev/null 2>&1
sleep 5
echo "peak      $(sample "$pid") MB"

# Close it. `toggle`, not another summon: summoning an already-open panel is a
# no-op, so closing it this way is the difference between measuring a closed
# panel and measuring an open one you thought was closed.
omarchy-shell shell toggle quickshell.tidal >/dev/null 2>&1
sleep "$rest_wait"
echo "rest      $(sample "$pid") MB   (after ${rest_wait}s closed)"

mopidy_pid="$(systemctl --user show -p MainPID --value mopidy 2>/dev/null || true)"
if [ -n "$mopidy_pid" ] && [ "$mopidy_pid" != "0" ]; then
  echo "mopidy    $(sample "$mopidy_pid") MB"
fi
