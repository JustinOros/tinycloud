#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
SANDBOX=$(mktemp -d)
TC_HOME=$SANDBOX/home
export TC_HOME
mkdir -p "$TC_HOME"
printf '0.1.0\n' > "$TC_HOME/VERSION"
printf 'NODE_NAME=rocky\nRELAY_TOKEN=s3cr3t-token\nWIFI_PASSWORD=hunter2\nWIFI_SSID=HomeNet\nGATEWAY_HOST=gw.example.com\n' > "$TC_HOME/tinycloud.conf"
TC_SOURCED=1
. "$HERE/harness.sh"
. "$TC_ROOT/bin/tinycloud"

CALLS=$SANDBOX/calls
: > "$CALLS"
dc() {
  echo "$*" >> "$CALLS"
  case $1 in
    exec) echo "OK doctor line 198.51.100.7" ;;
    logs) echo "2026-11-21T17:38:38Z log line from 203.0.113.9 using s3cr3t-token and fe80:0:0:0:1:2:3:4" ;;
  esac
}

TZ=America/Phoenix
export TZ

assert_eq "iso line localized" "2026-11-21 10:38:38 AM hello world" "$(localize_line '2026-11-21T17:38:38Z hello world')"
assert_eq "syncthing style line localized" "2026-11-21 10:38:38 AM INFO: x" "$(localize_line '2026-11-21 17:38:38 INFO: x')"
assert_eq "plain line unchanged" "just a line" "$(localize_line 'just a line')"
assert_eq "short line unchanged" "word" "$(localize_line 'word')"

scrubbed=$(printf 'from 203.0.113.9:22000 and fe80:0:0:0:1:2:3:4 at 2026-11-21T17:38:38Z token s3cr3t-token id AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH\n' | scrub)
assert_contains "ipv4 scrubbed" "$scrubbed" "x.x.x.x:22000"
assert_contains "ipv6 scrubbed" "$scrubbed" "x:x:x:x"
assert_contains "token scrubbed" "$scrubbed" "token REDACTED"
assert_contains "timestamp kept" "$scrubbed" "17:38:38Z"
assert_contains "device id kept" "$scrubbed" "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"

: > "$CALLS"
main doctor > /dev/null
assert_eq "doctor runs in the agent container" "exec -T agent sh /app/agent/doctor.sh" "$(cat "$CALLS")"

: > "$CALLS"
main logs bogus > /dev/null 2>&1
assert_eq "bad log component returns 2" 2 "$?"
assert_eq "bad log component runs nothing" 0 "$(wc -l < "$CALLS" | tr -d ' ')"
out=$(main logs syncthing)
assert_eq "logs asks for 200 lines" "logs --no-log-prefix --tail 200 syncthing" "$(cat "$CALLS")"
assert_contains "logs localized" "$out" "2026-11-21 10:38:38 AM log line"

: > "$CALLS"
main debug on > /dev/null
assert_eq "debug on dispatch" "exec -T agent sh /app/agent/debug.sh on" "$(cat "$CALLS")"
: > "$CALLS"
main join > /dev/null
assert_eq "join dispatch" "exec -T agent sh /app/agent/join.sh" "$(cat "$CALLS")"
assert_contains "usage lists join" "$(usage)" "join"
mkdir -p "$TC_HOME/data/library" "$SANDBOX/h"
TC_LINK_DIR=$SANDBOX/h
export TC_LINK_DIR
main path > /dev/null
assert_eq "link created" "$TC_HOME/data/library" "$(readlink "$SANDBOX/h/tinycloud")"
assert_eq "path command" "$TC_HOME/data/library" "$(main path)"
ln -sfn /nowhere "$SANDBOX/h/tinycloud"
main path > /dev/null
assert_eq "wrong link repaired" "$TC_HOME/data/library" "$(readlink "$SANDBOX/h/tinycloud")"
rm "$SANDBOX/h/tinycloud"
mkdir "$SANDBOX/h/tinycloud"
main path > /dev/null
assert_eq "real folder left alone" 0 "$([ -L "$SANDBOX/h/tinycloud" ] && echo 1 || echo 0)"
rmdir "$SANDBOX/h/tinycloud"
printf 'x' > "$SANDBOX/h/tinycloud"
main path > /dev/null
assert_eq "real file left alone" x "$(cat "$SANDBOX/h/tinycloud")"
rm "$SANDBOX/h/tinycloud"
rm -rf "$TC_HOME/data"
main path > /dev/null
assert_eq "no link without library" 0 "$([ -e "$SANDBOX/h/tinycloud" ] && echo 1 || echo 0)"
unset TC_LINK_DIR
assert_contains "usage lists path" "$(usage)" "path"
main debug sideways > /dev/null 2>&1
assert_eq "debug bad arg returns 2" 2 "$?"

