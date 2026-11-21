#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
. "$HERE/harness.sh"

P1=$(mkid C)
P2=$(mkid D)

setup() {
  new_sandbox
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/confirm.sh"
  printf '[{"id":"%s","name":"grace","role":"anchor","owner":"justin"},{"id":"%s","name":"brie","role":"reader","owner":"finn"}]' "$P1" "$P2" > "$TC_STATE_DIR/pending.json"
  printf 'oldhash\n' > "$TC_STATE_DIR/applied.sha"
}

setup
out=$(main)
assert_contains "lists first waiting peer" "$out" "grace"
assert_contains "lists second waiting peer" "$out" "brie"
assert_contains "shows how to confirm" "$out" "tinycloud confirm all"

setup
main grace > /dev/null
assert_eq "confirmed id saved" "$P1" "$(cat "$TC_STATE_DIR/confirmed.ids")"
assert_eq "forces a re-apply" 0 "$(test -f "$TC_STATE_DIR/applied.sha" && echo 1 || echo 0)"

setup
main all > /dev/null
assert_eq "all confirms both" "$(printf '%s\n%s' "$P1" "$P2")" "$(cat "$TC_STATE_DIR/confirmed.ids")"

setup
main nobody > /dev/null 2>&1
assert_eq "unknown name fails" 1 "$?"
assert_eq "unknown name confirms nothing" 0 "$(test -f "$TC_STATE_DIR/confirmed.ids" && echo 1 || echo 0)"

setup
main 'Bad Name' > /dev/null 2>&1
assert_eq "invalid name fails" 1 "$?"

setup
rm -f "$TC_STATE_DIR/pending.json"
assert_contains "nothing waiting" "$(main)" "Nothing is waiting"

finish
