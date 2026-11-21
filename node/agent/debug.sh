#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

FACETS=connections,discover,relay

debug_on() {
  do_minutes=${TC_DEBUG_MINUTES:-30}
  if ! valid_int "$do_minutes"; then
    log ERROR "TC_DEBUG_MINUTES is not a number"
    return 1
  fi
  if ! st_api POST "/rest/system/debug?enable=$FACETS" > /dev/null; then
    log ERROR "could not turn debug on"
    return 1
  fi
  mkdir -p "$TC_STATE_DIR"
  write_atomic "$(state_file debug.until)" "$(($(date +%s) + do_minutes * 60))"
  log INFO "debug on for $do_minutes minutes"
}

debug_off() {
  if ! st_api POST "/rest/system/debug?disable=$FACETS" > /dev/null; then
    log ERROR "could not turn debug off"
    return 1
  fi
  rm -f "$(state_file debug.until)"
  log INFO "debug off"
}

debug_expire() {
  de_until=$(read_state debug.until)
  if [ -z "$de_until" ]; then
    return 0
  fi
  if ! valid_int "$de_until"; then
    rm -f "$(state_file debug.until)"
    return 0
  fi
  if [ "$(date +%s)" -ge "$de_until" ]; then
    debug_off
  fi
}

main() {
  case ${1:-} in
    on) debug_on ;;
    off) debug_off ;;
    expire) debug_expire ;;
    *)
      echo "usage: debug.sh on|off|expire" >&2
      return 2
      ;;
  esac
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
