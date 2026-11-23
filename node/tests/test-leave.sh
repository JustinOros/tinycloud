#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
. "$HERE/harness.sh"

ME=$(mkid A)
GW=$(mkid B)
P1=$(mkid C)
P2=$(mkid D)

setup() {
  new_sandbox
  FAKE_MY_ID=$ME
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/leave.sh"
  st_api() { fake_st_api "$@"; }
  printf 'NODE_NAME=rocky\nOWNER=justin\nGATEWAY_ID=%s\n' "$GW" > "$TC_CONF"
  printf '%s\n%s\n' "$P1" "$P2" > "$TC_STATE_DIR/managed.ids"
  printf 'x\n' > "$TC_STATE_DIR/applied.sha"
}

setup
main > "$FAKE_DIR/out" 2>&1
assert_eq "leave ok" 0 "$?"
assert_jq "library shared with self only" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" "(.devices | length) == 1 and .devices[0].deviceID == \"$ME\""
assert_eq "peer 1 removed" 1 "$(count_calls "DELETE /rest/config/devices/$P1")"
assert_eq "peer 2 removed" 1 "$(count_calls "DELETE /rest/config/devices/$P2")"
assert_eq "gateway removed" 1 "$(count_calls "DELETE /rest/config/devices/$GW")"
assert_eq "peers folder removed" 1 "$(count_calls 'DELETE /rest/config/folders/tinycloud-peers')"
assert_eq "status folder removed" 1 "$(count_calls 'DELETE /rest/config/folders/tc-status-rocky')"
assert_eq "view folder removed" 1 "$(count_calls 'DELETE /rest/config/folders/tc-view-justin')"
assert_eq "library folder not deleted" 0 "$(count_calls 'DELETE /rest/config/folders/tc-lib-justin')"
assert_eq "left marker written" 1 "$(test -f "$TC_STATE_DIR/left" && echo 1 || echo 0)"
assert_eq "managed list cleared" 0 "$(test -f "$TC_STATE_DIR/managed.ids" && echo 1 || echo 0)"

setup
printf '[{"id":"tc-lib-justin"},{"id":"tc-lib-finn"},{"id":"tinycloud-peers"}]' > "$FAKE_DIR/folders.json"
main > "$FAKE_DIR/out" 2>&1
assert_jq "every owner folder unshared" "$(body_of 'PATCH /rest/config/folders/tc-lib-finn')" "(.devices | length) == 1 and .devices[0].deviceID == \"$ME\""
assert_eq "no owner folder deleted" 0 "$(count_calls 'DELETE /rest/config/folders/tc-lib-')"

setup
FAKE_FAIL="DELETE /rest/config/devices"
main > "$FAKE_DIR/out" 2>&1
assert_eq "partial failure reports error" 1 "$?"
assert_eq "left marker still written" 1 "$(test -f "$TC_STATE_DIR/left" && echo 1 || echo 0)"
assert_contains "failure logged" "$(cat "$FAKE_DIR/out")" "step failed"

setup
conf_set "$TC_CONF" NODE_NAME 'BAD NAME'
main > "$FAKE_DIR/out" 2>&1
assert_eq "bad config fails" 1 "$?"
assert_eq "bad config makes no changes" 0 "$(count_calls DELETE)"
assert_eq "bad config does not mark as left" 0 "$(test -f "$TC_STATE_DIR/left" && echo 1 || echo 0)"

finish
