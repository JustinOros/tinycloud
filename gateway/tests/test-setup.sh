#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(cd "$HERE/.." && pwd)
REPO=$(cd "$GW/.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
GW_HOME=$SANDBOX/gw
export GW_HOME

run_setup() {
  rs_os=$1
  rs_input=$2
  shift 2
  GW_OS_RELEASE=$HERE/fixtures/$rs_os SETUP_INPUT=$rs_input sh "$REPO/setup.sh" "$@" 2>&1
}

printf 'gw.example.com\n\n\n\n\ny\n' > "$SANDBOX/in1"
out=$(run_setup debian13 "$SANDBOX/in1" --dry-run)
assert_contains "banner" "$out" "TinyCloud gateway setup"
assert_contains "os shown" "$out" "System: debian 13 (trixie)"
assert_contains "host in plan" "$out" "Hostname: gw.example.com"
assert_contains "ports in plan" "$out" "22000, 22067, and 8443"
assert_contains "ssh port default" "$out" "open only ports 22 (SSH)"
assert_contains "dry run finishes" "$out" "dry run finished, nothing changed"

printf 'gw.example.com\n2222\n\n\n\ny\n' > "$SANDBOX/in2"
out=$(run_setup ubuntu2404 "$SANDBOX/in2" --dry-run)
assert_contains "custom ssh port" "$out" "open only ports 2222 (SSH)"
assert_contains "ubuntu shown" "$out" "System: ubuntu 24.04 (noble)"
assert_contains "ubuntu docker repo" "$out" "download.docker.com/linux/ubuntu"

printf 'gw.example.com\n\n\n\n\nn\n' > "$SANDBOX/in3"
out=$(run_setup debian13 "$SANDBOX/in3" --dry-run)
assert_contains "declined" "$out" "cancelled"
assert_not_contains "declined runs nothing" "$out" "dry run finished"

printf 'bad/host\ngw.example.com\n\n\n\n\ny\n' > "$SANDBOX/in4"
out=$(run_setup debian13 "$SANDBOX/in4" --dry-run)
assert_contains "bad host explained" "$out" "not a valid hostname"
assert_contains "good host after retry" "$out" "Hostname: gw.example.com"

printf 'a/b\nc/d\ne/f\n' > "$SANDBOX/in5"
out=$(run_setup debian13 "$SANDBOX/in5" --dry-run)
assert_contains "gives up after three bad hosts" "$out" "no valid hostname"

printf 'gw.example.com\n\n\n\n9pm\ny\n' > "$SANDBOX/in7"
out=$(run_setup debian13 "$SANDBOX/in7" --dry-run)
assert_contains "custom reboot time planned" "$out" "reboot at 9:00 PM when an update needs it"
printf 'gw.example.com\n\n\n\nnever\n5am\ny\n' > "$SANDBOX/in8"
out=$(run_setup debian13 "$SANDBOX/in8" --dry-run)
assert_contains "bad reboot time explained" "$out" "not a valid time"
assert_contains "reboot time after retry" "$out" "reboot at 5:00 AM when an update needs it"
printf 'gw.example.com\n\n\nn\ny\n' > "$SANDBOX/in9"
out=$(run_setup debian13 "$SANDBOX/in9" --dry-run)
assert_contains "no auto reboot planned" "$out" "not reboot automatically"
assert_not_contains "no reboot time asked" "$out" "Reboot time"
printf 'gw.example.com\n\nPacific/Honolulu\n\n\ny\n' > "$SANDBOX/in10"
out=$(run_setup debian13 "$SANDBOX/in10" --dry-run)
assert_contains "time zone change planned" "$out" "set the server time zone to Pacific/Honolulu"
assert_contains "time zone applied" "$out" "timedatectl set-timezone Pacific/Honolulu"
printf 'gw.example.com\n\nNope/Zone\nPacific/Honolulu\n\n\ny\n' > "$SANDBOX/in11"
out=$(run_setup debian13 "$SANDBOX/in11" --dry-run)
assert_contains "bad time zone explained" "$out" "not a time zone on this server"
assert_contains "time zone after retry" "$out" "set the server time zone to Pacific/Honolulu"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com)
assert_not_contains "yes mode keeps the time zone" "$out" "set the server time zone"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com --timezone Pacific/Honolulu)
assert_contains "time zone flag" "$out" "set the server time zone to Pacific/Honolulu"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com --timezone Nope/Zone)
assert_contains "bad time zone flag refused" "$out" "no valid time zone"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com --auto-reboot no)
assert_contains "flag turns reboot off" "$out" "not reboot automatically"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com --auto-reboot maybe)
assert_contains "bad reboot flag refused" "$out" "--auto-reboot must be yes or no"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com --reboot-time 25:00)
assert_contains "bad reboot time flag refused" "$out" "no valid reboot time"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com)
assert_contains "yes mode reboots at 4 AM" "$out" "reboot at 4:00 AM when an update needs it"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com --ssh-port 2200)
assert_contains "yes mode runs" "$out" "dry run finished, nothing changed"
assert_contains "yes mode port" "$out" "open only ports 2200 (SSH)"
assert_not_contains "yes mode no prompts" "$out" "[Y/n]"

out=$(run_setup debian13 /dev/null --dry-run --yes)
assert_contains "yes needs host" "$out" "--yes needs --host"
out=$(run_setup debian13 /dev/null --dry-run --bogus)
assert_contains "unknown flag" "$out" "usage:"
out=$(run_setup debian13 /dev/null --dry-run --yes --host gw.example.com --ssh-port 99999)
assert_contains "bad port refused" "$out" "bad SSH port"

