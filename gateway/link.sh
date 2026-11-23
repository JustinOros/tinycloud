LINK_PREFIX=tcl1.
LINK_MAX_NAME=12

LINK_CHECK='
def txt: type == "string";
def fail($r): {ok: false, reason: $r};
def devid: test("\\A[A-Z2-7]{7}(-[A-Z2-7]{7}){7}\\z");
if type != "object" then fail("not an object")
elif .v != 1 then fail("unknown version")
elif ([.host, .gateway_id, .relay_id, .disc_id, .token] | all(txt) | not) then fail("field missing or not text")
elif (.host | test("\\A[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\\z") | not) then fail("bad host")
elif ([.gateway_id, .relay_id, .disc_id] | all(devid) | not) then fail("bad id")
elif (.token | test("\\A[A-Za-z0-9_-]{1,128}\\z") | not) then fail("bad token")
elif (.nodes | type) != "array" then fail("nodes is not a list")
elif (.nodes | length) < 1 then fail("no nodes")
elif (.nodes | length) > 64 then fail("too many nodes")
elif (.nodes | all(type == "object") | not) then fail("node is not an object")
elif (.nodes | all((.id | txt) and (.name | txt) and (.role | txt) and (.owner | txt)) | not) then fail("node field missing or not text")
elif (.nodes | all(.id | devid) | not) then fail("bad node id")
elif (.nodes | all(.name | test("\\A[a-z0-9-]{1,32}\\z")) | not) then fail("bad node name")
elif (.nodes | all(.owner | test("\\A[a-z0-9-]{1,32}\\z")) | not) then fail("bad owner")
elif (.nodes | all(.role | IN("anchor", "contributor", "partial", "reader")) | not) then fail("bad role")
elif (.nodes | map(.id) | unique | length) != (.nodes | length) then fail("duplicate node id")
elif (.nodes | map(.name) | unique | length) != (.nodes | length) then fail("duplicate node name")
else {ok: true, link: {host, gateway_id, relay_id, disc_id, token, nodes: (.nodes | map({id, name, role, owner}))}}
end
'

LINK_PEERS='
[.[] as $l | $l.nodes[] as $n | {
  id: $n.id,
  name: ($l.name + "-" + $n.name),
  role: $n.role,
  owner: $n.owner,
  folders: ((if ($l.accept | index($n.owner)) != null then [$n.owner] else [] end) + $l.offer | unique)
}]
'

load_links() {
  if [ -s "$LINKS" ]; then
    cat "$LINKS"
  else
    printf '[]'
  fi
}

own_setting() {
  sed -n "s/^$1=//p" "$GW_HOME/node-lines.txt" 2> /dev/null | tail -n 1
}

