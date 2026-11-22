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
printf 'GATEWAY_HOST=gw.example.com\n' > "$GW_HOME/node-lines.txt"
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
assert_contains "backup has node lines" "$listing" "node-lines.txt"
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

assert_contains "config shows saved lines" "$(cmd_config)" "GATEWAY_HOST=gw.example.com"
rm -f "$GW_HOME/node-lines.txt"
assert_eq "config without file fails" 1 "$(cmd_config > /dev/null 2>&1 && echo 0 || echo 1)"
assert_contains "help lists config" "$(usage)" "config"
assert_contains "help" "$(usage)" "approve NAME DEVICEID ROLE OWNER"
assert_eq "version" "$(cat "$GW/VERSION")" "$(GW_VERSION=$(cat "$GW/VERSION"); echo "$GW_VERSION")"

reset
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
printf 'yes\n' | cmd_approve grace "$N2" anchor justin > /dev/null 2>&1
printf 'yes\n' | cmd_approve brie "$N3" reader finn > /dev/null 2>&1
printf '{"connections":{"%s":{"connected":true},"%s":{"connected":false},"%s":{"connected":true}}}' "$N1" "$N2" "$N3" > "$FAKE/connections.json"
printf '{"v":1,"name":"rocky","role":"reader","version":"0.1.0","percent_stored":42,"free_bytes":5000000000,"low_space":false,"case_conflicts":1,"time":"2026-11-21T19:00:00Z"}' > "$FOLDERS_DIR/tc-status-rocky/status.json"
printf '{"v":1,"name":"brie","role":"hacker","version":"0.1.0","percent_stored":150,"free_bytes":1,"low_space":false,"case_conflicts":0,"time":"2026-11-21T19:00:00Z"}' > "$FOLDERS_DIR/tc-status-brie/status.json"
cmd_aggregate
full=$(cat "$GW_STATE/view.json")
assert_jq "view shape" "$full" '.version == 1 and (.generated | test("^[0-9]{4}-")) and (.nodes | length) == 3'
assert_jq "rocky online with status" "$full" '(.nodes[] | select(.name == "rocky")) | .online == true and .status.percent_stored == 42 and .status.case_conflicts == 1 and .status.reported == "2026-11-21T19:00:00Z" and .role == "reader"'
assert_jq "node status keeps only known fields" "$full" '(.nodes[] | select(.name == "rocky") | .status | keys | sort) == ["booted","case_conflicts","free_bytes","low_space","percent_stored","reported","version"]'
assert_jq "grace offline with no status" "$full" '(.nodes[] | select(.name == "grace")) | .online == false and .status == null'
assert_jq "invalid status rejected" "$full" '(.nodes[] | select(.name == "brie")) | .status == null and .role == "reader"'
assert_jq "justin view holds only his nodes" "$(cat "$FOLDERS_DIR/tc-view-justin/view.json")" '(.nodes | length) == 2 and all(.nodes[]; .owner == "justin")'
assert_jq "finn view holds only his nodes" "$(cat "$FOLDERS_DIR/tc-view-finn/view.json")" '(.nodes | length) == 1 and .nodes[0].name == "brie"'
assert_eq "no temp file left" 0 "$(find "$FOLDERS_DIR" -name '.syncthing.view.json.tmp' | wc -l | tr -d ' ')"

before=$(cat "$GW_STATE/view.json")
sleep 1
cmd_aggregate
assert_eq "unchanged view is not rewritten" "$before" "$(cat "$GW_STATE/view.json")"

printf '{"connections":{"%s":{"connected":false},"%s":{"connected":false},"%s":{"connected":true}}}' "$N1" "$N2" "$N3" > "$FAKE/connections.json"
cmd_aggregate
assert_jq "changed state is rewritten" "$(cat "$GW_STATE/view.json")" '(.nodes[] | select(.name == "rocky")) | .online == false'
assert_jq "owner view updated too" "$(cat "$FOLDERS_DIR/tc-view-justin/view.json")" '(.nodes[] | select(.name == "rocky")) | .online == false'

