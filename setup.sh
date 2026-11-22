#!/bin/sh
set -u

TC_REPO=${TC_REPO:-JustinOros/tinycloud}
TC_REF=${TC_REF:-main}
SELF_DIR=${SETUP_SELF_DIR:-$(cd "$(dirname "$0")" 2> /dev/null && pwd)}
INPUT=${SETUP_INPUT:-/dev/tty}
GW_HOME=${GW_HOME:-/opt/tinycloud-gateway}
HOST=
SSH_PORT=
AUTO_REBOOT=
REBOOT_TIME=
ASSUME_YES=false
DRY_RUN=false
SRC=
ANSWER=

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  return 1
}

ask_value() {
  av_default=${2:-}
  if [ "$ASSUME_YES" = true ]; then
    ANSWER=$av_default
    return 0
  fi
  if [ -n "$av_default" ]; then
    printf '%s [%s]: ' "$1" "$av_default"
  else
    printf '%s: ' "$1"
  fi
  if ! read -r ANSWER <&3; then
    ANSWER=
    return 1
  fi
  if [ -z "$ANSWER" ]; then
    ANSWER=$av_default
  fi
}

ask_yes() {
  ay_default=${2:-y}
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  if [ "$ay_default" = y ]; then
    printf '%s [Y/n]: ' "$1"
  else
    printf '%s [y/N]: ' "$1"
  fi
  if ! read -r ay_answer <&3; then
    return 1
  fi
  case $ay_answer in
    y | Y | yes | YES) return 0 ;;
    n | N | no | NO) return 1 ;;
    '') [ "$ay_default" = y ] ;;
    *) return 1 ;;
  esac
}

usage() {
  say "usage: sh setup.sh [--host HOSTNAME] [--ssh-port N] [--auto-reboot yes|no] [--reboot-time TIME] [--yes] [--dry-run]"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --host)
        [ $# -ge 2 ] || { usage; return 1; }
        HOST=$2
        shift 2
        ;;
      --ssh-port)
        [ $# -ge 2 ] || { usage; return 1; }
        SSH_PORT=$2
        shift 2
        ;;
      --auto-reboot)
        [ $# -ge 2 ] || { usage; return 1; }
        AUTO_REBOOT=$2
        shift 2
        ;;
      --reboot-time)
        [ $# -ge 2 ] || { usage; return 1; }
        REBOOT_TIME=$2
        shift 2
        ;;
      --yes)
        ASSUME_YES=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      *)
        usage
        return 1
        ;;
    esac
  done
  if [ "$ASSUME_YES" = true ] && [ -z "$HOST" ]; then
    fail "--yes needs --host"
  fi
}

open_input() {
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  if ! ( : < "$INPUT" ) 2> /dev/null; then
    fail "no terminal to ask questions on. Run it as: sh setup.sh"
    return 1
  fi
  exec 3< "$INPUT"
}

ensure_root() {
  if [ "$DRY_RUN" = true ] || [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if command -v sudo > /dev/null 2>&1; then
    say "This needs root."
    if ask_yes "Run it again with sudo?" y; then
      exec sudo sh "$0" "$@"
    fi
  fi
  fail "run as root"
}

ensure_tool() {
  if command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  say "$1 is missing."
  if ! ask_yes "Install $1 now?" y; then
    fail "$1 is needed"
    return 1
  fi
  if [ "$DRY_RUN" = true ]; then
    say "+ apt-get install -y $1"
    return 0
  fi
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"
}

download_tarball() {
  curl -fsSL --max-time 120 "https://github.com/$TC_REPO/archive/$TC_REF.tar.gz"
}

fetch_tree() {
  SRC=${SETUP_SRC:-/opt/tinycloud-src}
  case $SRC in
    '' | /) fail "bad source folder"; return 1 ;;
  esac
  if ! printf '%s' "$TC_REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    fail "bad TC_REPO"
    return 1
  fi
  if ! printf '%s' "$TC_REF" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
    fail "bad TC_REF"
    return 1
  fi
  ensure_tool curl || return 1
  ensure_tool tar || return 1
  say "Downloading TinyCloud ($TC_REPO, $TC_REF)..."
  ft_tmp=$(mktemp -d)
  if ! download_tarball | tar xz --strip-components=1 -C "$ft_tmp"; then
    rm -rf "$ft_tmp"
    fail "download failed"
    return 1
  fi
  if [ ! -f "$ft_tmp/gateway/gateway.sh" ]; then
    rm -rf "$ft_tmp"
    fail "the download does not look like TinyCloud"
    return 1
  fi
  rm -rf "$SRC"
  mkdir -p "$(dirname "$SRC")"
  mv "$ft_tmp" "$SRC"
}

find_tree() {
  if [ -f "$SELF_DIR/gateway/gateway.sh" ]; then
    SRC=$SELF_DIR
    return 0
  fi
  fetch_tree
}

load_lib() {
  GW_DIR=$SRC/gateway
  . "$GW_DIR/lib.sh"
}

resolve_host() {
  getent ahostsv4 "$1" 2> /dev/null | awk 'NR==1 {print $1}'
}

local_ips() {
  if command -v ip > /dev/null 2>&1; then
    ip -4 -o addr show 2> /dev/null | awk '{split($4, a, "/"); print a[1]}'
  else
    hostname -I 2> /dev/null | tr ' ' '\n'
  fi
}

