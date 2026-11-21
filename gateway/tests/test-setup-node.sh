#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(cd "$HERE/.." && pwd)
REPO=$(cd "$GW/.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
NODE_HOME=$SANDBOX/node
export NODE_HOME

mkid() {
  mi=$1
  printf '%s%s%s%s%s%s%s%s' "$(printf "$mi%.0s" 1 2 3 4 5 6 7)-" "$(printf "$mi%.0s" 1 2 3 4 5 6 7)-" "$(printf "$mi%.0s" 1 2 3 4 5 6 7)-" "$(printf "$mi%.0s" 1 2 3 4 5 6 7)-" "$(printf "$mi%.0s" 1 2 3 4 5 6 7)-" "$(printf "$mi%.0s" 1 2 3 4 5 6 7)-" "$(printf "$mi%.0s" 1 2 3 4 5 6 7)-" "$(printf "$mi%.0s" 1 2 3 4 5 6 7)"
}
ID1=$(mkid A)
ID2=$(mkid B)
ID3=$(mkid C)

cat > "$SANDBOX/lines" << EOT
GATEWAY_HOST=gw.example.com
GATEWAY_ID=$ID1
RELAY_ID=$ID2
DISCOVERY_ID=$ID3
RELAY_TOKEN=tok123
EOT

run_setup() {
  rs_os=$1
  rs_input=$2
  shift 2
  GW_OS_RELEASE=$HERE/fixtures/$rs_os SETUP_INPUT=$rs_input SETUP_USER=tester SETUP_USER_HOME=$SANDBOX/home sh "$REPO/setup-node.sh" "$@" 2>&1
}

mkdir -p "$SANDBOX/home"

{
  printf 'adrian\njustin\ncontributor\nAmerica/Phoenix\n'
  cat "$SANDBOX/lines"
  printf '\ny\n'
} > "$SANDBOX/in1"
out=$(run_setup debian13 "$SANDBOX/in1" --dry-run)
assert_contains "banner" "$out" "TinyCloud node setup"
assert_contains "os shown" "$out" "System: debian 13 (trixie)"
assert_contains "plan node" "$out" "Node:     adrian (owner justin, role contributor)"
assert_contains "plan gateway" "$out" "Gateway:  gw.example.com"
assert_contains "plan timezone" "$out" "Timezone: America/Phoenix"
assert_contains "dry run finishes" "$out" "dry run finished, nothing changed"
assert_not_contains "token never printed" "$out" "tok123"
assert_eq "dry run writes nothing" 0 "$([ -e "$NODE_HOME" ] && echo 1 || echo 0)"

out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian --owner justin --role anchor --timezone UTC --config "$SANDBOX/lines")
assert_contains "yes mode runs" "$out" "dry run finished, nothing changed"
assert_contains "yes mode role" "$out" "role anchor"
assert_contains "docker compose planned" "$out" "+ docker compose up -d --build"
assert_contains "command link planned" "$out" "ln -sfn"
assert_contains "shortcut planned" "$out" "$SANDBOX/home/tinycloud"

out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian)
assert_contains "yes needs config" "$out" "--yes needs --name, --owner, and --config"
out=$(run_setup debian13 /dev/null --dry-run --bogus)
assert_contains "unknown flag" "$out" "usage:"
out=$(run_setup debian13 /dev/null --dry-run --yes --name "Bad Name" --owner justin --config "$SANDBOX/lines")
assert_contains "bad name refused" "$out" "bad node name"
out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian --owner justin --role admin --config "$SANDBOX/lines")
assert_contains "bad role refused" "$out" "bad role"
out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian --owner justin --timezone 'a b' --config "$SANDBOX/lines")
assert_contains "bad timezone refused" "$out" "bad timezone"
out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian --owner justin --config "$SANDBOX/missing")
assert_contains "missing config refused" "$out" "cannot read"

