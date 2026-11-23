#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
TC_DOCTOR_RUN=0
. "$HERE/harness.sh"

ME=$(mkid A)
GW=$(mkid B)

setup() {
  new_sandbox
  FAKE_MY_ID=$ME
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/doctor.sh"
  st_api() { fake_st_api "$@"; }
  tcp_check() { return 0; }
  dns_check() { return 0; }
  cat > "$TC_CONF" << CONF
NODE_NAME=rocky
OWNER=justin
ROLE=anchor
FREE_SPACE_PERCENT=1
GATEWAY_HOST=gw.example.com
GATEWAY_ID=$GW
RELAY_ID=$(mkid C)
DISCOVERY_ID=$(mkid D)
RELAY_TOKEN=tok
CONF
  printf '{"connections":{"%s":{"connected":true}}}' "$GW" > "$FAKE_DIR/connections.json"
  date -u > "$TC_STATE_DIR/firstboot.done"
  DOC_FAILS=0
}

run_doctor() {
  main > "$FAKE_DIR/out" 2>&1
  RC=$?
  OUT=$(cat "$FAKE_DIR/out")
}

setup
run_doctor
assert_eq "healthy node passes" 0 "$RC"
assert_contains "says all passed" "$OUT" "All checks passed."
assert_not_contains "no failures" "$OUT" "FAIL"
assert_contains "reports gateway link" "$OUT" "Connected to the gateway"

setup
dns_check() { return 1; }
run_doctor
assert_eq "dns failure fails" 1 "$RC"
assert_contains "dns failure explained" "$OUT" "Cannot look up gw.example.com"

setup
tcp_check() { [ "$2" != 22067 ]; }
run_doctor
assert_eq "closed relay port fails" 1 "$RC"
assert_contains "names the relay" "$OUT" "relay port 22067"
assert_contains "other ports fine" "$OUT" "sync port 22000 is reachable"

setup
printf '{"connections":{}}' > "$FAKE_DIR/connections.json"
run_doctor
assert_eq "not connected fails" 1 "$RC"
assert_contains "not connected explained" "$OUT" "Not connected to the gateway"

setup
rm -f "$TC_STATE_DIR/firstboot.done"
run_doctor
assert_contains "first boot missing flagged" "$OUT" "First boot setup has not finished"

setup
conf_set "$TC_CONF" NODE_NAME BAD
run_doctor
assert_eq "bad config fails" 1 "$RC"
assert_contains "bad config names the key" "$OUT" "NODE_NAME"
assert_not_contains "network checks skipped" "$OUT" "resolves"

setup
printf '{"state":"error","globalBytes":1,"localBytes":1,"pullErrors":3}' > "$FAKE_DIR/dbstatus.json"
run_doctor
assert_contains "sync errors warned" "$OUT" "Folder justin has sync errors (3 files)"
assert_eq "warnings alone do not fail" 0 "$RC"

setup
printf '[{"id":"tc-lib-justin"},{"id":"tc-lib-finn"}]' > "$FAKE_DIR/folders.json"
run_doctor
assert_contains "each folder reported" "$OUT" "Folder finn state: idle"

setup
printf '[]' > "$FAKE_DIR/folders.json"
run_doctor
assert_contains "no folders warned" "$OUT" "No library folders found"

setup
printf 'x' > "$TC_STATE_DIR/rejected.sha"
run_doctor
assert_contains "rejected peers warned" "$OUT" "last peers.json was rejected"

setup
printf '[{"id":"x"},{"id":"y"}]' > "$TC_STATE_DIR/pending.json"
run_doctor
assert_contains "pending peers warned" "$OUT" "2 new peers are waiting"

setup
printf '2026-01-01T00:00:00Z tinycloud-agent 0.1.0 ERROR something broke\n' > "$TC_LOG_DIR/errors.log"
run_doctor
assert_contains "recent errors shown" "$OUT" "something broke"

setup
conf_set "$TC_CONF" FREE_SPACE_MIN_GB 999999
run_doctor
assert_contains "full disk warned" "$OUT" "Disk is nearly full"

finish
