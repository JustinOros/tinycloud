#!/bin/sh
AP_OUTER_SOURCED=${TC_SOURCED:-0}
TC_SOURCED=1
. "${TC_ROOT:-/app}/agent/firstboot.sh"
TC_SOURCED=$AP_OUTER_SOURCED

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
elif (.peers | all((.folders // []) | type == "array") | not) then fail("folders is not a list")
elif (.peers | all((.folders // []) | length <= 64) | not) then fail("too many folders")
elif (.peers | all((.folders // []) | all(type == "string" and test("\\A[a-z0-9-]{1,32}\\z"))) | not) then fail("bad folder name")
elif ((.links // []) | type) != "array" then fail("links is not a list")
elif ((.links // []) | length) > 16 then fail("too many links")
elif ((.links // []) | all(type == "object") | not) then fail("link is not an object")
elif ((.links // []) | all((.host | txt) and (.relay_id | txt) and (.disc_id | txt) and (.token | txt)) | not) then fail("link field missing or not text")
elif ((.links // []) | all(.host | test("\\A[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\\z")) | not) then fail("bad link host")
elif ((.links // []) | all((.relay_id | test("\\A[A-Z2-7]{7}(-[A-Z2-7]{7}){7}\\z")) and (.disc_id | test("\\A[A-Z2-7]{7}(-[A-Z2-7]{7}){7}\\z"))) | not) then fail("bad link id")
elif ((.links // []) | all(.token | test("\\A[A-Za-z0-9_-]{1,128}\\z")) | not) then fail("bad link token")
elif ((.links // []) | map(.host) | unique | length) != ((.links // []) | length) then fail("duplicate link host")
else {ok: true, peers: (.peers | map({id, name, role, owner, folders: (.folders // null)})), links: ((.links // []) | map({host, relay_id, disc_id, token}))}
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

sync_owner_folder() {
  sof_id=tc-lib-$1
  if sof_cur=$(st_api GET "/rest/config/folders/$sof_id" 2> /dev/null); then
    sof_extra=$(owner_folder_extra) || return 1
    sof_body=$(printf '%s' "$sof_cur" | jq -c --argjson rm "$3" --argjson want "$4" --argjson extra "$sof_extra" '
      .devices as $cur
      | ($cur | map(select(.deviceID as $d | ($rm | index($d)) == null))) as $kept
      | ($kept | map(.deviceID)) as $have
      | {devices: ($kept + ($want | map(select(. as $d | ($have | index($d)) == null) | {deviceID: .})))} + $extra')
    st_api PATCH "/rest/config/folders/$sof_id" "$sof_body" > /dev/null || {
      log ERROR "could not update folder $1"
      return 1
    }
  else
    sof_devices=$(jq -nc --arg me "$2" --argjson want "$4" '[{deviceID: $me}] + ($want | map({deviceID: .}))')
    put_owner_folder "$1" "$sof_devices" || {
      log ERROR "could not create folder $1"
      return 1
    }
    log INFO "folder $1 created"
  fi
}

drop_old_folders() {
  dof_have=$(lib_folder_ids) || dof_have=
  for dof_id in $dof_have; do
    if [ "$(printf '%s' "$1" | jq --arg o "${dof_id#tc-lib-}" 'index($o) == null')" = true ]; then
      if st_api DELETE "/rest/config/folders/$dof_id" > /dev/null; then
        log INFO "folder ${dof_id#tc-lib-} removed, files kept"
      else
        log WARN "could not remove folder ${dof_id#tc-lib-}"
      fi
    fi
  done
  if st_api GET /rest/config/folders/tinycloud-library > /dev/null 2>&1; then
    if st_api DELETE /rest/config/folders/tinycloud-library > /dev/null; then
      log INFO "old tinycloud-library folder removed, files kept"
    else
      log WARN "could not remove the old tinycloud-library folder"
    fi
  fi
}

apply_peers() {
  ap_status=$(st_api GET /rest/system/status) || return 1
  ap_me=$(printf '%s' "$ap_status" | jq -r '.myID // empty')
  ap_gw=$(conf_get GATEWAY_ID)
  ap_role=$(conf_get ROLE reader)
  ap_confirm=$(conf_get PEERS_CONFIRM auto)
  ap_owner=$(conf_get OWNER)
  valid_name "$ap_owner" || { log ERROR "OWNER is invalid"; return 1; }
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

  ap_owners=$(printf '%s' "$ap_desired" | jq -c --arg o "$ap_owner" '[(.[] | select(.folders == null) | .owner), $o, (.[] | .folders // [] | .[])] | unique')
  ap_known=$(jq -nc --argjson m "$ap_managed" --argjson w "$ap_want" '$m + $w | unique')
  for ap_o in $(printf '%s' "$ap_owners" | jq -r '.[]'); do
    ap_want_o=$(printf '%s' "$ap_desired" | jq -c --arg x "$ap_o" 'map(select(.folders == null or (.folders | index($x)) != null) | .id)')
    ap_remove_o=$(jq -nc --argjson k "$ap_known" --argjson w "$ap_want_o" '$k - $w')
    sync_owner_folder "$ap_o" "$ap_me" "$ap_remove_o" "$ap_want_o" || return 1
  done
  drop_old_folders "$ap_owners"

  for ap_old in $(printf '%s' "$ap_remove" | jq -r '.[]'); do
    st_api DELETE "/rest/config/devices/$ap_old" > /dev/null || log WARN "could not remove device $ap_old"
  done

  ap_tmp=$(mktemp)
  printf '%s' "$ap_want" | jq -r '.[]' > "$ap_tmp"
  mv "$ap_tmp" "$(state_file managed.ids)"
  log INFO "peers applied: added=[$ap_added] removed=$(printf '%s' "$ap_remove" | jq 'length') pending=$(printf '%s' "$ap_pending" | jq 'length')"
}

apply_links() {
  al_old=$(linked_gateways)
  if [ "$al_old" = "$1" ]; then
    return 0
  fi
  load_settings || return 1
  write_atomic "$(state_file links.json)" "$1"
  apply_options || return 1
  restart_if_needed || return 1
  log INFO "linked gateways applied: $(printf '%s' "$1" | jq 'length')"
}

main() {
  if [ ! -f "$PEERS_FILE" ]; then
    log INFO "no peers file yet"
    return 0
  fi
  mkdir -p "$TC_STATE_DIR"
  sha=$(sha256 "$PEERS_FILE")
  if [ "$sha" = "$(read_state applied.sha)" ] && [ "$(read_state layout)" = 2 ]; then
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
  apply_links "$(printf '%s' "$result" | jq -c '.links')" || return 1
  write_atomic "$(state_file applied.sha)" "$sha"
  write_atomic "$(state_file layout)" 2
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