sed 's/tok123/REDACTED/' "$SANDBOX/lines" > "$SANDBOX/redacted"
out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian --owner justin --config "$SANDBOX/redacted")
assert_contains "placeholder token refused" "$out" "placeholder"
sed 's/^GATEWAY_ID=.*/GATEWAY_ID=nope/' "$SANDBOX/lines" > "$SANDBOX/badid"
out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian --owner justin --config "$SANDBOX/badid")
assert_contains "bad id refused" "$out" "GATEWAY_ID is missing or not valid"
grep -v '^RELAY_TOKEN' "$SANDBOX/lines" > "$SANDBOX/notoken"
out=$(run_setup debian13 /dev/null --dry-run --yes --name adrian --owner justin --config "$SANDBOX/notoken")
assert_contains "missing token refused" "$out" "RELAY_TOKEN is missing"

out=$(run_setup fedora /dev/null --dry-run --yes --name adrian --owner justin --config "$SANDBOX/lines")
assert_contains "fedora refused" "$out" "unsupported system"
out=$(run_setup debian11 /dev/null --dry-run --yes --name adrian --owner justin --config "$SANDBOX/lines")
assert_contains "debian 11 refused" "$out" "unsupported system"

{
  printf 'bad name\nadrian\njustin\nbogus\nreader\nUTC\n'
  printf 'GATEWAY_HOST=gw.example.com\n\n'
  cat "$SANDBOX/lines"
  printf '\ny\n'
} > "$SANDBOX/in2"
out=$(run_setup debian13 "$SANDBOX/in2" --dry-run)
assert_contains "retries a bad name" "$out" "That is not valid."
assert_contains "retries incomplete gateway lines" "$out" "GATEWAY_ID is missing or not valid."
assert_contains "ends with a valid plan" "$out" "Node:     adrian (owner justin, role reader)"

printf 'adrian\njustin\nreader\nUTC\n%s\n\nn\n' "$(cat "$SANDBOX/lines")" > "$SANDBOX/in3"
out=$(run_setup debian13 "$SANDBOX/in3" --dry-run)
assert_contains "declined" "$out" "cancelled"
assert_not_contains "declined runs nothing" "$out" "dry run finished"

out=$(run_setup debian13 "$SANDBOX/missing-input" --dry-run)
assert_contains "no terminal explained" "$out" "no terminal to ask questions on"

SETUP_NO_MAIN=1
SETUP_SELF_DIR=$REPO
export SETUP_NO_MAIN SETUP_SELF_DIR
. "$REPO/setup-node.sh"
SRC=$REPO
load_lib

assert_eq "line value" "gw.example.com" "$(line_value "$(cat "$SANDBOX/lines")" GATEWAY_HOST)"
assert_eq "line value strips quotes and spaces" "abc" "$(line_value 'RELAY_TOKEN= "abc" ' RELAY_TOKEN)"
assert_eq "line value strips carriage returns" "abc" "$(line_value "$(printf 'RELAY_TOKEN=abc\r')" RELAY_TOKEN)"
parse_gateway "$(cat "$SANDBOX/lines")" > /dev/null
assert_eq "parse host" gw.example.com "$G_HOST"
assert_eq "parse token" tok123 "$G_TOKEN"
assert_eq "parse relay id" "$ID2" "$R_ID"

assert_eq "default tz is valid" 0 "$(valid_tz_name "$(default_tz)" && echo 0 || echo 1)"
assert_eq "default name is blank or valid" 0 "$(n=$(default_name); [ -z "$n" ] || valid_name "$n" && echo 0 || echo 1)"

DRY_RUN=false
KEEP_CONFIG=false
NODE_NAME=adrian
OWNER=justin
ROLE=contributor
TZ_NAME=America/Phoenix
SRC=$REPO
install_files
assert_eq "files installed" 1 "$([ -f "$NODE_HOME/docker-compose.yml" ] && echo 1 || echo 0)"
assert_eq "agent installed" 1 "$([ -f "$NODE_HOME/agent/join.sh" ] && echo 1 || echo 0)"
assert_eq "tests not installed" 0 "$([ -e "$NODE_HOME/tests" ] && echo 1 || echo 0)"
assert_eq "library folder made" 1 "$([ -d "$NODE_HOME/data/library" ] && echo 1 || echo 0)"
write_config
conf=$(cat "$NODE_HOME/tinycloud.conf")
assert_contains "conf name" "$conf" "NODE_NAME=adrian"
assert_contains "conf owner" "$conf" "OWNER=justin"
assert_contains "conf role" "$conf" "ROLE=contributor"
assert_contains "conf token" "$conf" "RELAY_TOKEN=tok123"
assert_contains "conf gateway id" "$conf" "GATEWAY_ID=$ID1"
assert_eq "conf private" 600 "$(stat -c %a "$NODE_HOME/tinycloud.conf" 2> /dev/null || stat -f %Lp "$NODE_HOME/tinycloud.conf")"
assert_eq "no temp file left" 0 "$([ -e "$NODE_HOME/tinycloud.conf.tmp" ] && echo 1 || echo 0)"

