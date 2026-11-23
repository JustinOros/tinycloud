#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

try() {
  if ! "$@" > /dev/null 2>&1; then
    log WARN "step failed: $*"
    leave_rc=1
  fi
}

main() {
  leave_rc=0
  lv_name=$(conf_get NODE_NAME)
  lv_owner=$(conf_get OWNER)
  lv_gateway=$(conf_get GATEWAY_ID)
  valid_name "$lv_name" || { log ERROR "NODE_NAME is invalid"; return 1; }
  valid_name "$lv_owner" || { log ERROR "OWNER is invalid"; return 1; }
  valid_device_id "$lv_gateway" || { log ERROR "GATEWAY_ID is invalid"; return 1; }
  lv_status=$(st_api GET /rest/system/status) || { log ERROR "cannot read syncthing status"; return 1; }
  lv_me=$(printf '%s' "$lv_status" | jq -r '.myID // empty')
  valid_device_id "$lv_me" || { log ERROR "syncthing device id not valid"; return 1; }

  lv_only_me=$(jq -nc --arg me "$lv_me" '{devices: [{deviceID: $me}]}')
  lv_ids=$(lib_folder_ids 2> /dev/null || true)
  [ -n "$lv_ids" ] || lv_ids=tc-lib-$lv_owner
  for lv_f in $lv_ids; do
    try st_api PATCH "/rest/config/folders/$lv_f" "$lv_only_me"
  done
  for lv_id in $(read_state managed.ids); do
    valid_device_id "$lv_id" && try st_api DELETE "/rest/config/devices/$lv_id"
  done
  try st_api DELETE "/rest/config/devices/$lv_gateway"
  try st_api DELETE /rest/config/folders/tinycloud-peers
  try st_api DELETE "/rest/config/folders/tc-status-$lv_name"
  try st_api DELETE "/rest/config/folders/tc-view-$lv_owner"

  rm -f "$(state_file managed.ids)" "$(state_file pending.json)" "$(state_file confirmed.ids)" "$(state_file applied.sha)"
  write_atomic "$(state_file left)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log INFO "node $lv_name left the cloud, files were kept"
  return "$leave_rc"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