printf 'garbage' > "$FOLDERS_DIR/tc-status-rocky/status.json"
cmd_aggregate
assert_jq "garbage status becomes null" "$(cat "$GW_STATE/view.json")" '(.nodes[] | select(.name == "rocky")) | .status == null'

printf '{"v":1,"name":"rocky","role":"reader","version":"0.1.0","percent_stored":42,"free_bytes":5,"low_space":false,"case_conflicts":0,"time":"2026-11-21T19:00:00Z","x":"%s"}' "$(printf 'a%.0s' $(seq 1 3000))" > "$FOLDERS_DIR/tc-status-rocky/status.json"
cmd_aggregate
assert_jq "oversized status becomes null" "$(cat "$GW_STATE/view.json")" '(.nodes[] | select(.name == "rocky")) | .status == null'

mkdir "$GW_STATE/.lock"
printf '%s' "$$" > "$GW_STATE/.lock/pid"
cmd_aggregate
assert_eq "busy lock skips quietly" 0 "$?"
unlock

reset
assert_jq "view with no nodes" "$(cmd_view)" '.version == 1 and (.nodes | length) == 0'
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
rm -f "$GW_STATE/view.json"
assert_jq "view builds when missing" "$(cmd_view)" '(.nodes | length) == 1'
assert_contains "help lists aggregate" "$(usage)" "aggregate"
assert_contains "help lists view" "$(usage)" "view"

reset
nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$GW_STATE"
cat > "$GW_STATE/view.json" << EOT
{"version":1,"generated":"$nowiso","nodes":[
{"name":"grace","role":"contributor","owner":"justin","online":false,"status":null},
{"name":"adrian","role":"contributor","owner":"justin","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":167600000000,"low_space":false,"case_conflicts":0,"reported":"$nowiso"}},
{"name":"brie","role":"reader","owner":"finn","online":true,"status":{"version":"0.1.0","percent_stored":40,"free_bytes":12884901888,"low_space":true,"case_conflicts":2,"reported":"2020-01-01T00:00:00Z"}},
{"name":"odd","role":"reader","owner":"zed","online":null,"status":null}]}
EOT
st=$(cmd_status)
assert_contains "status summary" "$st" "TinyCloud: 4 nodes, 2 online, 3 with warnings. Updated just now."
assert_contains "status header" "$st" "NODE"
assert_contains "status shows free space" "$st" "156.1 GB"
assert_contains "status shows exact gigabytes" "$st" "12.0 GB"
assert_contains "status shows just now" "$st" "just now"
assert_contains "status shows low space" "$st" "Low space"
assert_contains "status shows conflicts" "$st" "2 name conflicts"
assert_contains "status shows stale" "$st" "Stale status"
assert_contains "status shows days ago" "$st" "days ago"
assert_contains "status shows no status" "$st" "No status yet"
assert_contains "status shows unknown" "$st" "Unknown"
assert_eq "status has no color by default" 0 "$(printf '%s' "$st" | grep -c "$(printf '\033')")"
assert_eq "status sorted by owner then name" "brie adrian grace odd" "$(printf '%s\n' "$st" | awk 'NR > 3 {printf "%s ", $1}' | sed 's/ $//')"
stc=$(cmd_status --color)
assert_eq "status color adds escapes" 1 "$([ "$(printf '%s' "$stc" | grep -c "$(printf '\033')")" -gt 0 ] && echo 1 || echo 0)"
assert_eq "bad status flag fails" 1 "$(cmd_status --bogus > /dev/null 2>&1 && echo 0 || echo 1)"
assert_contains "help lists status" "$(usage)" "status"
printf '{"version":1,"generated":"%s","nodes":[]}\n' "$nowiso" > "$GW_STATE/view.json"
assert_contains "status with no nodes" "$(cmd_status)" "No nodes yet."

