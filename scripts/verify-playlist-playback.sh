#!/usr/bin/env bash
# Verify the fix for issue #1: playlists play as a whole, not a track at a time.
#
# Run it on an Omarchy host with mopidy running and a TIDAL session saved.
# It reads; the only thing it changes is the tracklist, and only when you pass
# --play. Everything it asserts is printed, so a failure says which step.
#
#   scripts/verify-playlist-playback.sh              # diagnose only
#   scripts/verify-playlist-playback.sh --play       # also replace the queue
#
# Pass a playlist uri to test a specific one, otherwise it takes the first of
# your own playlists.
#
#   scripts/verify-playlist-playback.sh tidal:playlist:<uuid>

set -uo pipefail

RPC=http://127.0.0.1:6680/mopidy/rpc
API=http://127.0.0.1:6680/omarchy-tidal
PLAY=0
URI=""

for arg in "$@"; do
  case "$arg" in
    --play) PLAY=1 ;;
    tidal:playlist:*) URI="$arg" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m       %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAILED\033[0m   %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  ..       %s\n' "$1"; }

rpc() {
  curl -s --max-time 30 "$RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}"
}

jq_or_die() {
  command -v jq >/dev/null || { echo "this script needs jq"; exit 2; }
}
jq_or_die

echo "== reachable =="
if rpc core.get_version | grep -q result; then
  ok "mopidy JSON-RPC on :6680"
else
  bad "mopidy JSON-RPC on :6680 -- nothing else here will work"
  exit 1
fi

if curl -sf --max-time 10 "$API/health" >/dev/null; then
  ok "companion extension responding"
else
  bad "companion extension not responding at $API/health"
  exit 1
fi

echo
echo "== pick a playlist =="
if [ -z "$URI" ]; then
  URI=$(curl -s --max-time 30 "$API/playlists" | jq -r '.items[0].uri // empty')
fi
if [ -z "$URI" ]; then
  echo "  no playlist found. Pass one: $0 tidal:playlist:<uuid>"
  exit 2
fi
NAME=$(curl -s --max-time 30 "$API/playlist?uri=$URI" | jq -r '.name // "?"')
NUM=$(curl -s --max-time 30 "$API/playlist?uri=$URI" | jq -r '.num_tracks // 0')
note "$NAME ($URI, $NUM tracks)"

echo
echo "== the bug: what core.library.lookup answers for a playlist =="
LOOKUP=$(rpc core.library.lookup "{\"uris\":[\"$URI\"]}")
PLACEHOLDERS=$(echo "$LOOKUP" | jq "[.result[][] | select(.uri == \"tidal:track:0:0:0\")] | length")
REAL=$(echo "$LOOKUP" | jq "[.result[][] | select(.uri != \"tidal:track:0:0:0\")] | length")
note "$REAL real track(s), $PLACEHOLDERS placeholder(s)"
if [ "$PLACEHOLDERS" -gt 0 ]; then
  bad "lookup still returns tidal:track:0:0:0 -- playlist_lookup.install() did not take"
  note "check the mopidy log for 'playlist and mix lookup answer with real tracks'"
elif [ "$REAL" -gt 0 ]; then
  ok "lookup returns real tracks (backend patch active)"
else
  bad "lookup returned nothing at all"
fi

echo
echo "== the endpoint the plugin uses =="
URIS=$(curl -s --max-time 60 "$API/playlist/uris?uri=$URI")
COUNT=$(echo "$URIS" | jq '.uris | length')
BOGUS=$(echo "$URIS" | jq '[.uris[] | select(. == "tidal:track:0:0:0")] | length')
note "$COUNT uri(s) returned"
if [ "$COUNT" -gt 0 ] && [ "$BOGUS" -eq 0 ]; then
  ok "/playlist/uris names real tracks"
else
  bad "/playlist/uris returned $COUNT uris, $BOGUS of them placeholders"
fi
if [ "$NUM" -gt 100 ]; then
  if [ "$COUNT" -gt 100 ]; then
    ok "a playlist over 100 tracks is not truncated ($COUNT of $NUM)"
  else
    bad "truncated at $COUNT for a playlist of $NUM"
  fi
else
  note "playlist is under 100 tracks; test a longer one for the paging path"
fi

if [ "$PLAY" -eq 0 ]; then
  echo
  echo "$pass passed, $fail failed. Re-run with --play to check the queue and playback."
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

echo
echo "== queue and play (this replaces your queue) =="
rpc core.tracklist.clear >/dev/null
rpc core.tracklist.add "{\"uris\":[\"$URI\"]}" >/dev/null
TL=$(rpc core.tracklist.get_tl_tracks)
TL_COUNT=$(echo "$TL" | jq '.result | length')
TL_BOGUS=$(echo "$TL" | jq '[.result[] | select(.track.uri == "tidal:track:0:0:0")] | length')
note "adding the playlist uri gave $TL_COUNT entries, $TL_BOGUS placeholders"
if [ "$TL_COUNT" -gt 0 ] && [ "$TL_BOGUS" -eq 0 ]; then
  ok "core.tracklist.add on a playlist uri queues real tracks"
else
  bad "the queue still holds placeholders"
fi

rpc core.playback.play >/dev/null
sleep 5
STATE=$(rpc core.playback.get_state | jq -r '.result')
CUR=$(rpc core.playback.get_current_track | jq -r '.result.uri // "none"')
POS=$(rpc core.playback.get_time_position | jq -r '.result // 0')
note "state=$STATE track=$CUR position=${POS}ms"
if [ "$STATE" = "playing" ] && [ "$POS" -gt 0 ]; then
  ok "playing, and the position is advancing"
else
  bad "not playing after 5s -- this is the reported symptom"
fi

echo
echo "== it advances to the next track =="
rpc core.playback.next >/dev/null
sleep 4
NEXT=$(rpc core.playback.get_current_track | jq -r '.result.uri // "none"')
STATE=$(rpc core.playback.get_state | jq -r '.result')
note "state=$STATE track=$NEXT"
if [ "$STATE" = "playing" ] && [ "$NEXT" != "$CUR" ] && [ "$NEXT" != "none" ]; then
  ok "moved to the next track and kept playing"
else
  bad "stalled at the track boundary"
fi

rpc core.playback.stop >/dev/null

echo
echo "$pass passed, $fail failed."
[ "$fail" -eq 0 ] || exit 1
