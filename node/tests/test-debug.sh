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
  . "$TC_ROOT/agent/debug.sh"
  st_api() { fake_st_api "$@"; }
}

setup
main on > /dev/null
assert_eq "on enables three facets" 1 "$(count_calls 'POST /rest/system/debug?enable=connections,discover,relay')"
until=$(cat "$TC_STATE_DIR/debug.until")
now=$(date +%s)
assert_eq "until is about 30 minutes ahead" 1 "$([ "$until" -gt $((now + 1700)) ] && [ "$until" -le $((now + 1801)) ] && echo 1 || echo 0)"

before=$(wc -l < "$FAKE_DIR/calls")
main expire > /dev/null
assert_eq "not expired does nothing" "$before" "$(wc -l < "$FAKE_DIR/calls")"

printf '%s\n' "$((now - 5))" > "$TC_STATE_DIR/debug.until"
main expire > /dev/null
assert_eq "expired turns debug off" 1 "$(count_calls 'POST /rest/system/debug?disable=connections,discover,relay')"
assert_eq "expired removes marker" 0 "$(test -f "$TC_STATE_DIR/debug.until" && echo 1 || echo 0)"

setup
main expire > /dev/null
assert_eq "no marker does nothing" 0 "$(wc -l < "$FAKE_DIR/calls" | tr -d ' ')"

printf 'garbage\n' > "$TC_STATE_DIR/debug.until"
main expire > /dev/null
assert_eq "garbage marker removed without api calls" 0 "$(wc -l < "$FAKE_DIR/calls" | tr -d ' ')"
assert_eq "garbage marker gone" 0 "$(test -f "$TC_STATE_DIR/debug.until" && echo 1 || echo 0)"

setup
main off > /dev/null
assert_eq "off disables facets" 1 "$(count_calls 'POST /rest/system/debug?disable')"

setup
FAKE_FAIL="debug?enable"
main on > /dev/null 2>&1
assert_eq "api failure fails" 1 "$?"
assert_eq "api failure leaves no marker" 0 "$(test -f "$TC_STATE_DIR/debug.until" && echo 1 || echo 0)"

setup
main bogus > /dev/null 2>&1
assert_eq "bad usage returns 2" 2 "$?"

setup
TC_DEBUG_MINUTES=abc main on > /dev/null 2>&1
assert_eq "bad minutes rejected" 1 "$?"

finish
