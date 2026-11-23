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

new_sandbox
FAKE_MY_ID=$ME
export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
. "$TC_ROOT/agent/lib.sh"
. "$TC_ROOT/agent/relay.sh"
st_api() { fake_st_api "$@"; }
cat > "$TC_CONF" << CONF
NODE_NAME=rocky
OWNER=justin
ROLE=reader
GATEWAY_HOST=gw.example.com
GATEWAY_ID=$GW
RELAY_ID=$RELAY
DISCOVERY_ID=$DISC
RELAY_TOKEN=brandnewtoken
CONF

relay_main > "$FAKE_DIR/out" 2>&1
assert_eq "relay step ok" 0 "$?"
calls=$(cat "$FAKE_DIR/calls")
opts=$(grep '^PATCH /rest/config/options' "$FAKE_DIR/calls" | sed 's/^PATCH \/rest\/config\/options //')
assert_jq "options carry the new token" "$opts" ".listenAddresses == [\"relay://gw.example.com:22067/?id=$RELAY&token=brandnewtoken\"]"
assert_not_contains "folders untouched" "$calls" "/rest/config/folders"
assert_not_contains "devices untouched" "$calls" "/rest/config/devices"
assert_eq "no first boot marker written" 0 "$(test -f "$TC_STATE_DIR/firstboot.done" && echo 1 || echo 0)"

printf '[{"host":"gw.finn.example","relay_id":"%s","disc_id":"%s","token":"fintoken"}]' "$(mkid F)" "$(mkid G)" > "$TC_STATE_DIR/links.json"
: > "$FAKE_DIR/calls"
relay_main > /dev/null 2>&1
opts=$(grep '^PATCH /rest/config/options' "$FAKE_DIR/calls" | sed 's/^PATCH \/rest\/config\/options //')
assert_jq "linked gateways stay in the options" "$opts" '(.listenAddresses | length) == 2 and (.globalAnnounceServers | length) == 2'
rm -f "$TC_STATE_DIR/links.json"

FAKE_RESTART=true
: > "$FAKE_DIR/calls"
relay_main > /dev/null 2>&1
assert_contains "syncthing restarts when needed" "$(cat "$FAKE_DIR/calls")" "POST /rest/system/restart"

conf_set "$TC_CONF" RELAY_TOKEN 'bad token!'
relay_main > "$FAKE_DIR/out" 2>&1
assert_eq "bad token refused" 1 "$?"
assert_contains "bad token explained" "$(cat "$FAKE_DIR/out")" "RELAY_TOKEN"

finish