reset
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
cmd_aggregate
jq -c '.generated = "2020-01-01T00:00:00Z"' "$GW_STATE/view.json" > "$GW_STATE/view.tmp" && mv "$GW_STATE/view.tmp" "$GW_STATE/view.json"
cmd_aggregate
assert_contains "aggregate records its run time" "$(cat "$GW_STATE/aggregated.at")" "$(date +%s | cut -c1-6)"
assert_eq "view generated follows the last run" true "$(cmd_view | jq -r '.generated | startswith("2020") | not')"
assert_contains "status says just now after a run" "$(cmd_status)" "Updated just now."
rm -f "$GW_STATE/aggregated.at"
assert_contains "view falls back to stored time" "$(cmd_view)" '"generated":"2020-01-01T00:00:00Z"'

reset
printf 'GATEWAY_HOST=gw.example.com\nRELAY_TOKEN=oldtoken\n' > "$GW_HOME/.env"
printf 'GATEWAY_HOST=gw.example.com\nGATEWAY_ID=X\nRELAY_TOKEN=oldtoken\nOTHER=keep\n' > "$GW_HOME/node-lines.txt"
chmod 600 "$GW_HOME/.env" "$GW_HOME/node-lines.txt"
out=$(printf 'no\n' | cmd_rotate_token 2>&1)
assert_contains "rotate asks first" "$out" "cancelled"
assert_contains "rotate cancelled keeps token" "$(cat "$GW_HOME/.env")" "RELAY_TOKEN=oldtoken"
out=$(cmd_rotate_token --yes 2>&1)
newtok=$(sed -n 's/^RELAY_TOKEN=//p' "$GW_HOME/.env")
assert_eq "new token differs" 1 "$([ "$newtok" != oldtoken ] && echo 1 || echo 0)"
assert_eq "new token is valid" 32 "${#newtok}"
assert_contains "env keeps host" "$(cat "$GW_HOME/.env")" "GATEWAY_HOST=gw.example.com"
assert_contains "node lines get the token" "$(cat "$GW_HOME/node-lines.txt")" "RELAY_TOKEN=$newtok"
assert_contains "node lines keep other values" "$(cat "$GW_HOME/node-lines.txt")" "OTHER=keep"
assert_eq "old token gone from env" 0 "$(grep -c oldtoken "$GW_HOME/.env")"
assert_eq "old token gone from node lines" 0 "$(grep -c oldtoken "$GW_HOME/node-lines.txt")"
assert_eq "env stays private" 600 "$(stat -c %a "$GW_HOME/.env" 2> /dev/null || stat -f %Lp "$GW_HOME/.env")"
assert_eq "node lines stay private" 600 "$(stat -c %a "$GW_HOME/node-lines.txt" 2> /dev/null || stat -f %Lp "$GW_HOME/node-lines.txt")"
assert_contains "output shows the new token" "$out" "RELAY_TOKEN=$newtok"
assert_contains "output says what nodes run" "$out" "tinycloud relay-token"
assert_contains "relay restarted" "$(cat "$FAKE/calls")" "dc up -d --force-recreate relay"
assert_contains "audit notes the rotation" "$(cat "$AUDIT")" "rotate-token"
assert_eq "audit never holds the token" 0 "$(grep -c "$newtok" "$AUDIT")"
rm -f "$GW_HOME/.env"
assert_eq "rotate needs gateway settings" 1 "$(cmd_rotate_token --yes > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "rotate rejects odd args" 1 "$(cmd_rotate_token --bogus > /dev/null 2>&1 && echo 0 || echo 1)"
assert_contains "help lists rotate-token" "$(usage)" "rotate-token"

