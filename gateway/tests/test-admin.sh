#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$GW/.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
GW_HOME=$SANDBOX/gw
GW_ALLOW_NONROOT=1
GW_NO_MAIN=1
GW_LIB_DIR=$GW
GW_BACKUP_DIR=$SANDBOX/backups
FAKE=$SANDBOX/fake
export GW_HOME GW_ALLOW_NONROOT GW_NO_MAIN GW_LIB_DIR GW_BACKUP_DIR
. "$GW/bin/tinycloud-gw"

GWID=$(mkid A)
N1=$(mkid B)
N2=$(mkid C)
N3=$(mkid D)

fake_api() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FAKE/calls"
  case "$1 $2" in
    "GET /rest/system/ping") printf '{"ping":"pong"}' ;;
    "GET /rest/system/status") printf '{"myID":"%s"}' "$GWID" ;;
    "GET /rest/system/connections") cat "$FAKE/connections.json" ;;
    "GET /rest/config/defaults/folder")
      printf '{"id":"","label":"","path":"","type":"sendreceive","devices":[],"rescanIntervalS":3600}'
      ;;
    "GET /rest/config/defaults/device")
      printf '{"deviceID":"","name":"","addresses":["dynamic"],"introducer":false}'
      ;;
    "PUT /rest/config/devices/"*) printf '%s' "$3" > "$FAKE/devices/${2##*/}.json" ;;
    "DELETE /rest/config/devices/"*) rm -f "$FAKE/devices/${2##*/}.json" ;;
    "PUT /rest/config/folders/"*) printf '%s' "$3" > "$FAKE/folders/${2##*/}.json" ;;
    "DELETE /rest/config/folders/"*) rm -f "$FAKE/folders/${2##*/}.json" ;;
    "GET /rest/config/folders/"*)
      [ -f "$FAKE/folders/${2##*/}.json" ] || return 1
      cat "$FAKE/folders/${2##*/}.json"
      ;;
    "PATCH /rest/config/folders/"*)
      [ -f "$FAKE/folders/${2##*/}.json" ] || return 1
      jq -c --argjson p "$3" '. * $p' "$FAKE/folders/${2##*/}.json" > "$FAKE/tmp.json"
      mv "$FAKE/tmp.json" "$FAKE/folders/${2##*/}.json"
      ;;
  esac
  return 0
}

st_api() { fake_api "$@"; }
dc() { printf 'dc %s\n' "$*" >> "$FAKE/calls"; }

reset() {
  rm -rf "$GW_HOME" "$FAKE" "$GW_BACKUP_DIR"
  mkdir -p "$GW_HOME" "$FAKE/devices" "$FAKE/folders"
  : > "$FAKE/calls"
  printf '{"connections":{}}' > "$FAKE/connections.json"
  ASSUME_YES=0
}

folder_ids() { jq -c '[.devices[].deviceID] | sort' "$FAKE/folders/$1.json"; }
sorted() { printf '%s\n' "$@" | sort | jq -R . | jq -sc .; }

reset
out=$(printf 'yes\n' | cmd_approve rocky "$N1" reader justin 2>&1)
assert_contains "code shown" "$out" "Verification code: $(verify_code "$N1")"
assert_contains "approved message" "$out" "approved rocky"
assert_eq "device added" 1 "$([ -f "$FAKE/devices/$N1.json" ] && echo 1 || echo 0)"
assert_jq "device name" "$(cat "$FAKE/devices/$N1.json")" '.name == "rocky" and .introducer == false and .autoAcceptFolders == false'
assert_jq "approved list" "$(cat "$APPROVED")" 'length == 1 and .[0].name == "rocky" and .[0].role == "reader" and .[0].owner == "justin"'
assert_eq "peers folder devices" "$(sorted "$GWID" "$N1")" "$(folder_ids tinycloud-peers)"
assert_jq "peers folder is send only" "$(cat "$FAKE/folders/tinycloud-peers.json")" '.type == "sendonly" and .path == "/var/syncthing/tinycloud-peers"'
assert_jq "status folder receive only" "$(cat "$FAKE/folders/tc-status-rocky.json")" '.type == "receiveonly" and .id == "tc-status-rocky"'
assert_eq "status folder devices" "$(sorted "$GWID" "$N1")" "$(folder_ids tc-status-rocky)"
assert_jq "view folder send only" "$(cat "$FAKE/folders/tc-view-justin.json")" '.type == "sendonly"'
assert_eq "view folder devices" "$(sorted "$GWID" "$N1")" "$(folder_ids tc-view-justin)"
peers=$FOLDERS_DIR/tinycloud-peers/peers.json
assert_jq "peers.json shape" "$(cat "$peers")" '.version == 1 and (.peers | length) == 1 and .peers[0].id != null'
assert_eq "folder marker made" 1 "$([ -d "$FOLDERS_DIR/tinycloud-peers/.stfolder" ] && echo 1 || echo 0)"
assert_eq "no temp file left" 0 "$([ -e "$FOLDERS_DIR/tinycloud-peers/.syncthing.peers.json.tmp" ] && echo 1 || echo 0)"
assert_contains "scan triggered" "$(cat "$FAKE/calls")" "POST /rest/db/scan?folder=tinycloud-peers"
assert_contains "audit approve" "$(cat "$AUDIT")" "approve rocky $N1 reader justin"

