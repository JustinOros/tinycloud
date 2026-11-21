#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

run_step() {
  sh "$TC_ROOT/agent/$1.sh"
}

main() {
  agent_rc=0
  st_wait 30 || return 1
  run_step firstboot || return 1
  run_step apply-peers || agent_rc=1
  agent_count=$(read_state run.count)
  agent_count=$((${agent_count:-0} + 1))
  if [ ! -f "$(state_file status.local.json)" ] || [ $((agent_count % 3)) -eq 0 ]; then
    run_step status || agent_rc=1
  fi
  write_atomic "$(state_file run.count)" "$((agent_count % 3))"
  return "$agent_rc"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  main "$@"
fi