reset
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
printf 'yes\n' | cmd_approve grace "$N2" reader justin > /dev/null 2>&1
printf 'yes\n' | cmd_approve brie "$N3" reader finn > /dev/null 2>&1
printf '{"connections":{"%s":{"connected":true},"%s":{"connected":true},"%s":{"connected":true}}}' "$N1" "$N2" "$N3" > "$FAKE/connections.json"
printf '{"v":1,"name":"rocky","role":"reader","version":"0.1.0","percent_stored":42,"free_bytes":5000000000,"low_space":false,"case_conflicts":0,"time":"2026-11-21T19:00:00Z","booted":"2026-11-19T10:00:00Z"}' > "$FOLDERS_DIR/tc-status-rocky/status.json"
printf '{"v":1,"name":"grace","role":"reader","version":"0.1.0","percent_stored":42,"free_bytes":5000000000,"low_space":false,"case_conflicts":0,"time":"2026-11-21T19:00:00Z"}' > "$FOLDERS_DIR/tc-status-grace/status.json"
printf '{"v":1,"name":"brie","role":"reader","version":"0.1.0","percent_stored":42,"free_bytes":5000000000,"low_space":false,"case_conflicts":0,"time":"2026-11-21T19:00:00Z","booted":"yesterday"}' > "$FOLDERS_DIR/tc-status-brie/status.json"
cmd_aggregate
assert_jq "booted passes through" "$(cat "$GW_STATE/view.json")" '(.nodes[] | select(.name == "rocky")) | .status.booted == "2026-11-19T10:00:00Z"'
assert_jq "missing booted is null" "$(cat "$GW_STATE/view.json")" '(.nodes[] | select(.name == "grace")) | .status.booted == null'
assert_jq "bad booted rejects the status" "$(cat "$GW_STATE/view.json")" '(.nodes[] | select(.name == "brie")) | .status == null'

reset
nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$GW_STATE"
cat > "$GW_STATE/view.json" << EOT
{"version":1,"generated":"$nowiso","nodes":[
{"name":"old","role":"reader","owner":"a","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":1000000000,"low_space":false,"case_conflicts":0,"reported":"$nowiso","booted":"2020-01-01T00:00:00Z"}},
{"name":"fresh","role":"reader","owner":"a","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":1000000000,"low_space":false,"case_conflicts":0,"reported":"$nowiso","booted":"$nowiso"}},
{"name":"down","role":"reader","owner":"a","online":false,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":1000000000,"low_space":false,"case_conflicts":0,"reported":"$nowiso","booted":"2020-01-01T00:00:00Z"}},
{"name":"legacy","role":"reader","owner":"a","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":1000000000,"low_space":false,"case_conflicts":0,"reported":"$nowiso","booted":null}}]}
EOT
st=$(cmd_status)
assert_contains "status has an uptime column" "$st" "UPTIME"
row() { printf '%s\n' "$st" | awk -v n="$1" '$1 == n'; }
assert_contains "old boot shows days" "$(row old)" "days"
assert_contains "fresh boot shows minutes" "$(row fresh)" "1 min"
assert_eq "offline node has no uptime" 0 "$(row down | grep -c 'days')"
assert_eq "node without booted shows a dash" 1 "$(row legacy | awk '{print $5}' | grep -c '^-$')"

reset
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
printf '{"connections":{"%s":{"connected":true}}}' "$N1" > "$FAKE/connections.json"
WOUT=$SANDBOX/watch.out
GW_WATCH_INTERVAL=1 cmd_status --watch > "$WOUT" 2>&1 &
watch_pid=$!
sleep 1
printf '{"connections":{"%s":{"connected":false}}}' "$N1" > "$FAKE/connections.json"
sleep 3
kill "$watch_pid" 2> /dev/null
wait "$watch_pid" 2> /dev/null
wo=$(cat "$WOUT")
assert_contains "watch shows the node online first" "$wo" "Online"
assert_contains "watch picks up the node going offline" "$wo" "Offline"
assert_contains "watch clears the screen" "$wo" "$(printf '\033[H\033[2J')"
assert_contains "watch says how to stop" "$wo" "Ctrl+C"
assert_contains "watch states the interval" "$wo" "every 1 seconds"
assert_eq "watch output has no color when not a terminal" 0 "$(printf '%s' "$wo" | grep -c "$(printf '\033')\[3")"
rm -rf "$GW_STATE/.lock"
assert_contains "help lists watch" "$(usage)" "--watch"

reset
printf '{"connections":null}' > "$FAKE/connections.json"
printf 'yes\n' | cmd_approve rocky "$N1" reader justin > /dev/null 2>&1
cmd_aggregate
assert_jq "unknown connection state is null" "$(cat "$GW_STATE/view.json")" '.nodes[0].online == null'

finish
