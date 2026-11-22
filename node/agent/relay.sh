#!/bin/sh
RELAY_OUTER_SOURCED=${TC_SOURCED:-0}
TC_SOURCED=1
. "${TC_ROOT:-/app}/agent/firstboot.sh"
TC_SOURCED=$RELAY_OUTER_SOURCED

relay_main() {
  load_settings || return 1
  st_wait 60 || return 1
  apply_options || return 1
  restart_if_needed || return 1
  log INFO "relay token applied"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  relay_main "$@"
fi