TC_SUPPORT_OUT=$SANDBOX/bundle.txt
export TC_SUPPORT_OUT
main support > /dev/null
bundle=$(cat "$TC_SUPPORT_OUT")
assert_contains "bundle has version" "$bundle" "version: 0.1.0"
assert_contains "bundle has doctor" "$bundle" "== doctor =="
assert_contains "bundle has config" "$bundle" "NODE_NAME=rocky"
assert_contains "token redacted in config" "$bundle" "RELAY_TOKEN=REDACTED"
assert_contains "wifi password redacted" "$bundle" "WIFI_PASSWORD=REDACTED"
assert_contains "wifi name redacted" "$bundle" "WIFI_SSID=REDACTED"
assert_not_contains "no token anywhere" "$bundle" "s3cr3t-token"
assert_not_contains "no password anywhere" "$bundle" "hunter2"
assert_not_contains "no ipv4 anywhere" "$bundle" "198.51.100.7"
assert_not_contains "no log ipv4 anywhere" "$bundle" "203.0.113.9"
assert_not_contains "no ipv6 anywhere" "$bundle" "fe80:0:0:0:1:2:3:4"

: > "$CALLS"
printf 'no\n' | main leave > /dev/null
assert_eq "leave cancelled by default answer" 0 "$(wc -l < "$CALLS" | tr -d ' ')"
out=$(printf 'yes\n' | main leave)
assert_contains "leave runs leave script" "$(cat "$CALLS")" "exec -T agent sh /app/agent/leave.sh"
assert_contains "leave stops the agent" "$(cat "$CALLS")" "stop agent"
assert_contains "leave tells the owner what to run" "$out" "tinycloud remove rocky"

: > "$CALLS"
main confirm > /dev/null
assert_eq "confirm without name only lists" "exec -T agent sh /app/agent/confirm.sh" "$(cat "$CALLS")"
: > "$CALLS"
main confirm grace > /dev/null
assert_contains "confirm with name confirms" "$(cat "$CALLS")" "confirm.sh grace"
assert_contains "confirm with name applies now" "$(cat "$CALLS")" "apply-peers.sh"

: > "$CALLS"
inode_before=$(find "$TC_HOME/tinycloud.conf" -printf '%i' 2> /dev/null || stat -f %i "$TC_HOME/tinycloud.conf")
out=$(printf 'n3w-T0ken_9\n' | main relay-token 2>&1)
assert_contains "relay-token confirms" "$out" "Relay token updated."
assert_contains "relay-token writes the new token" "$(cat "$TC_HOME/tinycloud.conf")" "RELAY_TOKEN=n3w-T0ken_9"
assert_eq "old token is gone" 0 "$(grep -c 's3cr3t-token' "$TC_HOME/tinycloud.conf")"
assert_contains "other settings kept" "$(cat "$TC_HOME/tinycloud.conf")" "GATEWAY_HOST=gw.example.com"
assert_contains "wifi password kept" "$(cat "$TC_HOME/tinycloud.conf")" "WIFI_PASSWORD=hunter2"
assert_eq "config file keeps its inode" "$inode_before" "$(find "$TC_HOME/tinycloud.conf" -printf '%i' 2> /dev/null || stat -f %i "$TC_HOME/tinycloud.conf")"
assert_contains "relay-token applies it now" "$(cat "$CALLS")" "relay.sh"
assert_not_contains "token never on the command line" "$(cat "$CALLS")" "n3w-T0ken_9"
before=$(cat "$TC_HOME/tinycloud.conf")
: > "$CALLS"
out=$(printf 'bad token!\n' | main relay-token 2>&1)
printf 'bad token!\n' | main relay-token > /dev/null 2>&1
bad_rc=$?
assert_eq "bad token refused" 1 "$bad_rc"
assert_contains "bad token explained" "$out" "not a valid token"
assert_eq "bad token changes nothing" "$before" "$(cat "$TC_HOME/tinycloud.conf")"
assert_eq "bad token does not touch syncthing" "" "$(cat "$CALLS")"
printf '' | main relay-token > /dev/null 2>&1
empty_rc=$?
assert_eq "empty token refused" 1 "$empty_rc"
assert_contains "help lists relay-token" "$(usage)" "relay-token"

assert_eq "version prints" "0.1.0" "$(main version)"
main nonsense > /dev/null 2>&1
assert_eq "unknown command returns 2" 2 "$?"

finish
