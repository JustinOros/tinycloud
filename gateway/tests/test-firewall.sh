#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(cd "$HERE/.." && pwd)
. "$HERE/harness.sh"

rules=$(sed 's/SSH_PORT/22/' "$GW/firewall.nft")
assert_contains "default drop" "$rules" "policy drop"
assert_contains "has gateway ports" "$rules" "22000, 22067, 8443"
assert_not_contains "no flush ruleset" "$rules" "flush ruleset"
assert_not_contains "no forward chain" "$rules" "chain forward"
assert_not_contains "no output chain" "$rules" "chain output"

if command -v nft > /dev/null 2>&1; then
  tmp=$(mktemp)
  printf '%s\n' "$rules" > "$tmp"
  if nft -c -f "$tmp" > /dev/null 2>&1; then
    result=ok
  else
    result=$(nft -c -f "$tmp" 2>&1 | head -n 3)
  fi
  rm -f "$tmp"
  assert_eq "nft accepts rules" ok "$result"
fi

compose=$(cat "$GW/docker-compose.yml")
assert_contains "discovery flags use double dashes" "$compose" "--listen=:8443"
assert_contains "discovery cert flag" "$compose" "--cert=/disco/cert.pem"
assert_not_contains "no single dash discovery flags" "$compose" "- -listen=:8443"

finish
