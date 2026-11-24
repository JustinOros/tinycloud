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
P3=$(mkid E)

setup() {
  new_sandbox
  FAKE_MY_ID=$ME
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/apply-peers.sh"
  st_api() { fake_st_api "$@"; }
  PEERS_FILE=$TC_SYSTEM_DIR/peers/peers.json
  printf 'OWNER=justin\nROLE=%s\nGATEWAY_ID=%s\nPEERS_CONFIRM=%s\n' "${1:-contributor}" "$GW" "${2:-auto}" > "$TC_CONF"
  printf '{"devices":[{"deviceID":"%s"}]}' "$ME" > "$FAKE_DIR/folder-justin.json"
}

peers_json() {
  printf '{"version":1,"generated":"x","extra":"ignored","peers":[%s]}' "$1"
}

peer() {
  printf '{"name":"%s","id":"%s","role":"%s","owner":"%s","junk":"ignored"}' "$1" "$2" "$3" "${4:-justin}"
}

run_main() {
  main > "$FAKE_DIR/out" 2>&1
  RC=$?
  OUT=$(cat "$FAKE_DIR/out")
}

setup
peers_json "$(peer rocky "$ME" anchor),$(peer grace "$P1" anchor),$(peer brie "$P2" reader)" > "$PEERS_FILE"
run_main
assert_eq "valid file applies" 0 "$RC"
assert_contains "log shows added" "$OUT" "added=[grace,brie]"
assert_eq "self not added" 0 "$(count_calls "PUT /rest/config/devices/$ME")"
assert_eq "peer 1 added" 1 "$(count_calls "PUT /rest/config/devices/$P1")"
assert_eq "peer 2 added" 1 "$(count_calls "PUT /rest/config/devices/$P2")"
assert_jq "device body has dynamic address and no introducer" "$(body_of "PUT /rest/config/devices/$P1")" '.addresses == ["dynamic"] and .introducer == false and .autoAcceptFolders == false and .name == "grace"'
assert_jq "folder shares with new peers" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" "(.devices | map(.deviceID) | sort) == ([\"$ME\", \"$P1\", \"$P2\"] | sort)"
assert_eq "the patch keeps the pull order and free space floor" '["devices","minDiskFree","order"]' "$(body_of 'PATCH /rest/config/folders/tc-lib-justin' | jq -c 'keys')"
assert_jq "the free space floor is not the Syncthing default" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" '.minDiskFree.unit == "MB" and .minDiskFree.value >= 1024'
assert_eq "layout marker written" 2 "$(cat "$TC_STATE_DIR/layout")"
assert_eq "managed ids saved" "$(printf '%s\n%s' "$P1" "$P2")" "$(cat "$TC_STATE_DIR/managed.ids")"

before=$(wc -l < "$FAKE_DIR/calls")
run_main
assert_eq "unchanged file does nothing" "$before" "$(wc -l < "$FAKE_DIR/calls")"

peers_json "$(peer rocky "$ME" anchor),$(peer brie "$P2" reader)" > "$PEERS_FILE"
run_main
assert_eq "removal run ok" 0 "$RC"
assert_eq "removed peer deleted" 1 "$(count_calls "DELETE /rest/config/devices/$P1")"
assert_eq "kept peer not deleted" 0 "$(count_calls "DELETE /rest/config/devices/$P2")"
assert_eq "gateway never deleted" 0 "$(count_calls "DELETE /rest/config/devices/$GW")"
assert_jq "folder keeps self and drops the removed peer" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" "(.devices | map(.deviceID) | index(\"$ME\")) != null and (.devices | map(.deviceID) | index(\"$P1\")) == null"

setup
peers_json "$(peer rocky "$ME" anchor),$(peer grace "$P1" anchor finn)" > "$PEERS_FILE"
run_main
assert_eq "new owner folder created" 1 "$(count_calls 'PUT /rest/config/folders/tc-lib-finn')"
finn=$(body_of 'PUT /rest/config/folders/tc-lib-finn')
assert_jq "other owner folder is receive only" "$finn" '.type == "receiveonly" and .label == "finn"'
assert_jq "other owner folder path" "$finn" ".path == \"$TC_LIBRARY_DIR/finn\""
assert_jq "other owner folder shared with me and peers" "$finn" "(.devices | map(.deviceID) | sort) == ([\"$ME\", \"$P1\"] | sort)"
assert_contains "ignore list set for new folder" "$(body_of 'POST /rest/db/ignores?folder=tc-lib-finn')" '._*'
assert_eq "own folder not recreated" 0 "$(count_calls 'PUT /rest/config/folders/tc-lib-justin')"

setup
printf '[{"id":"tc-lib-justin"},{"id":"tc-lib-finn"}]' > "$FAKE_DIR/folders.json"
peers_json "$(peer rocky "$ME" anchor)" > "$PEERS_FILE"
run_main
assert_eq "folder of an owner that left is removed" 1 "$(count_calls 'DELETE /rest/config/folders/tc-lib-finn')"
assert_eq "own folder kept" 0 "$(count_calls 'DELETE /rest/config/folders/tc-lib-justin')"
assert_contains "log says files kept" "$OUT" "removed, files kept"

setup
printf '{"devices":[]}' > "$FAKE_DIR/legacy.json"
peers_json "$(peer rocky "$ME" anchor)" > "$PEERS_FILE"
run_main
assert_eq "old library folder removed" 1 "$(count_calls 'DELETE /rest/config/folders/tinycloud-library')"
assert_contains "old folder removal logged" "$OUT" "old tinycloud-library folder removed"

setup
rm -f "$FAKE_DIR/folder-justin.json"
peers_json "$(peer rocky "$ME" anchor)" > "$PEERS_FILE"
run_main
assert_eq "missing own folder is created" 1 "$(count_calls 'PUT /rest/config/folders/tc-lib-justin')"
assert_jq "own folder follows the role" "$(body_of 'PUT /rest/config/folders/tc-lib-justin')" '.type == "sendreceive"'

setup reader
rm -f "$FAKE_DIR/folder-justin.json"
peers_json "$(peer rocky "$ME" reader),$(peer a "$P1" anchor)" > "$PEERS_FILE"
run_main
assert_jq "reader own folder receive only" "$(body_of 'PUT /rest/config/folders/tc-lib-justin')" '.type == "receiveonly"'

setup
peers_json "$(peer rocky "$ME" anchor)" > "$PEERS_FILE"
run_main
printf 'x\n' > "$TC_STATE_DIR/layout"
before=$(wc -l < "$FAKE_DIR/calls")
run_main
assert_eq "old layout reapplies an unchanged file" 1 "$([ "$(wc -l < "$FAKE_DIR/calls")" -gt "$before" ] && echo 1 || echo 0)"

setup
peers_json "$(peer rocky "$ME" anchor)" > "$PEERS_FILE"
printf '%s\n' "$P3" > "$TC_STATE_DIR/managed.ids"
run_main
assert_eq "unmanaged devices untouched, managed removed" 1 "$(count_calls "DELETE /rest/config/devices/$P3")"

setup
printf '{"version":2,"peers":[%s]}' "$(peer a "$P1" anchor)" > "$PEERS_FILE"
run_main
assert_contains "unknown version rejected" "$OUT" "peers.json rejected: unknown version"
assert_eq "no api writes on reject" 0 "$(count_calls PUT)"
run_main
assert_eq "same bad file not logged again" 0 "$(grep -c rejected "$FAKE_DIR/out" || true)"

setup
printf '{"version":1,"peers":[]}' > "$PEERS_FILE"
run_main
assert_contains "empty list rejected" "$OUT" "empty peer list"
assert_eq "empty list changes nothing" 0 "$(count_calls PATCH)"

setup
printf 'not json at all' > "$PEERS_FILE"
run_main
assert_contains "garbage rejected" "$OUT" "not valid JSON"

setup
peers_json "$(peer Bad "$P1" anchor)" > "$PEERS_FILE"
run_main
assert_contains "uppercase name rejected" "$OUT" "bad node name"

setup
printf '{"version":1,"peers":[{"name":"ok\\nbad","id":"%s","role":"anchor","owner":"justin"}]}' "$P1" > "$PEERS_FILE"
run_main
assert_contains "newline in name rejected" "$OUT" "bad node name"

setup
peers_json "$(peer a "bad-id" anchor)" > "$PEERS_FILE"
run_main
assert_contains "bad id rejected" "$OUT" "bad device id"

setup
peers_json "$(peer a "$P1" admin)" > "$PEERS_FILE"
run_main
assert_contains "bad role rejected" "$OUT" "bad role"

setup
peers_json "$(peer a "$P1" anchor),$(peer b "$P1" anchor)" > "$PEERS_FILE"
run_main
assert_contains "duplicate id rejected" "$OUT" "duplicate device id"

setup
peers_json "$(peer a "$P1" anchor),$(peer a "$P2" anchor)" > "$PEERS_FILE"
run_main
assert_contains "duplicate name rejected" "$OUT" "duplicate node name"

setup
printf '{"version":1,"peers":[{"name":"a","id":"%s","role":"anchor","owner":5}]}' "$P1" > "$PEERS_FILE"
run_main
assert_contains "non text field rejected" "$OUT" "not text"

setup
many=
n=0
while [ "$n" -lt 65 ]; do
  many="$many$(peer "n$n" "$(mkid C)" anchor),"
  n=$((n + 1))
done
peers_json "${many%,}" > "$PEERS_FILE"
run_main
assert_contains "more than 64 peers rejected" "$OUT" "too many peers"

setup
head -c 70000 /dev/zero | tr '\0' ' ' > "$PEERS_FILE"
run_main
assert_contains "oversized file rejected" "$OUT" "file too large"

setup reader
peers_json "$(peer a "$P1" reader),$(peer b "$P2" anchor)" > "$PEERS_FILE"
run_main
assert_eq "reader skips reader peers" 0 "$(count_calls "PUT /rest/config/devices/$P1")"
assert_eq "reader adds anchor peers" 1 "$(count_calls "PUT /rest/config/devices/$P2")"

setup contributor manual
peers_json "$(peer a "$P1" anchor)" > "$PEERS_FILE"
run_main
assert_eq "manual mode adds nothing new" 0 "$(count_calls "PUT /rest/config/devices/$P1")"
assert_contains "manual mode lists pending" "$(cat "$TC_STATE_DIR/pending.json")" "$P1"
printf '%s\n' "$P1" > "$TC_STATE_DIR/confirmed.ids"
rm -f "$TC_STATE_DIR/applied.sha"
run_main
assert_eq "confirmed peer is added" 1 "$(count_calls "PUT /rest/config/devices/$P1")"
assert_eq "pending cleared" "[]" "$(cat "$TC_STATE_DIR/pending.json")"

setup
peers_json "$(peer a "$P1" anchor)" > "$PEERS_FILE"
FAKE_FAIL="PUT /rest/config/devices"
run_main
assert_eq "api failure returns error" 1 "$RC"
assert_eq "failed run does not save hash" "" "$(read_state applied.sha)"

setup
peers_json "$(peer a "$P1" anchor)" > "$PEERS_FILE"
rm -f "$FAKE_DIR/folder-justin.json"
FAKE_FAIL="PUT /rest/config/folders"
run_main
assert_eq "folder create failure returns error" 1 "$RC"

setup
peers_json "$(peer a "$P1" anchor)" > "$PEERS_FILE"
conf_set "$TC_CONF" OWNER "BAD OWNER"
run_main
assert_eq "bad owner returns error" 1 "$RC"

DISC2=$(mkid F)
RELAY2=$(mkid G)
link() {
  printf '{"host":"%s","relay_id":"%s","disc_id":"%s","token":"%s"}' "${1:-gw.finn.example}" "${2:-$RELAY2}" "${3:-$DISC2}" "${4:-fintoken}"
}
links_conf() {
  printf 'NODE_NAME=rocky\nGATEWAY_HOST=gw.example.com\nRELAY_ID=%s\nDISCOVERY_ID=%s\nRELAY_TOKEN=owntoken\n' "$(mkid H)" "$(mkid I)" >> "$TC_CONF"
}

setup
links_conf
printf '{"version":1,"peers":[%s],"links":[%s]}' "$(peer rocky "$ME" anchor)" "$(link)" > "$PEERS_FILE"
run_main
assert_eq "links file applies" 0 "$RC"
opts=$(body_of 'PATCH /rest/config/options')
assert_jq "linked discovery server added after the own one" "$opts" "(.globalAnnounceServers | length) == 2 and .globalAnnounceServers[1] == \"https://gw.finn.example:8443/?id=$DISC2\""
assert_jq "linked relay added after the own one" "$opts" "(.listenAddresses | length) == 2 and .listenAddresses[1] == \"relay://gw.finn.example:22067/?id=$RELAY2&token=fintoken\" and (.listenAddresses[0] | startswith(\"relay://gw.example.com:22067/\"))"
assert_contains "links applied is logged" "$OUT" "linked gateways applied: 1"
assert_not_contains "link token never logged" "$OUT" "fintoken"

: > "$FAKE_DIR/calls"
rm -f "$TC_STATE_DIR/applied.sha"
run_main
assert_eq "unchanged links are not applied again" 0 "$(count_calls 'PATCH /rest/config/options')"

FAKE_RESTART=true
printf '{"version":1,"peers":[%s],"links":[]}' "$(peer rocky "$ME" anchor)" > "$PEERS_FILE"
run_main
assert_jq "removing the links restores the single servers" "$(body_of 'PATCH /rest/config/options')" '(.globalAnnounceServers | length) == 1 and (.listenAddresses | length) == 1'
assert_eq "syncthing restarts when needed" 1 "$(count_calls 'POST /rest/system/restart')"
FAKE_RESTART=false

setup
printf '{"version":1,"peers":[%s]}' "$(peer rocky "$ME" anchor)" > "$PEERS_FILE"
run_main
assert_eq "no links and none before changes no options" 0 "$(count_calls 'PATCH /rest/config/options')"

for bad in \
  '[{"host":"bad host","relay_id":"R","disc_id":"D","token":"t"}]' \
  "[$(link gw.finn.example NOPE)]" \
  "[$(link gw.finn.example "$RELAY2" "$DISC2" 'bad token!')]" \
  "[$(link),$(link)]" \
  '"notalist"'; do
  setup
  links_conf
  printf '{"version":1,"peers":[%s],"links":%s}' "$(peer rocky "$ME" anchor)" "$bad" > "$PEERS_FILE"
  run_main
  assert_contains "bad links reject the file" "$OUT" "peers.json rejected"
  assert_eq "bad links change nothing" 0 "$(count_calls PATCH)"
done

setup
links_conf
printf '{"version":1,"peers":[%s],"links":[%s]}' "$(peer rocky "$ME" anchor)" "$(link)" > "$PEERS_FILE"
run_main
printf '[]' > "$TC_STATE_DIR/links.json"
rm -f "$TC_STATE_DIR/applied.sha"
run_main
assert_jq "options use the saved links" "$(body_of 'PATCH /rest/config/options')" '(.listenAddresses | length) == 2'

lpeer() {
  printf '{"name":"%s","id":"%s","role":"anchor","owner":"%s","folders":%s}' "$1" "$2" "$3" "$4"
}

setup
peers_json "$(peer rocky "$ME" anchor),$(peer grace "$P1" anchor),$(lpeer finn-rocky "$P2" finn '["finn"]')" > "$PEERS_FILE"
run_main
assert_eq "accepted folder is created" 1 "$(count_calls 'PUT /rest/config/folders/tc-lib-finn')"
assert_jq "accepted folder is receive only and shared with the linked node" "$(body_of 'PUT /rest/config/folders/tc-lib-finn')" "(.devices | map(.deviceID) | index(\"$P2\")) != null and .type == \"receiveonly\""
assert_jq "own folder does not go to a linked node that was not offered it" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" "(.devices | map(.deviceID) | index(\"$P2\")) == null and (.devices | map(.deviceID) | index(\"$P1\")) != null"
assert_eq "linked device is added" 1 "$(count_calls "PUT /rest/config/devices/$P2")"

setup
peers_json "$(peer rocky "$ME" anchor),$(lpeer finn-rocky "$P2" finn '["justin"]')" > "$PEERS_FILE"
run_main
assert_jq "offered own folder goes to the linked node" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" "(.devices | map(.deviceID) | index(\"$P2\")) != null"
assert_eq "a folder that was not accepted is not created" 0 "$(count_calls 'PUT /rest/config/folders/tc-lib-finn')"

setup
peers_json "$(peer rocky "$ME" anchor),$(lpeer finn-rocky "$P2" finn '[]')" > "$PEERS_FILE"
run_main
assert_eq "linked node with nothing shared gets no folder" 0 "$(count_calls 'PUT /rest/config/folders/tc-lib-finn')"
assert_jq "and is not in the own folder" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" "(.devices | map(.deviceID) | index(\"$P2\")) == null"

setup
printf '%s\n' "$P2" > "$TC_STATE_DIR/managed.ids"
printf '{"devices":[{"deviceID":"%s"},{"deviceID":"%s"}]}' "$ME" "$P2" > "$FAKE_DIR/folder-justin.json"
peers_json "$(peer rocky "$ME" anchor),$(lpeer finn-rocky "$P2" finn '["finn"]')" > "$PEERS_FILE"
run_main
assert_jq "a linked node no longer offered the own folder is dropped from it" "$(body_of 'PATCH /rest/config/folders/tc-lib-justin')" "(.devices | map(.deviceID) | index(\"$P2\")) == null"

setup
peers_json "$(peer rocky "$ME" anchor),$(lpeer finn-rocky "$P2" finn '"x"')" > "$PEERS_FILE"
run_main
assert_contains "folders that is not a list is rejected" "$OUT" "folders is not a list"
setup
peers_json "$(peer rocky "$ME" anchor),$(lpeer finn-rocky "$P2" finn '["Bad Name"]')" > "$PEERS_FILE"
run_main
assert_contains "bad folder name is rejected" "$OUT" "bad folder name"

finish