check_with_node() {
  (
    TC_ROOT=$ROOT/node
    TC_SOURCED=1
    export TC_ROOT TC_SOURCED
    . "$ROOT/node/agent/apply-peers.sh"
    check_peers_file "$1"
  )
}
assert_jq "node accepts peers.json" "$(check_with_node "$peers")" '.ok == true and (.peers | length) == 1'

out=$(printf 'yes\n' | cmd_approve grace "$N2" anchor justin 2>&1)
assert_contains "second node approved" "$out" "approved grace"
case $out in
  *"approved grace"*) ;;
  *) printf 'second approve said:\n%s\n' "$out" ;;
esac
assert_eq "second node in peers folder" "$(sorted "$GWID" "$N1" "$N2")" "$(folder_ids tinycloud-peers)"
assert_eq "second node in view folder" "$(sorted "$GWID" "$N1" "$N2")" "$(folder_ids tc-view-justin)"
assert_jq "node accepts two peers" "$(check_with_node "$peers")" '.ok == true and (.peers | length) == 2'

out=$(printf 'yes\n' | cmd_approve gouda "$N3" contributor finn 2>&1)
assert_eq "other owner own view folder" "$(sorted "$GWID" "$N3")" "$(folder_ids tc-view-finn)"
assert_eq "justin view unchanged" "$(sorted "$GWID" "$N1" "$N2")" "$(folder_ids tc-view-justin)"
assert_eq "all in peers folder" "$(sorted "$GWID" "$N1" "$N2" "$N3")" "$(folder_ids tinycloud-peers)"

