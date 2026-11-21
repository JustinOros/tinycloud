#!/bin/sh
TC_SOURCED=1
. "${TC_ROOT:-/app}/agent/lib.sh"
. "${TC_ROOT:-/app}/agent/firstboot.sh"

DOC_FAILS=0

ok() {
  printf 'OK    %s\n' "$1"
}

warn() {
  printf 'WARN  %s\n      %s\n' "$1" "$2"
}

fail() {
  printf 'FAIL  %s\n      %s\n' "$1" "$2"
  DOC_FAILS=$((DOC_FAILS + 1))
}

tcp_check() {
  nc -z -w 5 "$1" "$2" > /dev/null 2>&1
}

dns_check() {
  curl -s --connect-timeout 5 -o /dev/null "http://$1:9/"
  dc_rc=$?
  [ "$dc_rc" -ne 6 ]
}

check_config() {
  dc_out=$(mktemp)
  if load_settings > "$dc_out" 2>&1; then
    ok "Config file is valid"
    rm -f "$dc_out"
    return 0
  fi
  fail "Config file has a problem" "$(tail -n 1 "$dc_out" | cut -d ' ' -f 5-)"
  rm -f "$dc_out"
  return 1
}

check_network() {
  if dns_check "$host"; then
    ok "Gateway name $host resolves"
  else
    fail "Cannot look up $host" "Check that this machine has internet and working DNS."
    return 1
  fi
  for dn_port in 22000:sync 22067:relay 8443:discovery; do
    if tcp_check "$host" "${dn_port%%:*}"; then
      ok "Gateway ${dn_port##*:} port ${dn_port%%:*} is reachable"
    else
      fail "Cannot reach gateway ${dn_port##*:} port ${dn_port%%:*}" "The gateway may be down, or a firewall is blocking this port."
    fi
  done
}

check_syncthing() {
  if ! st_api GET /rest/system/ping > /dev/null 2>&1; then
    fail "Syncthing is not answering" "Restart the node. If it keeps happening, run tinycloud logs syncthing."
    return 1
  fi
  ok "Syncthing is running"
  if [ -f "$(state_file firstboot.done)" ]; then
    ok "First boot setup is done"
  else
    fail "First boot setup has not finished" "Wait a minute and run doctor again. If it stays, run tinycloud logs agent."
  fi
  dc_conn=$(st_api GET /rest/system/connections 2> /dev/null || true)
  if [ "$(printf '%s' "$dc_conn" | jq -r --arg id "$gateway_id" '.connections[$id].connected // false' 2> /dev/null)" = true ]; then
    ok "Connected to the gateway"
  else
    fail "Not connected to the gateway" "Check the network checks above. Make sure the owner approved this node."
  fi
  dc_db=$(st_api GET "/rest/db/status?folder=tinycloud-library" 2> /dev/null || true)
  dc_state=$(printf '%s' "$dc_db" | jq -r '.state // "unknown"' 2> /dev/null)
  dc_errors=$(printf '%s' "$dc_db" | jq -r '.pullErrors // 0' 2> /dev/null)
  if [ "$dc_state" = error ] || [ "${dc_errors:-0}" -gt 0 ]; then
    warn "Library has sync errors ($dc_errors files)" "Run tinycloud logs syncthing to see which files."
  else
    ok "Library state: $dc_state"
  fi
}

check_disk() {
  dc_df=$(df -Pk "$TC_LIBRARY_DIR" | awk 'NR==2 {print $2 " " $4}')
  dc_total=${dc_df% *}
  dc_avail=${dc_df#* }
  dc_min_mb=$(calc_min_free_mb "$dc_total" "$pct" "$min_gb")
  dc_free_gb=$(awk -v kb="$dc_avail" 'BEGIN {printf "%.1f", kb / 1048576}')
  if [ $((dc_avail * 2 / 1024)) -lt $((dc_min_mb * 3)) ]; then
    warn "Disk is nearly full: $dc_free_gb GB free" "Syncthing stops pulling at the free space floor. Add storage or change the node role."
  else
    ok "Disk space: $dc_free_gb GB free"
  fi
}

check_clock() {
  dc_year=$(date -u +%Y)
  if [ "$dc_year" -ge 2025 ]; then
    ok "Clock looks right"
  else
    fail "Clock looks wrong (year $dc_year)" "Check that the host can reach an NTP server."
  fi
}

check_peers() {
  if [ -n "$(read_state rejected.sha)" ] && [ "$(read_state rejected.sha)" != "$(read_state applied.sha)" ]; then
    warn "The last peers.json was rejected" "Tell the gateway owner. Run tinycloud logs agent for the reason."
  fi
  dc_pending=$(jq 'length' "$(state_file pending.json)" 2> /dev/null || echo 0)
  if [ "$dc_pending" -gt 0 ]; then
    warn "$dc_pending new peers are waiting for your confirmation" "Confirm them to start syncing with them."
  fi
}

check_errors() {
  if [ -s "$TC_LOG_DIR/errors.log" ]; then
    warn "Recent errors in the log" "$(tail -n 3 "$TC_LOG_DIR/errors.log")"
  fi
}

main() {
  if check_config; then
    check_network || true
    check_syncthing || true
    check_disk
    check_peers
  fi
  check_clock
  check_errors
  if [ "$DOC_FAILS" -gt 0 ]; then
    printf '\n%s problems found.\n' "$DOC_FAILS"
    return 1
  fi
  printf '\nAll checks passed.\n'
}

if [ "${TC_DOCTOR_RUN:-1}" = 1 ]; then
  main "$@"
fi
