#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

LIB_FOLDER=tinycloud-library
STATUS_DIR=${TC_STATUS_DIR:-$TC_SYSTEM_DIR/status-out}

list_paths() {
  find "$1" -mindepth 1 2> /dev/null
}

count_case_conflicts() {
  list_paths "$1" | tr '[:upper:]' '[:lower:]' | sort | uniq -d | wc -l | tr -d ' '
}

collect_status() {
  cs_db=$(st_api GET "/rest/db/status?folder=$LIB_FOLDER") || return 1
  cs_global=$(printf '%s' "$cs_db" | jq -r '.globalBytes // 0')
  cs_local=$(printf '%s' "$cs_db" | jq -r '.localBytes // 0')
  if [ "$cs_global" -le 0 ]; then
    st_percent=100
  else
    st_percent=$((cs_local * 100 / cs_global))
    if [ "$st_percent" -gt 100 ]; then
      st_percent=100
    fi
  fi
  cs_df=$(df -Pk "$TC_LIBRARY_DIR" | awk 'NR==2 {print $2 " " $4}')
  cs_total_kb=${cs_df% *}
  cs_avail_kb=${cs_df#* }
  if ! valid_int "$cs_total_kb" || ! valid_int "$cs_avail_kb"; then
    log ERROR "could not read disk size"
    return 1
  fi
  st_free_bytes=$((cs_avail_kb * 1024))
  cs_pct=$(conf_get FREE_SPACE_PERCENT 10)
  cs_gb=$(conf_get FREE_SPACE_MIN_GB 1)
  cs_min_mb=$(calc_min_free_mb "$cs_total_kb" "$cs_pct" "$cs_gb")
  cs_free_mb=$((cs_avail_kb / 1024))
  st_low=false
  if [ $((cs_free_mb * 2)) -lt $((cs_min_mb * 3)) ]; then
    st_low=true
  fi
  st_conflicts=$(count_case_conflicts "$TC_LIBRARY_DIR")
}

build_status_json() {
  jq -nc --arg name "$(conf_get NODE_NAME)" --arg role "$(conf_get ROLE reader)" --arg version "$TC_VERSION" \
    --argjson pct "$st_percent" --argjson free "$st_free_bytes" --argjson low "$st_low" \
    --argjson cc "$st_conflicts" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{v: 1, name: $name, role: $role, version: $version, percent_stored: $pct, free_bytes: $free,
      low_space: $low, case_conflicts: $cc, time: $time}'
}

should_write_status() {
  if [ -z "$1" ]; then
    return 0
  fi
  jq -ne --argjson a "$1" --argjson b "$2" --argjson now "$3" --argjson last "$4" '
    def absval: if . < 0 then -. else . end;
    (($a.percent_stored - $b.percent_stored) | absval) >= 2
    or $a.low_space != $b.low_space
    or $a.version != $b.version
    or $a.role != $b.role
    or $a.case_conflicts != $b.case_conflicts
    or ($now - $last) >= 86400' > /dev/null
}

write_status_file() {
  mkdir -p "$STATUS_DIR"
  ws_tmp=$STATUS_DIR/.syncthing.status.json.tmp
  printf '%s\n' "$1" > "$ws_tmp" && mv "$ws_tmp" "$STATUS_DIR/status.json"
}

main() {
  mkdir -p "$TC_STATE_DIR"
  if ! collect_status; then
    log ERROR "could not collect status"
    return 1
  fi
  new_json=$(build_status_json)
  write_atomic "$(state_file status.local.json)" "$new_json"
  prev_json=$(read_state status.sent.json)
  last_at=$(read_state status.sent.at)
  now=$(date +%s)
  if should_write_status "$prev_json" "$new_json" "$now" "${last_at:-0}"; then
    write_status_file "$new_json"
    write_atomic "$(state_file status.sent.json)" "$new_json"
    write_atomic "$(state_file status.sent.at)" "$now"
    log INFO "status written: stored=$st_percent% low_space=$st_low case_conflicts=$st_conflicts"
  fi
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