link_encode() {
  printf '%s' "$1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

link_decode() {
  ld_b=$(printf '%s' "$1" | tr '_-' '/+')
  case $((${#ld_b} % 4)) in
    2) ld_b=$ld_b== ;;
    3) ld_b=$ld_b= ;;
  esac
  printf '%s' "$ld_b" | base64 -d 2> /dev/null
}

link_owners() {
  printf '%s' "$1" | jq -c '[.[].owner] | unique'
}

csv_json() {
  if [ -z "$1" ]; then
    printf '[]'
  else
    printf '%s' "$1" | tr ',' '\n' | jq -R . | jq -sc 'unique'
  fi
}

ask_yes() {
  printf '%s (y/N) ' "$1" >&2
  read -r ay_answer || return 1
  case $ay_answer in
    y | Y | yes | YES) return 0 ;;
  esac
  return 1
}

pick_owners() {
  po_out='[]'
  for po_o in $(printf '%s' "$2" | jq -r '.[]'); do
    if ask_yes "$1 $po_o?"; then
      po_out=$(printf '%s' "$po_out" | jq -c --arg o "$po_o" '. + [$o]')
    fi
  done
  printf '%s' "$po_out"
}

subset_of() {
  [ "$(jq -nc --argjson a "$1" --argjson b "$2" '($a - $b) | length')" -eq 0 ]
}

cmd_link_export() {
  le_host=$(own_setting GATEWAY_HOST)
  le_gw=$(own_setting GATEWAY_ID)
  le_relay=$(own_setting RELAY_ID)
  le_disc=$(own_setting DISCOVERY_ID)
  le_token=$(own_setting RELAY_TOKEN)
  if [ -z "$le_host" ] || [ -z "$le_gw" ] || [ -z "$le_relay" ] || [ -z "$le_disc" ] || [ -z "$le_token" ]; then
    log ERROR "no saved node settings found, run gateway.sh first"
    return 1
  fi
  le_nodes=$(load_approved)
  if [ "$(printf '%s' "$le_nodes" | jq 'length')" -eq 0 ]; then
    log ERROR "approve a node first, a code with no nodes is no use"
    return 1
  fi
  le_json=$(jq -nc --arg h "$le_host" --arg g "$le_gw" --arg r "$le_relay" --arg d "$le_disc" --arg t "$le_token" --argjson n "$le_nodes" \
    '{v: 1, host: $h, gateway_id: $g, relay_id: $r, disc_id: $d, token: $t, nodes: ($n | map({id, name, role, owner}))}')
  printf 'This code holds your relay token. Send it privately.\n' >&2
  printf '%s%s\n' "$LINK_PREFIX" "$(link_encode "$le_json")"
}

do_link_add() {
  la_n=0
  la_name=
  la_code=
  la_accept=
  la_offer=
  la_have_accept=0
  la_have_offer=0
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) ASSUME_YES=1 ;;
      --accept)
        la_accept=${2:-}
        la_have_accept=1
        [ $# -gt 1 ] && shift
        ;;
      --offer)
        la_offer=${2:-}
        la_have_offer=1
        [ $# -gt 1 ] && shift
        ;;
      *)
        la_n=$((la_n + 1))
        case $la_n in
          1) la_name=$1 ;;
          2) la_code=$1 ;;
        esac
        ;;
    esac
    shift
  done
  if [ "$la_n" -ne 2 ]; then
    usage
    return 1
  fi
  valid_name "$la_name" && [ "${#la_name}" -le "$LINK_MAX_NAME" ] || { log ERROR "bad link name, use up to $LINK_MAX_NAME lowercase letters, digits, or dashes"; return 1; }
  case $la_code in
    "$LINK_PREFIX"*) ;;
    *) log ERROR "that is not a link code"; return 1 ;;
  esac
  if [ "${#la_code}" -gt 32768 ]; then
    log ERROR "that link code is too long"
    return 1
  fi
  la_json=$(link_decode "${la_code#"$LINK_PREFIX"}")
  la_res=$(printf '%s' "$la_json" | jq -c "$LINK_CHECK" 2> /dev/null || printf '%s' '{"ok":false,"reason":"not valid JSON"}')
  if [ "$(printf '%s' "$la_res" | jq -r '.ok')" != true ]; then
    log ERROR "bad link code: $(printf '%s' "$la_res" | jq -r '.reason')"
    return 1
  fi
  la_link=$(printf '%s' "$la_res" | jq -c '.link')
  la_host=$(printf '%s' "$la_link" | jq -r '.host')
  la_relay=$(printf '%s' "$la_link" | jq -r '.relay_id')
  if [ "$la_host" = "$(own_setting GATEWAY_HOST)" ] || [ "$la_relay" = "$(own_setting RELAY_ID)" ]; then
    log ERROR "that is your own gateway code"
    return 1
  fi
  la_mine=$(load_approved)
  la_links=$(load_links)
  la_others=$(printf '%s' "$la_links" | jq -c --arg n "$la_name" 'map(select(.name != $n))')
  la_old=$(printf '%s' "$la_links" | jq -c --arg n "$la_name" '.[] | select(.name == $n)')
  la_theirs=$(printf '%s' "$la_link" | jq -c '[.nodes[].owner] | unique')
  la_taken=$(jq -nc --argjson m "$(link_owners "$la_mine")" --argjson o "$(printf '%s' "$la_others" | jq -c '[.[].nodes[].owner] | unique')" '$m + $o | unique')
  la_clash=$(jq -nr --argjson a "$la_theirs" --argjson b "$la_taken" '$a - ($a - $b) | join(", ")')
  if [ -n "$la_clash" ]; then
    log ERROR "owner names must be unique across linked clouds, already used here: $la_clash"
    return 1
  fi
  la_bad=$(printf '%s' "$la_link" | jq -r --arg p "$la_name" '[.nodes[] | ($p + "-" + .name) | select(length > 32)] | .[0] // empty')
  if [ -n "$la_bad" ]; then
    log ERROR "the node name $la_bad is too long once the link name is added"
    return 1
  fi
  la_total=$(jq -nc --argjson m "$la_mine" --argjson o "$la_others" --argjson n "$la_link" '($m | length) + ($o | map(.nodes | length) | add // 0) + ($n.nodes | length)')
  if [ "$la_total" -gt 64 ]; then
    log ERROR "that would be more than 64 nodes in all"
    return 1
  fi
  la_names=$(jq -nc --argjson m "$la_mine" --argjson o "$la_others" --argjson n "$la_link" --arg p "$la_name" \
    '($m | map(.name)) + ($o | map(.name as $q | .nodes | map($q + "-" + .name)) | add // []) + ($n.nodes | map($p + "-" + .name)) | (length) - (unique | length)')
  if [ "$la_names" -ne 0 ]; then
    log ERROR "a node name would repeat, rename a node or pick another link name"
    return 1
  fi
  la_mine_owners=$(link_owners "$la_mine")

  if [ "$la_have_accept" = 1 ]; then
    la_acc=$(csv_json "$la_accept")
  elif [ "$ASSUME_YES" = 1 ] && [ -n "$la_old" ]; then
    la_acc=$(printf '%s' "$la_old" | jq -c '.accept // []')
  elif [ "$ASSUME_YES" = 1 ]; then
    la_acc='[]'
  else
    la_acc=$(pick_owners "Receive the files of" "$la_theirs")
  fi
  if [ "$la_have_offer" = 1 ]; then
    la_off=$(csv_json "$la_offer")
  elif [ "$ASSUME_YES" = 1 ] && [ -n "$la_old" ]; then
    la_off=$(printf '%s' "$la_old" | jq -c '.offer // []')
  elif [ "$ASSUME_YES" = 1 ]; then
    la_off='[]'
  else
    la_off=$(pick_owners "Send your files of" "$la_mine_owners")
  fi
  subset_of "$la_acc" "$la_theirs" || { log ERROR "--accept must be owners offered by that cloud: $(printf '%s' "$la_theirs" | jq -r 'join(", ")')"; return 1; }
  subset_of "$la_off" "$la_mine_owners" || { log ERROR "--offer must be your own owners: $(printf '%s' "$la_mine_owners" | jq -r 'join(", ")')"; return 1; }

  printf 'Link: %s\nGateway: %s\nNodes: %s\nTheir owners: %s\nYou receive: %s\nYou send: %s\n' \
    "$la_name" "$la_host" "$(printf '%s' "$la_link" | jq '.nodes | length')" \
    "$(printf '%s' "$la_theirs" | jq -r 'join(", ")')" \
    "$(printf '%s' "$la_acc" | jq -r 'if length == 0 then "nothing" else join(", ") end')" \
    "$(printf '%s' "$la_off" | jq -r 'if length == 0 then "nothing" else join(", ") end')"
  confirm || { echo "cancelled"; return 1; }
  la_new=$(printf '%s' "$la_others" | jq -c --arg n "$la_name" --argjson l "$la_link" --argjson a "$la_acc" --argjson o "$la_off" '. + [($l + {name: $n, accept: $a, offer: $o})]')
  write_atomic "$LINKS" "$la_new"
  chmod 600 "$LINKS"
  publish_peers
  audit "link add $la_name $la_host accept=$(printf '%s' "$la_acc" | jq -r 'join(",")') offer=$(printf '%s' "$la_off" | jq -r 'join(",")')"
  log INFO "linked $la_name"
}

