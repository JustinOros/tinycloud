#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
. "$HERE/harness.sh"

setup() {
  new_sandbox
  FAKE_MY_ID=$(mkid A)
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/agent.sh"
  st_api() { fake_st_api "$@"; }
  STEPS="$SANDBOX/steps"
  : > "$STEPS"
  STEP_FAIL=
  run_step() {
    echo "$1" >> "$STEPS"
    if [ "$STEP_FAIL" = "$1" ]; then
      return 1
    fi
    if [ "$1" = status ]; then
      printf '{}' > "$TC_STATE_DIR/status.local.json"
    fi
    return 0
  }
}

setup
main
assert_eq "first run does everything" "firstboot apply-peers status" "$(tr '\n' ' ' < "$STEPS" | sed 's/ $//')"
: > "$STEPS"
main
assert_eq "second run skips status" "firstboot apply-peers" "$(tr '\n' ' ' < "$STEPS" | sed 's/ $//')"
: > "$STEPS"
main
assert_eq "third run writes status" "firstboot apply-peers status" "$(tr '\n' ' ' < "$STEPS" | sed 's/ $//')"
: > "$STEPS"
main
assert_eq "fourth run skips status" "firstboot apply-peers" "$(tr '\n' ' ' < "$STEPS" | sed 's/ $//')"

setup
STEP_FAIL=firstboot
main
assert_eq "firstboot failure stops the run" 1 "$?"
assert_eq "nothing else ran" "firstboot" "$(tr '\n' ' ' < "$STEPS" | sed 's/ $//')"

setup
STEP_FAIL=apply-peers
main
assert_eq "apply failure reports error" 1 "$?"
assert_contains "status still runs" "$(cat "$STEPS")" "status"

setup
FAKE_FAIL="GET /rest/system/ping"
st_wait() { return 1; }
main
assert_eq "no syncthing fails fast" 1 "$?"
assert_eq "no steps without syncthing" 0 "$(wc -l < "$STEPS" | tr -d ' ')"

finish
