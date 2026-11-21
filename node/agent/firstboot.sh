#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

check() {
  if "$2" "$3"; then
    return 0
  fi
  log ERROR "config value $1 is missing or invalid"
  return 1
}

load_settings() {
  if [ ! -r "$TC_CONF" ]; then
    log ERROR "config file not readable"
    return 1
  fi
  node_name=$(conf_get NODE_NAME)
  owner=$(conf_get OWNER)
  role=$(conf_get ROLE reader)
  host=$(conf_get GATEWAY_HOST)
  gateway_id=$(conf_get GATEWAY_ID)
  relay_id=$(conf_get RELAY_ID)
  disc_id=$(conf_get DISCOVERY_ID)
  token=$(conf_get RELAY_TOKEN)
  pct=$(conf_get FREE_SPACE_PERCENT 10)
  min_gb=$(conf_get FREE_SPACE_MIN_GB 1)
  order=$(conf_get PULL_ORDER smallestFirst)
  check NODE_NAME valid_name "$node_name" || return 1
  check OWNER valid_name "$owner" || return 1
  check ROLE valid_role "$role" || return 1
  check GATEWAY_HOST valid_host "$host" || return 1
  check GATEWAY_ID valid_device_id "$gateway_id" || return 1
  check RELAY_ID valid_device_id "$relay_id" || return 1
  check DISCOVERY_ID valid_device_id "$disc_id" || return 1
  check RELAY_TOKEN valid_token "$token" || return 1
  check FREE_SPACE_PERCENT valid_int "$pct" || return 1
  check FREE_SPACE_MIN_GB valid_int "$min_gb" || return 1
  check PULL_ORDER valid_order "$order" || return 1
  if [ "$pct" -lt 1 ] || [ "$pct" -gt 50 ]; then
    log ERROR "config value FREE_SPACE_PERCENT must be 1 to 50"
    return 1
  fi
}

apply_options() {
  options=$(jq -nc --arg disc "https://$host:8443/?id=$disc_id" --arg relay "relay://$host:22067/?id=$relay_id&token=$token" \
    '{globalAnnounceEnabled: true, globalAnnounceServers: [$disc], localAnnounceEnabled: false, natEnabled: false,
      relaysEnabled: true, listenAddresses: [$relay], stunServers: [], urAccepted: -1,
      crashReportingEnabled: false, startBrowser: false, autoUpgradeIntervalH: 0}')
  if ! st_api PATCH /rest/config/options "$options" > /dev/null; then
    log ERROR "could not set syncthing options"
    return 1
  fi
  log INFO "syncthing options set"
}

restart_if_needed() {
  rr=$(st_api GET /rest/config/restart-required) || return 1
  if printf '%s' "$rr" | jq -e '.requiresRestart == true' > /dev/null; then
    st_api POST /rest/system/restart > /dev/null || return 1
    sleep "${TC_RESTART_WAIT:-5}"
    st_wait 60 || return 1
  fi
}

set_ignores() {
  si_n=0
  while [ "$si_n" -lt 10 ]; do
    if st_api POST "/rest/db/ignores?folder=$1" '{"ignore":[".DS_Store","Thumbs.db","._*"]}' > /dev/null 2>&1; then
      return 0
    fi
    si_n=$((si_n + 1))
    sleep 1
  done
  return 1
}

create_folders() {
  self_only=$(jq -nc --arg a "$my_id" '[{deviceID: $a}]')
  with_gateway=$(jq -nc --arg a "$my_id" --arg b "$gateway_id" '[{deviceID: $a}, {deviceID: $b}]')
  st_api DELETE /rest/config/folders/default > /dev/null 2>&1 || true
  gateway_addr=$(jq -nc --arg h "tcp://$host:22000" '[$h]')
  put_device "$gateway_id" gateway "$gateway_addr" || return 1
  total_kb=$(df -Pk "$TC_LIBRARY_DIR" | awk 'NR==2 {print $2}')
  if ! valid_int "$total_kb"; then
    log ERROR "could not read disk size"
    return 1
  fi
  min_mb=$(calc_min_free_mb "$total_kb" "$pct" "$min_gb")
  folder_type=sendreceive
  if [ "$role" = reader ]; then
    folder_type=receiveonly
  fi
  extra=$(jq -nc --arg order "$order" --argjson mb "$min_mb" --arg role "$role" \
    '{order: $order, minDiskFree: {value: $mb, unit: "MB"}}
     + (if $role == "anchor" then {versioning: {type: "trashcan", params: {cleanoutDays: "30"}}} else {} end)')
  put_folder tinycloud-library "TinyCloud Library" "$TC_LIBRARY_DIR" "$folder_type" "$self_only" "$extra" || return 1
  put_folder tinycloud-peers "TinyCloud Peers" "$TC_SYSTEM_DIR/peers" receiveonly "$with_gateway" || return 1
  put_folder "tc-status-$node_name" "TinyCloud Status" "$TC_SYSTEM_DIR/status-out" sendonly "$with_gateway" || return 1
  put_folder "tc-view-$owner" "TinyCloud View" "$TC_SYSTEM_DIR/view" receiveonly "$with_gateway" || return 1
  if ! set_ignores tinycloud-library; then
    log WARN "could not set the ignore list"
  fi
}

main() {
  if [ -f "$(state_file firstboot.done)" ] && [ "${TC_FORCE:-0}" != 1 ]; then
    log INFO "first boot already done"
    return 0
  fi
  load_settings || return 1
  st_wait 60 || return 1
  status=$(st_api GET /rest/system/status) || { log ERROR "cannot read syncthing status"; return 1; }
  my_id=$(printf '%s' "$status" | jq -r '.myID // empty')
  if ! valid_device_id "$my_id"; then
    log ERROR "syncthing device id not valid"
    return 1
  fi
  if [ "$gateway_id" = "$my_id" ]; then
    log ERROR "GATEWAY_ID is this node"
    return 1
  fi
  apply_options || return 1
  restart_if_needed || return 1
  create_folders || return 1
  mkdir -p "$TC_STATE_DIR"
  write_atomic "$(state_file device-id)" "$my_id"
  write_atomic "$(state_file firstboot.done)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log INFO "first boot done for node $node_name role $role"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