out=$(run_setup fedora /dev/null --dry-run --yes --host gw.example.com)
assert_contains "fedora refused" "$out" "unsupported system"
out=$(run_setup debian11 /dev/null --dry-run --yes --host gw.example.com)
assert_contains "debian 11 refused" "$out" "unsupported system"

mkdir -p "$GW_HOME"
printf 'GATEWAY_HOST=old.example.com\nRELAY_TOKEN=x\n' > "$GW_HOME/.env"
printf '\n\n\n\n\ny\n' > "$SANDBOX/in6"
out=$(run_setup debian13 "$SANDBOX/in6" --dry-run)
assert_contains "existing host is the default" "$out" "Hostname: old.example.com"
assert_contains "existing install noted" "$out" "keep the existing gateway identity"
rm -f "$GW_HOME/.env"

out=$(run_setup debian13 "$SANDBOX/missing-input-file" --dry-run)
assert_contains "no terminal explained" "$out" "no terminal to ask questions on"

SETUP_NO_MAIN=1
SETUP_SELF_DIR=$REPO
export SETUP_NO_MAIN SETUP_SELF_DIR
. "$REPO/setup.sh"

printf 'y\nn\n\nanything\n' > "$SANDBOX/answers"
exec 3< "$SANDBOX/answers"
ask_yes "q" y > /dev/null && a=yes || a=no
assert_eq "y answers yes" yes "$a"
ask_yes "q" y > /dev/null && a=yes || a=no
assert_eq "n answers no" no "$a"
ask_yes "q" y > /dev/null && a=yes || a=no
assert_eq "empty uses default yes" yes "$a"
ask_yes "q" y > /dev/null && a=yes || a=no
assert_eq "junk answers no" no "$a"
ask_yes "q" y > /dev/null && a=yes || a=no
assert_eq "end of input answers no" no "$a"
exec 3<&-

printf 'typed\n\n' > "$SANDBOX/answers"
exec 3< "$SANDBOX/answers"
ask_value "q" "dflt" > /dev/null
assert_eq "typed value used" typed "$ANSWER"
ask_value "q" "dflt" > /dev/null
assert_eq "empty uses default" dflt "$ANSWER"
exec 3<&-

resolve_host() { echo "203.0.113.5"; }
local_ips() { printf '127.0.0.1\n203.0.113.5\n'; }
assert_contains "dns matches" "$(check_dns gw.example.com)" "points at this server (203.0.113.5)"
local_ips() { printf '127.0.0.1\n10.0.0.2\n'; }
assert_contains "dns elsewhere" "$(check_dns gw.example.com)" "not an address on this server"
resolve_host() { echo ""; }
assert_contains "dns missing" "$(check_dns gw.example.com)" "does not resolve yet"
assert_contains "ip as host" "$(check_dns 203.0.113.5)" "a hostname is better"

ASSUME_YES=false
exec 3< /dev/null
assert_eq "missing tool declined" 1 "$(ensure_tool definitely-missing-tool > /dev/null 2>&1 && echo 0 || echo 1)"
exec 3<&-
ASSUME_YES=true
DRY_RUN=true
assert_contains "missing tool install planned" "$(ensure_tool definitely-missing-tool 2>&1)" "+ apt-get install -y definitely-missing-tool"
assert_eq "present tool is quiet" "" "$(ensure_tool sh)"
ASSUME_YES=false
DRY_RUN=false

mkdir -p "$SANDBOX/up/tinycloud-main/gateway"
printf 'echo hi\n' > "$SANDBOX/up/tinycloud-main/gateway/gateway.sh"
download_tarball() { tar czf - -C "$SANDBOX/up" tinycloud-main; }
SETUP_SRC=$SANDBOX/src
mkdir -p "$SETUP_SRC"
printf 'old' > "$SETUP_SRC/stale"
out=$(fetch_tree 2>&1)
assert_contains "download announced" "$out" "Downloading TinyCloud"
fetch_tree > /dev/null 2>&1
assert_eq "tree extracted" 1 "$([ -f "$SETUP_SRC/gateway/gateway.sh" ] && echo 1 || echo 0)"
assert_eq "old tree replaced" 0 "$([ -e "$SETUP_SRC/stale" ] && echo 1 || echo 0)"

rm -rf "$SANDBOX/up/tinycloud-main/gateway"
mkdir -p "$SANDBOX/up/tinycloud-main/other"
printf 'keep' > "$SETUP_SRC/keepme"
assert_eq "wrong download refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "wrong download keeps old tree" 1 "$([ -f "$SETUP_SRC/keepme" ] && echo 1 || echo 0)"

download_tarball() { printf 'not a tarball'; }
assert_eq "garbage download refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"

SETUP_SRC=/
assert_eq "root source refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"
SETUP_SRC=$SANDBOX/src
TC_REPO='bad repo'
assert_eq "bad repo refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"
TC_REPO=JustinOros/tinycloud
TC_REF='main;rm'
assert_eq "bad ref refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"
TC_REF=main

SELF_DIR=$SANDBOX/nowhere
download_tarball() { tar czf - -C "$SANDBOX/up" tinycloud-main; }
mkdir -p "$SANDBOX/up/tinycloud-main/gateway"
printf 'echo hi\n' > "$SANDBOX/up/tinycloud-main/gateway/gateway.sh"
find_tree > /dev/null 2>&1
assert_eq "find_tree downloads when not in a checkout" "$SANDBOX/src" "$SRC"
SELF_DIR=$REPO
find_tree
assert_eq "find_tree uses the checkout" "$REPO" "$SRC"

finish
