#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

own_id() {
  oi_id=$(read_state device-id)
  if ! valid_device_id "$oi_id"; then
    oi_id=$(st_api GET /rest/system/status 2> /dev/null | jq -r '.myID // empty')
  fi
  printf '%s' "$oi_id"
}

main() {
  jn_name=$(conf_get NODE_NAME)
  jn_owner=$(conf_get OWNER)
  jn_role=$(conf_get ROLE reader)
  valid_name "$jn_name" || { echo "NODE_NAME in tinycloud.conf is not valid." >&2; return 1; }
  valid_name "$jn_owner" || { echo "OWNER in tinycloud.conf is not valid." >&2; return 1; }
  valid_role "$jn_role" || { echo "ROLE in tinycloud.conf is not valid." >&2; return 1; }
  jn_id=$(own_id)
  if ! valid_device_id "$jn_id"; then
    echo "This node is not ready yet. Wait a minute and try again, or run: tinycloud doctor" >&2
    return 1
  fi
  echo "Send this line to the person who runs the gateway:"
  echo
  echo "  tinycloud-gw approve $jn_name $jn_id $jn_role $jn_owner"
  echo
  echo "They will see this code and should read it back to you:"
  echo
  echo "  $(verify_code "$jn_id")"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