check_dns() {
  if printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
    say "Note: an IP address works, but a hostname is better. You can move a hostname if you rebuild the server."
    return 0
  fi
  cd_ip=$(resolve_host "$1")
  if [ -z "$cd_ip" ]; then
    say "Note: $1 does not resolve yet. Add an A record for it that points at this server. The install does not need it, but nodes do."
    return 0
  fi
  if local_ips | grep -qx "$cd_ip"; then
    say "$1 points at this server ($cd_ip). Good."
  else
    say "Note: $1 points at $cd_ip, which is not an address on this server. That is fine behind NAT or while DNS is updating."
  fi
}

detect_ssh_port() {
  dp_port=$(sshd -T 2> /dev/null | awk '$1 == "port" {print $2; exit}')
  if valid_port "${dp_port:-}"; then
    printf '%s' "$dp_port"
  else
    printf '22'
  fi
}

existing_host() {
  sed -n 's/^GATEWAY_HOST=//p' "$GW_HOME/.env" 2> /dev/null | tail -n 1
}

choose_host() {
  ch_try=0
  ch_default=$(existing_host)
  while [ "$ch_try" -lt 3 ]; do
    if [ -z "$HOST" ]; then
      ask_value "Hostname nodes will use to reach this gateway (for example gw.example.com)" "$ch_default" || return 1
      HOST=$ANSWER
    fi
    if valid_host "$HOST"; then
      return 0
    fi
    say "That is not a valid hostname. Use letters, numbers, dots, and dashes."
    HOST=
    ch_try=$((ch_try + 1))
  done
  fail "no valid hostname"
}

choose_ssh_port() {
  if [ -n "$SSH_PORT" ]; then
    valid_port "$SSH_PORT" || fail "bad SSH port"
    return
  fi
  ask_value "SSH port" "$(detect_ssh_port)" || return 1
  SSH_PORT=$ANSWER
  valid_port "$SSH_PORT" || fail "bad SSH port"
}

choose_reboot() {
  case $AUTO_REBOOT in
    '' | yes | no) ;;
    *) fail "--auto-reboot must be yes or no"; return 1 ;;
  esac
  if [ -z "$AUTO_REBOOT" ]; then
    if [ "$ASSUME_YES" = true ] || ask_yes "Reboot automatically when an update needs it? (about a minute offline)" y; then
      AUTO_REBOOT=yes
    else
      AUTO_REBOOT=no
    fi
  fi
  if [ "$AUTO_REBOOT" = no ]; then
    return 0
  fi
  cr_try=0
  while [ "$cr_try" -lt 3 ]; do
    if [ -z "$REBOOT_TIME" ]; then
      ask_value "Reboot time (this server's local time, like 4:00 AM)" "4:00 AM" || return 1
      REBOOT_TIME=$ANSWER
    fi
    if valid_reboot_time "$REBOOT_TIME"; then
      REBOOT_TIME=$(time_24h "$REBOOT_TIME")
      return 0
    fi
    say "That is not a valid time."
    REBOOT_TIME=
    if [ "$ASSUME_YES" = true ]; then
      break
    fi
    cr_try=$((cr_try + 1))
  done
  fail "no valid reboot time"
}

show_plan() {
  say ""
  say "This will:"
  say "  - install Docker, fail2ban, nftables, and automatic security updates"
  say "  - start the Syncthing, relay, and discovery services"
  say "  - open only ports $SSH_PORT (SSH), 22000, 22067, and 8443"
  if [ "$AUTO_REBOOT" = yes ]; then
    say "  - reboot at $(time_12h "$REBOOT_TIME") when an update needs it"
  else
    say "  - not reboot automatically (alerts will tell you when a reboot is needed)"
  fi
  if has_ssh_key; then
    say "  - turn off SSH password logins (an SSH key was found)"
  else
    say "  - leave SSH passwords on, because no SSH key was found for root"
  fi
  if [ -f "$GW_HOME/.env" ]; then
    say "  - keep the existing gateway identity (this server is already set up)"
  fi
  say ""
  say "Hostname: $HOST"
  say "System:   $os_id $os_version"
  say ""
}

run_install() {
  set -- --host "$HOST" --ssh-port "$SSH_PORT" --auto-reboot "$AUTO_REBOOT"
  if [ "$AUTO_REBOOT" = yes ]; then
    set -- "$@" --reboot-time "$REBOOT_TIME"
  fi
  if [ "$DRY_RUN" = true ]; then
    set -- "$@" --dry-run
  fi
  sh "$SRC/gateway/gateway.sh" "$@"
}

finish_up() {
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  if ask_yes "Save a backup of the gateway identity now?" y; then
    "$GW_HOME/tinycloud-gw" backup
  fi
  say ""
  say "Next:"
  say "  1. Put the lines above into each node's tinycloud.conf."
  say "     Show them again any time with: tinycloud-gw config"
  say "  2. When a node shows its join line, run:"
  say "     tinycloud-gw approve NAME DEVICEID ROLE OWNER"
}

main() {
  parse_args "$@" || return 1
  open_input || return 1
  say "TinyCloud gateway setup"
  say ""
  ensure_root "$@" || return 1
  find_tree || return 1
  load_lib
  if ! detect_os || ! os_supported; then
    fail "unsupported system: ${os_id:-unknown} ${os_version:-}. Use Debian 12 or newer, or Ubuntu 22.04 or newer."
    return 1
  fi
  say "System: $os_id $os_version ($os_codename)"
  choose_host || return 1
  check_dns "$HOST"
  choose_ssh_port || return 1
  choose_reboot || return 1
  show_plan
  if ! ask_yes "Continue?" y; then
    say "cancelled"
    return 1
  fi
  run_install || return 1
  finish_up
}

if [ "${SETUP_NO_MAIN:-}" != 1 ]; then
  main "$@"
  exit $?
fi
