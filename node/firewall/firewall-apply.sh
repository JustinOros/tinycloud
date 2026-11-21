#!/bin/sh
NODE_ENV=${TC_NODE_ENV:-/etc/tinycloud/node.env}
FW_DIR=${TC_FW_DIR:-/etc/tinycloud}
RULES=${TC_FW_RULES:-/opt/tinycloud/firewall/firewall.nft}

env_get() {
  sed -n "s/^$1=//p" "$NODE_ENV" 2> /dev/null | tail -n 1 | tr -d '\r'
}

valid_ipv4() {
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

valid_host() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'
}

resolve_gateway() {
  getent ahostsv4 "$1" | awk 'NR==1 {print $1}'
}

find_router() {
  ip -4 route show default | awk 'NR==1 {print $3}'
}

lan_ports() {
  fw_ports=80
  if [ "$(env_get SSH_ENABLED)" = true ]; then
    fw_ports="$fw_ports, 22"
  fi
  if [ "$(env_get SMB_ENABLED)" = true ]; then
    fw_ports="$fw_ports, 445"
  fi
  printf '{ %s }' "$fw_ports"
}

write_vars() {
  fw_host=$(env_get GATEWAY_HOST)
  if ! valid_host "$fw_host"; then
    echo "GATEWAY_HOST is missing or invalid" >&2
    return 1
  fi
  fw_gateway=$(resolve_gateway "$fw_host")
  fw_router=$(find_router)
  if ! valid_ipv4 "$fw_gateway"; then
    echo "could not resolve the gateway" >&2
    return 1
  fi
  if ! valid_ipv4 "$fw_router"; then
    echo "could not find the router" >&2
    return 1
  fi
  mkdir -p "$FW_DIR"
  printf 'define GATEWAY = %s\ndefine ROUTER = %s\ndefine LAN_TCP = %s\n' \
    "$fw_gateway" "$fw_router" "$(lan_ports)" > "$FW_DIR/firewall.vars.nft.tmp"
  mv "$FW_DIR/firewall.vars.nft.tmp" "$FW_DIR/firewall.vars.nft"
}

main() {
  write_vars || return 1
  nft -c -f "$RULES" || return 1
  nft -f "$RULES"
  echo "firewall loaded"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
