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
  printf 'ROLE=%s\nGATEWAY_ID=%s\nPEERS_CONFIRM=%s\n' "${1:-contributor}" "$GW" "${2:-auto}" > "$TC_CONF"
  printf '{"devices":[{"deviceID":"%s"},{"deviceID":"%s"}]}' "$ME" "$GW" > "$FAKE_DIR/library.json"
}

peers_json() {
  printf '{"version":1,"generated":"x","extra":"ignored","peers":[%s]}' "$1"
}

peer() {
  printf '{"name":"%s","id":"%s","role":"%s","owner":"justin","junk":"ignored"}' "$1" "$2" "$3"
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
assert_jq "folder shares with new peers" "$(body_of 'PATCH /rest/config/folders/tinycloud-library')" "(.devices | map(.deviceID) | sort) == ([\"$ME\", \"$GW\", \"$P1\", \"$P2\"] | sort)"
assert_eq "only the devices key is patched" '["devices"]' "$(body_of 'PATCH /rest/config/folders/tinycloud-library' | jq -c 'keys')"
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
assert_jq "folder keeps gateway and self" "$(body_of 'PATCH /rest/config/folders/tinycloud-library')" "(.devices | map(.deviceID) | index(\"$GW\")) != null and (.devices | map(.deviceID) | index(\"$ME\")) != null"

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
rm -f "$FAKE_DIR/library.json"
FAKE_FAIL="GET /rest/config/folders"
run_main
assert_eq "missing library folder returns error" 1 "$RC"

finish
