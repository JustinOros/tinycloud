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
export GW_HOME GW_ALLOW_NONROOT GW_NO_MAIN GW_LIB_DIR
. "$GW/bin/tinycloud-gw"

st_api() { return 0; }

OWN_GW=$(mkid A)
OWN_RELAY=$(mkid B)
OWN_DISC=$(mkid C)
N1=$(mkid D)
N2=$(mkid E)
F_GW=$(mkid F)
F_RELAY=$(mkid G)
F_DISC=$(mkid H)
F1=$(mkid I)
F2=$(mkid J)
peers=$FOLDERS_DIR/tinycloud-peers/peers.json

reset() {
  rm -rf "$GW_HOME"
  mkdir -p "$GW_STATE"
  ASSUME_YES=0
  printf 'GATEWAY_HOST=gw.mine.example\nGATEWAY_ID=%s\nRELAY_ID=%s\nDISCOVERY_ID=%s\nRELAY_TOKEN=owntoken\n' "$OWN_GW" "$OWN_RELAY" "$OWN_DISC" > "$GW_HOME/node-lines.txt"
  printf '[{"name":"rocky","id":"%s","role":"anchor","owner":"justin"},{"name":"grace","id":"%s","role":"contributor","owner":"justin"}]' "$N1" "$N2" > "$APPROVED"
}

finn_code() {
  fc_json=$(jq -nc --arg h "${1:-gw.finn.example}" --arg g "$F_GW" --arg r "$F_RELAY" --arg d "$F_DISC" --arg o "${2:-finn}" --arg a "$F1" --arg b "$F2" \
    '{v: 1, host: $h, gateway_id: $g, relay_id: $r, disc_id: $d, token: "fintoken", nodes: [{id: $a, name: "rocky", role: "anchor", owner: $o}, {id: $b, name: "grace", role: "contributor", owner: $o}]}')
  printf '%s%s' "$LINK_PREFIX" "$(link_encode "$fc_json")"
}

reset
code=$(cmd_link_export 2> "$SANDBOX/err")
assert_contains "export warns about the token" "$(cat "$SANDBOX/err")" "relay token"
assert_contains "code has the prefix" "$code" "tcl1."
assert_eq "code is one line" 1 "$(printf '%s\n' "$code" | wc -l | tr -d ' ')"
assert_not_contains "code has no padding or url unsafe characters" "$code" "="
decoded=$(link_decode "${code#"$LINK_PREFIX"}")
assert_jq "code holds the identity" "$decoded" ".v == 1 and .host == \"gw.mine.example\" and .relay_id == \"$OWN_RELAY\" and .disc_id == \"$OWN_DISC\" and .token == \"owntoken\" and (.nodes | length) == 2"
assert_eq "decoded code passes the check" true "$(printf '%s' "$decoded" | jq -r "$LINK_CHECK" | jq -r '.ok')"

reset
: > "$APPROVED"
printf '[]' > "$APPROVED"
assert_contains "export needs a node" "$(cmd_link_export 2>&1 || true)" "approve a node first"
rm -f "$GW_HOME/node-lines.txt"
reset
rm -f "$GW_HOME/node-lines.txt"
assert_contains "export needs saved settings" "$(cmd_link_export 2>&1 || true)" "no saved node settings"

reset
out=$(do_link_add finn "$(finn_code)" --accept finn --offer justin --yes 2>&1)
assert_contains "link is added" "$out" "linked finn"
assert_contains "summary shows what is received" "$out" "You receive: finn"
assert_contains "summary shows what is sent" "$out" "You send: justin"
assert_jq "link record saved" "$(cat "$LINKS")" ".[0].name == \"finn\" and .[0].accept == [\"finn\"] and .[0].offer == [\"justin\"] and (.[0].nodes | length) == 2 and .[0].token == \"fintoken\""
assert_eq "links file is private" 600 "$(stat -c %a "$LINKS" 2> /dev/null || stat -f %Lp "$LINKS")"
assert_jq "peers.json has own and linked nodes" "$(cat "$peers")" '(.peers | map(.name) | sort) == ["finn-grace", "finn-rocky", "grace", "rocky"]'
assert_jq "own nodes carry no folders list" "$(cat "$peers")" '(.peers | map(select(.name == "rocky")) | .[0] | has("folders")) == false'
assert_jq "linked node folders are what was chosen" "$(cat "$peers")" '(.peers | map(select(.name == "finn-rocky")) | .[0].folders | sort) == ["finn", "justin"]'
assert_jq "peers.json lists the linked gateway" "$(cat "$peers")" ".links == [{host: \"gw.finn.example\", relay_id: \"$F_RELAY\", disc_id: \"$F_DISC\", token: \"fintoken\"}]"
assert_contains "audit has the link" "$(cat "$AUDIT")" "link add finn gw.finn.example accept=finn offer=justin"
assert_not_contains "audit has no token" "$(cat "$AUDIT")" "fintoken"

