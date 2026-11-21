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
  TC_STATUS_DIR=$SANDBOX/status-out
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG TC_STATUS_DIR
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/status.sh"
  st_api() { fake_st_api "$@"; }
  printf 'NODE_NAME=rocky\nROLE=%s\nFREE_SPACE_PERCENT=1\nFREE_SPACE_MIN_GB=%s\n' "${1:-anchor}" "${2:-1}" > "$TC_CONF"
}

setup
list_paths() {
  printf '%s\n' "$1/Book.epub" "$1/book.epub" "$1/other.epub" "$1/Dir" "$1/Dir/a.epub"
}
assert_eq "case conflicts counted once per group" 1 "$(count_case_conflicts "$TC_LIBRARY_DIR")"

main > "$FAKE_DIR/out" 2>&1
assert_eq "main ok" 0 "$?"
status=$(cat "$STATUS_DIR/status.json")
assert_jq "status fields" "$status" '.v == 1 and .name == "rocky" and .role == "anchor" and .percent_stored == 50 and .case_conflicts == 1 and .low_space == false and (.free_bytes | type) == "number"'
assert_jq "status has only known keys" "$status" '(keys | sort) == ["case_conflicts","free_bytes","low_space","name","percent_stored","role","time","v","version"]'
assert_eq "no temp file left behind" 0 "$(find "$STATUS_DIR" -name '*tmp*' | wc -l | tr -d ' ')"
assert_eq "local copy written" 1 "$(test -f "$TC_STATE_DIR/status.local.json" && echo 1 || echo 0)"

before=$(cat "$TC_STATE_DIR/status.sent.at")
main > "$FAKE_DIR/out" 2>&1
assert_eq "unchanged status not rewritten" "$before" "$(cat "$TC_STATE_DIR/status.sent.at")"
assert_not_contains "no log line when skipped" "$(cat "$FAKE_DIR/out")" "status written"

printf '{"state":"idle","globalBytes":1000,"localBytes":510,"pullErrors":0}' > "$FAKE_DIR/dbstatus.json"
rm -f "$STATUS_DIR/status.json"
main > "$FAKE_DIR/out" 2>&1
assert_eq "2 point change not written" 0 "$(test -f "$STATUS_DIR/status.json" && echo 1 || echo 0)"
printf '{"state":"idle","globalBytes":1000,"localBytes":600,"pullErrors":0}' > "$FAKE_DIR/dbstatus.json"
main > "$FAKE_DIR/out" 2>&1
assert_eq "big change written" 1 "$(test -f "$STATUS_DIR/status.json" && echo 1 || echo 0)"

setup
printf '{"state":"idle","globalBytes":0,"localBytes":0}' > "$FAKE_DIR/dbstatus.json"
main > "$FAKE_DIR/out" 2>&1
assert_jq "empty library is 100 percent" "$(cat "$STATUS_DIR/status.json")" '.percent_stored == 100'

setup anchor 999999
main > "$FAKE_DIR/out" 2>&1
assert_jq "low space flagged" "$(cat "$STATUS_DIR/status.json")" '.low_space == true'

A='{"percent_stored":50,"low_space":false,"version":"0.1.0","role":"anchor","case_conflicts":0}'
same_ok() { should_write_status "$1" "$2" "$3" "$4" && echo yes || echo no; }
assert_eq "no previous writes" yes "$(same_ok '' "$A" 1000 1000)"
assert_eq "same status skips" no "$(same_ok "$A" "$A" 1000 900)"
assert_eq "1 point skips" no "$(same_ok "$A" '{"percent_stored":51,"low_space":false,"version":"0.1.0","role":"anchor","case_conflicts":0}' 1000 900)"
assert_eq "2 points writes" yes "$(same_ok "$A" '{"percent_stored":52,"low_space":false,"version":"0.1.0","role":"anchor","case_conflicts":0}' 1000 900)"
assert_eq "low space flip writes" yes "$(same_ok "$A" '{"percent_stored":50,"low_space":true,"version":"0.1.0","role":"anchor","case_conflicts":0}' 1000 900)"
assert_eq "version change writes" yes "$(same_ok "$A" '{"percent_stored":50,"low_space":false,"version":"0.2.0","role":"anchor","case_conflicts":0}' 1000 900)"
assert_eq "conflict change writes" yes "$(same_ok "$A" '{"percent_stored":50,"low_space":false,"version":"0.1.0","role":"anchor","case_conflicts":2}' 1000 900)"
assert_eq "24 hours writes" yes "$(same_ok "$A" "$A" 100000 1000)"

setup
FAKE_FAIL="GET /rest/db/status"
main > "$FAKE_DIR/out" 2>&1
assert_eq "api failure returns error" 1 "$?"
assert_eq "api failure writes nothing" 0 "$(test -f "$STATUS_DIR/status.json" && echo 1 || echo 0)"

finish