printf 'keep=me\n' > "$NODE_HOME/data/library/book.epub"
printf 'ROLE=reader\n' >> "$NODE_HOME/tinycloud.conf"
install_files
assert_eq "update keeps files" 1 "$([ -f "$NODE_HOME/data/library/book.epub" ] && echo 1 || echo 0)"
assert_contains "update keeps config" "$(cat "$NODE_HOME/tinycloud.conf")" "RELAY_TOKEN=tok123"

assert_eq "existing value read" adrian "$(existing_value NODE_NAME)"
KEEP_CONFIG=true
before=$(cat "$NODE_HOME/tinycloud.conf")
write_config
assert_eq "keep leaves config alone" "$before" "$(cat "$NODE_HOME/tinycloud.conf")"
KEEP_CONFIG=false

SETUP_BIN_DIR=$SANDBOX/bin
link_command
assert_eq "command linked" "$NODE_HOME/bin/tinycloud" "$(readlink "$SANDBOX/bin/tinycloud")"

usermod() { :; }
getent() { return 0; }
TARGET_USER=tester
SETUP_USER_HOME=$SANDBOX/home
setup_user
assert_eq "shortcut made" "$NODE_HOME/data/library" "$(readlink "$SANDBOX/home/tinycloud")"
setup_user
assert_eq "shortcut kept" "$NODE_HOME/data/library" "$(readlink "$SANDBOX/home/tinycloud")"
rm "$SANDBOX/home/tinycloud"
mkdir "$SANDBOX/home/tinycloud"
setup_user
assert_eq "real folder not replaced" 0 "$([ -L "$SANDBOX/home/tinycloud" ] && echo 1 || echo 0)"

mkdir -p "$NODE_HOME/bin"
printf '#!/bin/sh\necho "tinycloud-gw approve adrian X contributor justin"\n' > "$NODE_HOME/bin/tinycloud"
chmod +x "$NODE_HOME/bin/tinycloud"
assert_contains "wait finds the join line" "$(wait_join)" "tinycloud-gw approve"
printf '#!/bin/sh\nexit 1\n' > "$NODE_HOME/bin/tinycloud"
SETUP_WAIT_TRIES=2
SETUP_WAIT_SECONDS=0
assert_eq "wait gives up" 1 "$(wait_join > /dev/null 2>&1 && echo 0 || echo 1)"

exec 3< /dev/null
ASSUME_YES=false
assert_eq "missing tool declined" 1 "$(ensure_tool definitely-missing-tool > /dev/null 2>&1 && echo 0 || echo 1)"
exec 3<&-

mkdir -p "$SANDBOX/up/tinycloud-main/gateway" "$SANDBOX/up/tinycloud-main/node"
printf 'x' > "$SANDBOX/up/tinycloud-main/gateway/lib.sh"
printf 'x' > "$SANDBOX/up/tinycloud-main/node/docker-compose.yml"
download_tarball() { tar czf - -C "$SANDBOX/up" tinycloud-main; }
SETUP_SRC=$SANDBOX/src
ASSUME_YES=true
fetch_tree > /dev/null 2>&1
assert_eq "tree extracted" 1 "$([ -f "$SETUP_SRC/node/docker-compose.yml" ] && echo 1 || echo 0)"
rm -f "$SANDBOX/up/tinycloud-main/node/docker-compose.yml"
assert_eq "wrong download refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"
SETUP_SRC=/
assert_eq "root source refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"
SETUP_SRC=$SANDBOX/src
TC_REF='main;rm'
assert_eq "bad ref refused" 1 "$(fetch_tree > /dev/null 2>&1 && echo 0 || echo 1)"

finish
