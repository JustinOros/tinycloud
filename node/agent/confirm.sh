#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

pending_json() {
  pj=$(read_state pending.json)
  if [ -n "$pj" ]; then
    printf '%s' "$pj"
  else
    printf '[]'
  fi
}

confirm_ids() {
  mkdir -p "$TC_STATE_DIR"
  printf '%s\n' "$1" | jq -r '.[]' >> "$(state_file confirmed.ids)"
  rm -f "$(state_file applied.sha)"
}

main() {
  cf_pending=$(pending_json)
  case ${1:-} in
    "")
      if [ "$(printf '%s' "$cf_pending" | jq 'length')" -eq 0 ]; then
        echo "Nothing is waiting for confirmation."
      else
        echo "Waiting for your confirmation:"
        printf '%s' "$cf_pending" | jq -r '.[] | "  \(.name)  \(.role)  owner \(.owner)"'
        echo "Run: tinycloud confirm NAME, or tinycloud confirm all"
      fi
      ;;
    all)
      confirm_ids "$(printf '%s' "$cf_pending" | jq -c 'map(.id)')"
      log INFO "confirmed all waiting peers"
      ;;
    *)
      if ! valid_name "$1"; then
        echo "That is not a valid node name." >&2
        return 1
      fi
      cf_ids=$(printf '%s' "$cf_pending" | jq -c --arg n "$1" 'map(select(.name == $n) | .id)')
      if [ "$(printf '%s' "$cf_ids" | jq 'length')" -eq 0 ]; then
        echo "No waiting peer is named $1." >&2
        return 1
      fi
      confirm_ids "$cf_ids"
      log INFO "confirmed peer $1"
      ;;
  esac
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