do_link_remove() {
  lr_name=
  for lr_arg in "$@"; do
    case $lr_arg in
      --yes) ASSUME_YES=1 ;;
      *) lr_name=$lr_arg ;;
    esac
  done
  valid_name "$lr_name" || { usage; return 1; }
  lr_links=$(load_links)
  if [ "$(printf '%s' "$lr_links" | jq --arg n "$lr_name" 'any(.[]; .name == $n)')" != true ]; then
    log ERROR "no link named $lr_name"
    return 1
  fi
  printf 'Remove link %s. Your nodes stop syncing with its nodes. Files already copied stay where they are.\n' "$lr_name"
  confirm || { echo "cancelled"; return 1; }
  write_atomic "$LINKS" "$(printf '%s' "$lr_links" | jq -c --arg n "$lr_name" 'map(select(.name != $n))')"
  chmod 600 "$LINKS"
  publish_peers
  audit "link remove $lr_name"
  log INFO "removed link $lr_name"
}

cmd_link_list() {
  ll_links=$(load_links)
  if [ "$(printf '%s' "$ll_links" | jq 'length')" -eq 0 ]; then
    echo "no links yet"
    return 0
  fi
  printf '%s' "$ll_links" | jq -r '.[] | [.name, .host, (.nodes | length | tostring), (if (.accept | length) == 0 then "-" else (.accept | join(",")) end), (if (.offer | length) == 0 then "-" else (.offer | join(",")) end)] | @tsv' |
    awk -F '\t' 'BEGIN {printf "%-12s %-32s %-6s %-20s %s\n", "NAME", "GATEWAY", "NODES", "RECEIVE", "SEND"} {printf "%-12s %-32s %-6s %-20s %s\n", $1, $2, $3, $4, $5}'
}

cmd_link() {
  lk_sub=${1:-}
  [ $# -gt 0 ] && shift
  case $lk_sub in
    export) cmd_link_export ;;
    add) locked do_link_add "$@" ;;
    list) cmd_link_list ;;
    remove) locked do_link_remove "$@" ;;
    *)
      usage
      return 1
      ;;
  esac
}
