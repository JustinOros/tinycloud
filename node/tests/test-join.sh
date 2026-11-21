#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
. "$HERE/harness.sh"

ID=$(mkid A)

setup() {
  new_sandbox
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/join.sh"
  printf 'NODE_NAME=adrian\nOWNER=justin\nROLE=contributor\n' > "$TC_CONF"
  printf '%s\n' "$ID" > "$TC_STATE_DIR/device-id"
}

setup
out=$(main)
assert_contains "join line" "$out" "tinycloud-gw approve adrian $ID contributor justin"
assert_contains "code shown" "$out" "$(verify_code "$ID")"

setup
printf 'NODE_NAME=adrian\nOWNER=justin\n' > "$TC_CONF"
out=$(main)
assert_contains "role defaults to reader" "$out" "$ID reader justin"

setup
st_api() { printf '{"myID":"%s"}' "$ID"; }
rm -f "$TC_STATE_DIR/device-id"
out=$(main)
assert_contains "falls back to syncthing" "$out" "$ID"

setup
rm -f "$TC_STATE_DIR/device-id"
st_api() { return 1; }
out=$(main 2>&1)
assert_eq "not ready fails" 1 "$(main > /dev/null 2>&1 && echo 0 || echo 1)"
assert_contains "not ready explained" "$out" "not ready yet"

setup
printf 'NODE_NAME=Bad Name\nOWNER=justin\n' > "$TC_CONF"
assert_eq "bad name fails" 1 "$(main > /dev/null 2>&1 && echo 0 || echo 1)"

setup
printf 'NODE_NAME=adrian\nOWNER=justin\nROLE=admin\n' > "$TC_CONF"
assert_eq "bad role fails" 1 "$(main > /dev/null 2>&1 && echo 0 || echo 1)"

finish
