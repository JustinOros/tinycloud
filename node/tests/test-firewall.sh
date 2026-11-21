#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
TC_NODE_ENV=$SANDBOX/node.env
TC_FW_DIR=$SANDBOX/out
export TC_NODE_ENV TC_FW_DIR
. "$TC_ROOT/firewall/firewall-apply.sh"
resolve_gateway() { echo 203.0.113.10; }
find_router() { echo 192.168.1.1; }

printf 'GATEWAY_HOST=gw.example.com\nSSH_ENABLED=false\nSMB_ENABLED=false\n' > "$TC_NODE_ENV"
write_vars
vars=$(cat "$FW_DIR/firewall.vars.nft")
assert_contains "gateway ip" "$vars" "define GATEWAY = 203.0.113.10"
assert_contains "router ip" "$vars" "define ROUTER = 192.168.1.1"
assert_contains "only status page by default" "$vars" "define LAN_TCP = { 80 }"

printf 'GATEWAY_HOST=gw.example.com\nSSH_ENABLED=true\nSMB_ENABLED=true\n' > "$TC_NODE_ENV"
write_vars
assert_contains "ssh and smb added" "$(cat "$FW_DIR/firewall.vars.nft")" "define LAN_TCP = { 80, 22, 445 }"

printf 'GATEWAY_HOST=bad/host\n' > "$TC_NODE_ENV"
assert_eq "bad host rejected" 1 "$(write_vars 2> /dev/null && echo 0 || echo 1)"

printf 'GATEWAY_HOST=gw.example.com\n' > "$TC_NODE_ENV"
resolve_gateway() { echo "not-an-ip"; }
assert_eq "bad gateway ip rejected" 1 "$(write_vars 2> /dev/null && echo 0 || echo 1)"

resolve_gateway() { echo 203.0.113.10; }
find_router() { echo ""; }
assert_eq "missing router rejected" 1 "$(write_vars 2> /dev/null && echo 0 || echo 1)"

finish
