#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
TC_RESTART_WAIT=0
export TC_RESTART_WAIT
. "$HERE/harness.sh"

ME=$(mkid A)
GW=$(mkid B)
RELAY=$(mkid C)
DISC=$(mkid D)
TOKEN=s3cr3t-token

setup() {
  new_sandbox
  FAKE_MY_ID=$ME
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/firstboot.sh"
  st_api() { fake_st_api "$@"; }
  cat > "$TC_CONF" << EOF
NODE_NAME=rocky
OWNER=justin
ROLE=${1:-anchor}
GATEWAY_HOST=gw.example.com
GATEWAY_ID=$GW
RELAY_ID=$RELAY
DISCOVERY_ID=$DISC
RELAY_TOKEN=$TOKEN
PULL_ORDER=smallestFirst
EOF
}

run_main() {
  main > "$FAKE_DIR/out" 2>&1
  RC=$?
  OUT=$(cat "$FAKE_DIR/out")
}

setup anchor
run_main
assert_eq "anchor first boot ok" 0 "$RC"
assert_eq "done marker written" 1 "$(test -f "$TC_STATE_DIR/firstboot.done" && echo 1 || echo 0)"
assert_eq "device id saved" "$ME" "$(cat "$TC_STATE_DIR/device-id")"

opts=$(body_of 'PATCH /rest/config/options')
assert_jq "global discovery only the gateway" "$opts" ".globalAnnounceServers == [\"https://gw.example.com:8443/?id=$DISC\"]"
assert_jq "relay is the only listen address" "$opts" ".listenAddresses == [\"relay://gw.example.com:22067/?id=$RELAY&token=$TOKEN\"]"
assert_jq "local discovery nat and stun off" "$opts" '.localAnnounceEnabled == false and .natEnabled == false and .stunServers == []'
assert_jq "no usage reports or crash reports" "$opts" '.urAccepted == -1 and .crashReportingEnabled == false'

gw=$(body_of "PUT /rest/config/devices/$GW")
assert_jq "gateway device direct address" "$gw" '.addresses == ["tcp://gw.example.com:22000"] and .introducer == false and .autoAcceptFolders == false'

lib=$(body_of 'PUT /rest/config/folders/tinycloud-library')
assert_jq "anchor library send receive" "$lib" '.type == "sendreceive"'
assert_jq "anchor has 30 day trashcan" "$lib" '.versioning.type == "trashcan" and .versioning.params.cleanoutDays == "30"'
assert_jq "library order and min free" "$lib" '.order == "smallestFirst" and .minDiskFree.unit == "MB" and .minDiskFree.value >= 1024'
assert_jq "library shared with self only" "$lib" "(.devices | length) == 1 and .devices[0].deviceID == \"$ME\""
assert_jq "library path" "$lib" ".path == \"$TC_LIBRARY_DIR\""

assert_jq "peers folder receive only with gateway" "$(body_of 'PUT /rest/config/folders/tinycloud-peers')" '.type == "receiveonly" and (.devices | length) == 2'
assert_jq "status folder send only with gateway" "$(body_of 'PUT /rest/config/folders/tc-status-rocky')" '.type == "sendonly" and (.devices | length) == 2'
assert_jq "view folder receive only with gateway" "$(body_of 'PUT /rest/config/folders/tc-view-justin')" '.type == "receiveonly" and (.devices | length) == 2'
assert_eq "default folder removed" 1 "$(count_calls 'DELETE /rest/config/folders/default')"
assert_contains "ignore list set" "$(body_of 'POST /rest/db/ignores?folder=tinycloud-library')" '._*'
assert_not_contains "token never logged" "$OUT" "$TOKEN"
assert_not_contains "relay id never logged" "$OUT" "$RELAY"

before=$(wc -l < "$FAKE_DIR/calls")
run_main
assert_eq "second run does nothing" "$before" "$(wc -l < "$FAKE_DIR/calls")"

setup reader
run_main
lib=$(body_of 'PUT /rest/config/folders/tinycloud-library')
assert_jq "reader library receive only" "$lib" '.type == "receiveonly"'
assert_jq "reader has no versioning" "$lib" '(.versioning.type // "") == ""'

setup anchor
FAKE_RESTART=true
run_main
assert_eq "restart when required" 1 "$(count_calls 'POST /rest/system/restart')"

setup anchor
conf_set "$TC_CONF" NODE_NAME Rocky
run_main
assert_eq "bad node name fails" 1 "$RC"
assert_eq "bad config touches nothing" 0 "$(count_calls PATCH)"
assert_contains "error names the key" "$OUT" "NODE_NAME"

setup anchor
conf_set "$TC_CONF" GATEWAY_HOST gw.example.com/evil
run_main
assert_eq "bad host fails" 1 "$RC"

setup anchor
conf_set "$TC_CONF" RELAY_TOKEN 'a&b'
run_main
assert_eq "bad token fails" 1 "$RC"
assert_not_contains "bad token not logged" "$OUT" 'a&b'

setup anchor
conf_set "$TC_CONF" PULL_ORDER chaos
run_main
assert_eq "bad pull order fails" 1 "$RC"

setup anchor
conf_set "$TC_CONF" GATEWAY_ID "$ME"
run_main
assert_eq "gateway id equal to self fails" 1 "$RC"

setup anchor
FAKE_FAIL="PATCH /rest/config/options"
run_main
assert_eq "options failure fails" 1 "$RC"
assert_eq "failed run leaves no done marker" 0 "$(test -f "$TC_STATE_DIR/firstboot.done" && echo 1 || echo 0)"

finish