check_with_node() {
  (
    TC_ROOT=$ROOT/node
    TC_SOURCED=1
    export TC_ROOT TC_SOURCED
    . "$ROOT/node/agent/apply-peers.sh"
    check_peers_file "$1"
  )
}
assert_jq "a node accepts the new peers.json" "$(check_with_node "$peers")" '.ok == true and (.peers | length) == 4 and (.links | length) == 1'

list=$(cmd_link_list)
assert_contains "list shows the link" "$list" "finn"
assert_contains "list shows the gateway" "$list" "gw.finn.example"

reset
do_link_add finn "$(finn_code)" --yes > /dev/null 2>&1
assert_jq "default is to share nothing" "$(cat "$LINKS")" '.[0].accept == [] and .[0].offer == []'
assert_jq "linked nodes get no folders by default" "$(cat "$peers")" '(.peers | map(select(.name == "finn-rocky")) | .[0].folders) == []'

reset
out=$(printf 'y\ny\nyes\n' | do_link_add finn "$(finn_code)" 2>&1)
assert_contains "prompts then asks to confirm" "$out" "linked finn"
assert_jq "prompted choices are saved" "$(cat "$LINKS")" '.[0].accept == ["finn"] and .[0].offer == ["justin"]'

reset
printf '[{"name":"rocky","id":"%s","role":"anchor","owner":"justin"}]' "$N1" > "$APPROVED"
do_link_add finn "$(finn_code)" --accept finn --yes > /dev/null 2>&1
before=$(cat "$LINKS")
out=$(do_link_add finn "$(finn_code)" --yes 2>&1)
assert_eq "updating with --yes keeps the earlier choices" "$before" "$(cat "$LINKS")"

reset
assert_contains "own code is refused" "$(do_link_add me "$(printf '%s' "$(cmd_link_export 2> /dev/null)")" --yes 2>&1 || true)" "your own gateway code"
assert_contains "owner clash is refused" "$(do_link_add finn "$(finn_code gw.finn.example justin)" --yes 2>&1 || true)" "already used here: justin"
assert_contains "not a code is refused" "$(do_link_add finn "hello" --yes 2>&1 || true)" "not a link code"
assert_contains "garbage is refused" "$(do_link_add finn "tcl1.@@@@" --yes 2>&1 || true)" "bad link code"
assert_contains "bad name is refused" "$(do_link_add Finn "$(finn_code)" --yes 2>&1 || true)" "bad link name"
assert_contains "long name is refused" "$(do_link_add abcdefghijklmn "$(finn_code)" --yes 2>&1 || true)" "bad link name"
assert_contains "accept must be offered" "$(do_link_add finn "$(finn_code)" --accept rachel --yes 2>&1 || true)" "--accept must be owners offered"
assert_contains "offer must be own" "$(do_link_add finn "$(finn_code)" --offer rachel --yes 2>&1 || true)" "--offer must be your own owners"
assert_eq "nothing saved after refusals" 0 "$([ -s "$LINKS" ] && echo 1 || echo 0)"
bad=$(jq -nc '{v: 1, host: "bad host", gateway_id: "x", relay_id: "x", disc_id: "x", token: "t", nodes: []}')
assert_contains "bad fields are refused" "$(do_link_add finn "tcl1.$(link_encode "$bad")" --yes 2>&1 || true)" "bad link code"

reset
do_link_add finn "$(finn_code)" --yes > /dev/null 2>&1
assert_contains "second link may not reuse an owner" "$(do_link_add other "$(finn_code gw.other.example)" --yes 2>&1 || true)" "already used here: finn"
printf '[{"name":"rocky","id":"%s","role":"anchor","owner":"justin"}]' "$N1" > "$APPROVED"
assert_contains "repeated node names are refused" "$(do_link_add justin-x "$(finn_code gw.other.example other)" --yes 2>&1 || true)" "linked justin-x"

reset
do_link_add finn "$(finn_code)" --accept finn --yes > /dev/null 2>&1
out=$(printf 'yes\n' | do_link_remove finn 2>&1)
assert_contains "remove says so" "$out" "removed link finn"
assert_jq "link is gone" "$(cat "$LINKS")" 'length == 0'
assert_jq "peers.json is back to own nodes" "$(cat "$peers")" '(.peers | map(.name) | sort) == ["grace", "rocky"] and .links == []'
assert_contains "remove of a missing link fails" "$(do_link_remove finn --yes 2>&1 || true)" "no link named finn"
assert_contains "list when empty" "$(cmd_link_list)" "no links yet"
assert_contains "audit has the removal" "$(cat "$AUDIT")" "link remove finn"

reset
out=$(printf 'n\nno\n' | do_link_add finn "$(finn_code)" --accept finn 2>&1 || true)
assert_contains "can be cancelled" "$out" "cancelled"
assert_eq "cancel saves nothing" 0 "$([ -s "$LINKS" ] && echo 1 || echo 0)"

cmd_link bogus > /dev/null 2>&1
assert_eq "unknown link subcommand fails" 1 "$?"

finish
