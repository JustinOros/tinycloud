#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

LIB_FOLDER=tinycloud-library
PEERS_FILE=${TC_PEERS_FILE:-$TC_SYSTEM_DIR/peers/peers.json}

PEERS_CHECK='
def txt: type == "string";
def fail($r): {ok: false, reason: $r};
if type != "object" then fail("not an object")
elif .version != 1 then fail("unknown version")
elif (.peers | type) != "array" then fail("peers is not a list")
elif (.peers | length) < 1 then fail("empty peer list")
elif (.peers | length) > 64 then fail("too many peers")
elif (.peers | all(type == "object") | not) then fail("peer is not an object")
elif (.peers | all((.id | txt) and (.name | txt) and (.role | txt) and (.owner | txt)) | not) then fail("peer field missing or not text")
elif (.peers | all(.id | test("\\A[A-Z2-7]{7}(-[A-Z2-7]{7}){7}\\z")) | not) then fail("bad device id")
elif (.peers | all(.name | test("\\A[a-z0-9-]{1,32}\\z")) | not) then fail("bad node name")
elif (.peers | all(.owner | test("\\A[a-z0-9-]{1,32}\\z")) | not) then fail("bad owner")
elif (.peers | all(.role | IN("anchor", "contributor", "partial", "reader")) | not) then fail("bad role")
elif (.peers | map(.id) | unique | length) != (.peers | length) then fail("duplicate device id")
elif (.peers | map(.name) | unique | length) != (.peers | length) then fail("duplicate node name")
else {ok: true, peers: (.peers | map({id, name, role, owner}))}
end
'

check_peers_file() {
  if [ "$(wc -c < "$1")" -gt 65536 ]; then
    printf '%s' '{"ok":false,"reason":"file too large"}'
    return 0
  fi
  jq -c "$PEERS_CHECK" "$1" 2> /dev/null || printf '%s' '{"ok":false,"reason":"not valid JSON"}'
}

ids_json() {
  if [ -s "$1" ]; then
    jq -R . "$1" | jq -sc .
  else
    printf '[]'
  fi
}

apply_peers() {
  ap_status=$(st_api GET /rest/system/status) || return 1
  ap_me=$(printf '%s' "$ap_status" | jq -r '.myID // empty')
  ap_gw=$(conf_get GATEWAY_ID)
  ap_role=$(conf_get ROLE reader)
  ap_confirm=$(conf_get PEERS_CONFIRM auto)
  ap_folder=$(st_api GET "/rest/config/folders/$LIB_FOLDER") || {
    log ERROR "library folder not found, first boot not done"
    return 1
  }
  ap_desired=$(printf '%s' "$1" | jq -c --arg me "$ap_me" --arg gw "$ap_gw" --arg role "$ap_role" \
    'map(select(.id != $me and .id != $gw and ($role != "reader" or .role != "reader")))')
  ap_managed=$(ids_json "$(state_file managed.ids)")
  ap_pending='[]'
  if [ "$ap_confirm" = manual ]; then
    ap_confirmed=$(ids_json "$(state_file confirmed.ids)")
    ap_allowed=$(jq -nc --argjson m "$ap_managed" --argjson c "$ap_confirmed" '$m + $c | unique')
    ap_pending=$(printf '%s' "$ap_desired" | jq -c --argjson a "$ap_allowed" 'map(select(.id as $i | ($a | index($i)) == null))')
    ap_desired=$(printf '%s' "$ap_desired" | jq -c --argjson a "$ap_allowed" 'map(select(.id as $i | ($a | index($i)) != null))')
  fi
  write_atomic "$(state_file pending.json)" "$ap_pending"
  ap_want=$(printf '%s' "$ap_desired" | jq -c 'map(.id)')
  ap_remove=$(jq -nc --argjson m "$ap_managed" --argjson w "$ap_want" '$m - $w')
  ap_added=$(printf '%s' "$ap_desired" | jq -r --argjson m "$ap_managed" 'map(select(.id as $i | ($m | index($i)) == null) | .name) | join(",")')

  ap_list=$(mktemp)
  printf '%s' "$ap_desired" | jq -r '.[] | "\(.id) \(.name)"' > "$ap_list"
  ap_failed=
  while read -r ap_id ap_name; do
    if ! put_device "$ap_id" "$ap_name" '["dynamic"]'; then
      ap_failed=$ap_name
      break
    fi
  done < "$ap_list"
  rm -f "$ap_list"
  if [ -n "$ap_failed" ]; then
    log ERROR "could not add device $ap_failed"
    return 1
  fi

  ap_devices=$(printf '%s' "$ap_folder" | jq -c --argjson rm "$ap_remove" --argjson want "$ap_want" '
    .devices as $cur
    | ($cur | map(select(.deviceID as $d | ($rm | index($d)) == null))) as $kept
    | ($kept | map(.deviceID)) as $have
    | {devices: ($kept + ($want | map(select(. as $d | ($have | index($d)) == null) | {deviceID: .})))}')
  st_api PATCH "/rest/config/folders/$LIB_FOLDER" "$ap_devices" > /dev/null || {
    log ERROR "could not update library devices"
    return 1
  }

  for ap_old in $(printf '%s' "$ap_remove" | jq -r '.[]'); do
    st_api DELETE "/rest/config/devices/$ap_old" > /dev/null || log WARN "could not remove device $ap_old"
  done

  ap_tmp=$(mktemp)
  printf '%s' "$ap_want" | jq -r '.[]' > "$ap_tmp"
  mv "$ap_tmp" "$(state_file managed.ids)"
  log INFO "peers applied: added=[$ap_added] removed=$(printf '%s' "$ap_remove" | jq 'length') pending=$(printf '%s' "$ap_pending" | jq 'length')"
}

main() {
  if [ ! -f "$PEERS_FILE" ]; then
    log INFO "no peers file yet"
    return 0
  fi
  mkdir -p "$TC_STATE_DIR"
  sha=$(sha256 "$PEERS_FILE")
  if [ "$sha" = "$(read_state applied.sha)" ]; then
    return 0
  fi
  result=$(check_peers_file "$PEERS_FILE")
  if [ "$(printf '%s' "$result" | jq -r '.ok')" != true ]; then
    if [ "$sha" != "$(read_state rejected.sha)" ]; then
      log ERROR "peers.json rejected: $(printf '%s' "$result" | jq -r '.reason')"
      write_atomic "$(state_file rejected.sha)" "$sha"
    fi
    return 0
  fi
  apply_peers "$(printf '%s' "$result" | jq -c '.peers')" || return 1
  write_atomic "$(state_file applied.sha)" "$sha"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