before=$(grep -c '^PUT' "$FAKE/calls")
assert_eq "duplicate name refused" 1 "$(printf 'yes\n' | cmd_approve rocky "$(mkid E)" reader justin > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "duplicate id refused" 1 "$(printf 'yes\n' | cmd_approve other "$N1" reader justin > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "bad role refused" 1 "$(printf 'yes\n' | cmd_approve x1 "$(mkid E)" boss justin > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "bad name refused" 1 "$(printf 'yes\n' | cmd_approve 'Bad Name' "$(mkid E)" reader justin > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "bad owner refused" 1 "$(printf 'yes\n' | cmd_approve x2 "$(mkid E)" reader 'a/b' > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "bad id refused" 1 "$(printf 'yes\n' | cmd_approve x3 NOTANID reader justin > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "gateway id refused" 1 "$(printf 'yes\n' | cmd_approve x4 "$GWID" reader justin > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "missing args refused" 1 "$(printf 'yes\n' | cmd_approve x5 > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "extra args refused" 1 "$(printf 'yes\n' | cmd_approve x6 "$(mkid E)" reader justin extra > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "no syncthing changes from refusals" "$before" "$(grep -c '^PUT' "$FAKE/calls")"
assert_eq "still three nodes" 3 "$(jq length "$APPROVED")"

assert_eq "declined does nothing" 1 "$(printf 'no\n' | cmd_approve nope "$(mkid E)" reader justin > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "declined not saved" 3 "$(jq length "$APPROVED")"
out=$(cmd_approve flag "$(mkid E)" reader justin --yes 2>&1 < /dev/null)
assert_contains "yes flag skips prompt" "$out" "approved flag"

limit=$(jq -nc '[range(0; 64) | {name: ("n" + tostring), id: "X", role: "reader", owner: "o"}]')
mkdir -p "$GW_STATE"
printf '%s' "$limit" > "$APPROVED"
assert_eq "limit of 64 enforced" 1 "$(printf 'yes\n' | cmd_approve extra "$(mkid E)" reader justin > /dev/null 2>&1 && echo 0 || echo 1)"

reset
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
printf 'yes\n' | cmd_approve grace "$N2" anchor justin > /dev/null 2>&1
printf 'yes\n' | cmd_approve gouda "$N3" contributor finn > /dev/null 2>&1

out=$(printf 'yes\n' | cmd_remove rocky 2>&1)
assert_contains "removed message" "$out" "removed rocky"
assert_eq "device deleted" 0 "$([ -f "$FAKE/devices/$N1.json" ] && echo 1 || echo 0)"
assert_eq "status folder deleted" 0 "$([ -f "$FAKE/folders/tc-status-rocky.json" ] && echo 1 || echo 0)"
assert_eq "peers folder devices after remove" "$(sorted "$GWID" "$N2" "$N3")" "$(folder_ids tinycloud-peers)"
assert_eq "view folder devices after remove" "$(sorted "$GWID" "$N2")" "$(folder_ids tc-view-justin)"
assert_jq "peers.json no longer lists it" "$(cat "$peers")" '(.peers | map(.name) | sort) == ["gouda", "grace"]'
assert_jq "approved list after remove" "$(cat "$APPROVED")" 'length == 2'
assert_contains "audit remove" "$(cat "$AUDIT")" "remove rocky $N1"

out=$(printf 'yes\n' | cmd_remove gouda 2>&1)
assert_eq "empty owner view folder deleted" 0 "$([ -f "$FAKE/folders/tc-view-finn.json" ] && echo 1 || echo 0)"
assert_eq "unknown node refused" 1 "$(printf 'yes\n' | cmd_remove nobody > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "bad name refused on remove" 1 "$(printf 'yes\n' | cmd_remove 'a/b' > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "declined remove keeps node" 1 "$(printf 'no\n' | cmd_remove grace > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "grace still approved" 1 "$(jq length "$APPROVED")"

out=$(printf 'yes\n' | cmd_remove grace 2>&1)
assert_contains "warns when list empty" "$out" "no nodes left"
assert_jq "peers.json kept when empty" "$(cat "$peers")" '(.peers | length) == 1'
assert_eq "list empty" "no nodes yet" "$(cmd_list)"

reset
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
printf 'yes\n' | cmd_approve grace "$N2" anchor justin > /dev/null 2>&1
printf '{"connections":{"%s":{"connected":true},"%s":{"connected":false}}}' "$N1" "$N2" > "$FAKE/connections.json"
out=$(cmd_list)
assert_contains "list header" "$out" "NAME"
assert_contains "list online" "$out" "rocky"
assert_contains "list rocky online" "$(printf '%s\n' "$out" | grep rocky)" "online"
assert_contains "list grace offline" "$(printf '%s\n' "$out" | grep grace)" "offline"
assert_not_contains "offline is not online" "$(printf '%s\n' "$out" | grep grace)" " online"

reset
mkdir -p "$GW_HOME/data/syncthing/config" "$GW_HOME/data/relay" "$GW_HOME/data/disco" "$GW_HOME/data/syncthing/tinycloud-peers" "$GW_HOME/state"
printf 'GATEWAY_HOST=gw.example.com\nRELAY_TOKEN=secrettoken\n' > "$GW_HOME/.env"
printf '<configuration><gui><apikey>KEY</apikey></gui></configuration>' > "$GW_HOME/data/syncthing/config/config.xml"
printf 'big' > "$GW_HOME/data/syncthing/config/index-v0.14.0.db"
printf 'cert' > "$GW_HOME/data/relay/relay-cert.pem"
printf 'cert' > "$GW_HOME/data/disco/cert.pem"
printf 'key' > "$GW_HOME/data/disco/key.pem"
printf 'peers' > "$GW_HOME/data/syncthing/tinycloud-peers/peers.json"
printf '[]' > "$APPROVED"
out=$(cmd_backup 2>&1)
assert_contains "backup saved" "$out" "Saved:"
assert_contains "backup scp hint" "$out" "scp root@gw.example.com:"
file=$(find "$GW_BACKUP_DIR" -name 'tinycloud-gateway-*.tar.gz' | head -n 1)
mode=$(stat -c %a "$file" 2> /dev/null || stat -f %Lp "$file")
assert_eq "backup file private" 600 "$mode"
listing=$(tar tzf "$file")
assert_contains "backup has env" "$listing" ".env"
assert_contains "backup has config" "$listing" "data/syncthing/config/config.xml"
assert_contains "backup has relay keys" "$listing" "data/relay/relay-cert.pem"
assert_contains "backup has approved list" "$listing" "state/approved.json"
assert_not_contains "backup skips db" "$listing" "index-v0.14.0.db"
assert_not_contains "backup skips synced files" "$listing" "tinycloud-peers/peers.json"
assert_contains "audit backup" "$(cat "$AUDIT")" "backup "
assert_not_contains "audit has no token" "$(cat "$AUDIT")" "secrettoken"

i=0
while [ "$i" -lt 12 ]; do
  touch "$GW_BACKUP_DIR/tinycloud-gateway-2000010$((i % 10))-0000$i.tar.gz"
  i=$((i + 1))
done
cmd_backup > /dev/null 2>&1
assert_eq "only 10 backups kept" 10 "$(find "$GW_BACKUP_DIR" -name 'tinycloud-gateway-*.tar.gz' | wc -l | tr -d ' ')"

: > "$FAKE/calls"
rm -rf "$GW_HOME/data/syncthing/config" "$GW_HOME/.env"
out=$(printf 'yes\n' | cmd_restore "$file" 2>&1)
assert_contains "restore done" "$out" "restored"
assert_contains "restore stops stack" "$(cat "$FAKE/calls")" "dc down"
assert_contains "restore starts stack" "$(cat "$FAKE/calls")" "dc up -d"
assert_contains "env restored" "$(cat "$GW_HOME/.env")" "RELAY_TOKEN=secrettoken"
assert_eq "config restored" 1 "$([ -f "$GW_HOME/data/syncthing/config/config.xml" ] && echo 1 || echo 0)"

bad=$SANDBOX/bad
mkdir -p "$bad/sub"
printf 'x' > "$bad/evil.txt"
(cd "$bad/sub" && tar czPf "$SANDBOX/dots.tar.gz" ../evil.txt)
tar czPf "$SANDBOX/abs.tar.gz" "$bad/evil.txt" 2> /dev/null
tar czf "$SANDBOX/noconfig.tar.gz" -C "$GW_HOME" .env
printf 'not a tar' > "$SANDBOX/garbage.tar.gz"
assert_eq "dotdot archive refused" 1 "$(printf 'yes\n' | cmd_restore "$SANDBOX/dots.tar.gz" > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "absolute archive refused" 1 "$(printf 'yes\n' | cmd_restore "$SANDBOX/abs.tar.gz" > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "archive without config refused" 1 "$(printf 'yes\n' | cmd_restore "$SANDBOX/noconfig.tar.gz" > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "garbage archive refused" 1 "$(printf 'yes\n' | cmd_restore "$SANDBOX/garbage.tar.gz" > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "missing file refused" 1 "$(printf 'yes\n' | cmd_restore "$SANDBOX/none.tar.gz" > /dev/null 2>&1 && echo 0 || echo 1)"
: > "$FAKE/calls"
assert_eq "declined restore" 1 "$(printf 'no\n' | cmd_restore "$file" > /dev/null 2>&1 && echo 0 || echo 1)"
assert_not_contains "declined restore leaves stack up" "$(cat "$FAKE/calls")" "dc down"

mkdir -p "$GW_STATE/.lock"
assert_eq "lock blocks second run" 1 "$(printf 'yes\n' | cmd_approve lk "$(mkid E)" reader justin > /dev/null 2>&1 && echo 0 || echo 1)"
rm -rf "$GW_STATE/.lock"

assert_contains "help" "$(usage)" "approve NAME DEVICEID ROLE OWNER"
assert_eq "version" "$(cat "$GW/VERSION")" "$(GW_VERSION=$(cat "$GW/VERSION"); echo "$GW_VERSION")"

finish
