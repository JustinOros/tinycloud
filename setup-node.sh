#!/bin/sh
set -u

TC_REPO=${TC_REPO:-JustinOros/tinycloud}
TC_REF=${TC_REF:-main}
SELF_DIR=${SETUP_SELF_DIR:-$(cd "$(dirname "$0")" 2> /dev/null && pwd)}
INPUT=${SETUP_INPUT:-/dev/tty}
NODE_HOME=${NODE_HOME:-/opt/tinycloud-node}
NODE_NAME=
OWNER=
ROLE=
TZ_NAME=
FIREWALL=
SSH_HARDEN=
CHANNEL=
SMB=
SMB_MODE=
SMB_USER=
SMB_GUEST=
SMB_OWNER=
SMB_PASSWORD=
UPDATE_ONLY=false
PREV_TAR=${TC_PREV_TAR:-/var/tmp/tinycloud-node-prev.tar}
AUTO_UPDATE=
AUTO_REBOOT=
REBOOT_TIME=
UPDATE_CONF_DIR=${UPDATE_CONF_DIR:-/etc/apt/apt.conf.d}
CONFIG_FILE=
G_HOST=
G_ID=
R_ID=
D_ID=
G_TOKEN=
ASSUME_YES=false
DRY_RUN=false
KEEP_CONFIG=false
SRC=
ANSWER=
TARGET_USER=${SETUP_USER:-${SUDO_USER:-}}

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  return 1
}

run() {
  if [ "$DRY_RUN" = true ]; then
    say "+ $*"
    return 0
  fi
  "$@"
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
  say "usage: sh setup-node.sh [--name NAME] [--owner OWNER] [--role ROLE] [--timezone TZ] [--channel stable|testing|off] [--firewall yes|no] [--ssh-hardening yes|no] [--smb yes|no] [--smb-mode ro|rw] [--smb-user NAME] [--smb-guest yes|no] [--auto-update yes|no] [--auto-reboot yes|no] [--reboot-time TIME] [--config FILE] [--yes] [--dry-run]"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --name | --owner | --role | --timezone | --config | --auto-update | --auto-reboot | --reboot-time | --firewall | --ssh-hardening | --channel | --smb | --smb-mode | --smb-user | --smb-guest)
        [ $# -ge 2 ] || { usage; return 1; }
        case $1 in
          --name) NODE_NAME=$2 ;;
          --owner) OWNER=$2 ;;
          --role) ROLE=$2 ;;
          --timezone) TZ_NAME=$2 ;;
          --config) CONFIG_FILE=$2 ;;
          --auto-update) AUTO_UPDATE=$2 ;;
          --auto-reboot) AUTO_REBOOT=$2 ;;
          --reboot-time) REBOOT_TIME=$2 ;;
          --firewall) FIREWALL=$2 ;;
          --channel) CHANNEL=$2 ;;
          --ssh-hardening) SSH_HARDEN=$2 ;;
          --smb) SMB=$2 ;;
          --smb-mode) SMB_MODE=$2 ;;
          --smb-user) SMB_USER=$2 ;;
          --smb-guest) SMB_GUEST=$2 ;;
        esac
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
      --update)
        UPDATE_ONLY=true
        shift
        ;;
      *)
        usage
        return 1
        ;;
    esac
  done
  if [ "$UPDATE_ONLY" = true ]; then
    return 0
  fi
  if [ "$ASSUME_YES" = true ] && { [ -z "$NODE_NAME" ] || [ -z "$OWNER" ] || [ -z "$CONFIG_FILE" ]; }; then
    fail "--yes needs --name, --owner, and --config"
  fi
}

open_input() {
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  if ! ( : < "$INPUT" ) 2> /dev/null; then
    fail "no terminal to ask questions on. Run it as: sh setup-node.sh"
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
  if [ ! -f "$ft_tmp/node/docker-compose.yml" ] || [ ! -f "$ft_tmp/gateway/lib.sh" ]; then
    rm -rf "$ft_tmp"
    fail "the download does not look like TinyCloud"
    return 1
  fi
  rm -rf "$SRC"
  mkdir -p "$(dirname "$SRC")"
  mv "$ft_tmp" "$SRC"
}

find_tree() {
  if [ -f "$SELF_DIR/node/docker-compose.yml" ] && [ -f "$SELF_DIR/gateway/lib.sh" ]; then
    SRC=$SELF_DIR
    return 0
  fi
  fetch_tree
}

load_lib() {
  GW_DIR=$SRC/gateway
  . "$GW_DIR/lib.sh"
  . "$SRC/node/harden/harden.sh"
  . "$SRC/node/harden/smb.sh"
}

valid_tz_name() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_/+-]{1,64}$'
}

default_name() {
  dn_host=$(hostname 2> /dev/null | tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9-' '-' | cut -c 1-32)
  dn_host=${dn_host#-}
  dn_host=${dn_host%-}
  if valid_name "$dn_host"; then
    printf '%s' "$dn_host"
  fi
}

default_tz() {
  dt_tz=$(cat /etc/timezone 2> /dev/null | head -n 1)
  if ! valid_tz_name "${dt_tz:-}"; then
    dt_tz=$(timedatectl show -p Timezone --value 2> /dev/null)
  fi
  if valid_tz_name "${dt_tz:-}"; then
    printf '%s' "$dt_tz"
  else
    printf 'UTC'
  fi
}

existing_value() {
  sed -n "s/^$1=//p" "$NODE_HOME/tinycloud.conf" 2> /dev/null | tail -n 1
}

choose_value() {
  cv_label=$1
  cv_default=$2
  cv_check=$3
  cv_try=0
  while [ "$cv_try" -lt 3 ]; do
    ask_value "$cv_label" "$cv_default" || return 1
    if "$cv_check" "$ANSWER"; then
      return 0
    fi
    say "That is not valid."
    cv_try=$((cv_try + 1))
  done
  fail "no valid answer for: $cv_label"
}

role_name() {
  case $1 in
    1 | anchor) printf 'anchor' ;;
    2 | contributor) printf 'contributor' ;;
    3 | partial) printf 'partial' ;;
    4 | reader) printf 'reader' ;;
  esac
}

valid_role_choice() {
  [ -n "$(role_name "$1")" ]
}

choose_role() {
  say "Role:"
  say "  1) anchor       always on, full copy"
  say "  2) contributor  sends and receives"
  say "  3) partial      stores what fits"
  say "  4) reader       receives only"
  choose_value "Which role? (number)" 4 valid_role_choice || return 1
  ROLE=$(role_name "$ANSWER")
}

time_24h() {
  t24_in=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
  t24_re='^([0-9]{1,2})(:([0-9]{2}))?(AM|PM)?$'
  t24_h=$(printf '%s' "$t24_in" | sed -nE "s/$t24_re/\\1/p" | sed 's/^0*\([0-9]\)/\1/')
  t24_m=$(printf '%s' "$t24_in" | sed -nE "s/$t24_re/\\3/p" | sed 's/^0*\([0-9]\)/\1/')
  t24_ap=$(printf '%s' "$t24_in" | sed -nE "s/$t24_re/\\4/p")
  [ -n "$t24_h" ] || return 1
  t24_m=${t24_m:-0}
  [ "$t24_m" -le 59 ] || return 1
  if [ -n "$t24_ap" ]; then
    [ "$t24_h" -ge 1 ] && [ "$t24_h" -le 12 ] || return 1
    if [ "$t24_ap" = AM ] && [ "$t24_h" -eq 12 ]; then
      t24_h=0
    elif [ "$t24_ap" = PM ] && [ "$t24_h" -ne 12 ]; then
      t24_h=$((t24_h + 12))
    fi
  else
    [ "$t24_h" -le 23 ] || return 1
  fi
  printf '%02d:%02d' "$t24_h" "$t24_m"
}

time_12h() {
  t12_h=$(printf '%s' "${1%%:*}" | sed 's/^0*\([0-9]\)/\1/')
  t12_m=${1#*:}
  t12_ap=AM
  [ "$t12_h" -ge 12 ] && t12_ap=PM
  t12_h=$((t12_h % 12))
  [ "$t12_h" -eq 0 ] && t12_h=12
  printf '%s:%s %s' "$t12_h" "$t12_m" "$t12_ap"
}

valid_reboot_time() {
  [ -n "$(time_24h "$1")" ]
}

choose_updates() {
  case $AUTO_UPDATE in
    '' | yes | no) ;;
    *) fail "--auto-update must be yes or no"; return 1 ;;
  esac
  case $AUTO_REBOOT in
    '' | yes | no) ;;
    *) fail "--auto-reboot must be yes or no"; return 1 ;;
  esac
  if [ -z "$AUTO_UPDATE" ]; then
    if [ "$ASSUME_YES" = true ]; then
      AUTO_UPDATE=no
    elif ask_yes "Install security updates automatically?" y; then
      AUTO_UPDATE=yes
    else
      AUTO_UPDATE=no
    fi
  fi
  if [ "$AUTO_UPDATE" = no ]; then
    if [ "$AUTO_REBOOT" = yes ]; then
      fail "--auto-reboot needs automatic updates"
      return 1
    fi
    AUTO_REBOOT=no
    return 0
  fi
  if [ -z "$AUTO_REBOOT" ]; then
    if [ "$ASSUME_YES" = true ]; then
      AUTO_REBOOT=yes
    elif ask_yes "Reboot automatically when an update needs it?" y; then
      AUTO_REBOOT=yes
    else
      AUTO_REBOOT=no
    fi
  fi
  if [ "$AUTO_REBOOT" = yes ]; then
    if [ -z "$REBOOT_TIME" ]; then
      choose_value "Reboot time (the board's local time, like 3:00 AM)" "3:00 AM" valid_reboot_time || return 1
      REBOOT_TIME=$ANSWER
    fi
    valid_reboot_time "$REBOOT_TIME" || { fail "bad reboot time"; return 1; }
    REBOOT_TIME=$(time_24h "$REBOOT_TIME")
  fi
}

choose_yes_no() {
  cyn_var=$1
  eval "cyn_now=\$$cyn_var"
  case $cyn_now in
    yes | no) return 0 ;;
    '') ;;
    *) fail "$2 must be yes or no"; return 1 ;;
  esac
  if [ "$ASSUME_YES" = true ]; then
    cyn_now=no
  elif ask_yes "$3" y; then
    cyn_now=yes
  else
    cyn_now=no
  fi
  eval "$cyn_var=\$cyn_now"
}

channel_name() {
  case $1 in
    1 | stable) printf 'stable' ;;
    2 | testing) printf 'testing' ;;
    3 | off) printf 'off' ;;
  esac
}

valid_channel_choice() {
  [ -n "$(channel_name "$1")" ]
}

choose_channel() {
  if [ -n "$CHANNEL" ]; then
    valid_channel_choice "$CHANNEL" || { fail "--channel must be stable, testing, or off"; return 1; }
    CHANNEL=$(channel_name "$CHANNEL")
    return 0
  fi
  [ "$ASSUME_YES" = true ] && return 0
  say "Update TinyCloud itself every night:"
  say "  1) stable   tested releases"
  say "  2) testing  newest changes, may break"
  say "  3) off      update by hand"
  choose_value "Which channel? (number)" 3 valid_channel_choice || return 1
  CHANNEL=$(channel_name "$ANSWER")
}

choose_hardening() {
  choose_yes_no FIREWALL --firewall "Turn on the firewall (blocks everything except SSH from your local network)?" || return 1
  choose_yes_no SSH_HARDEN --ssh-hardening "Harden SSH (no password login when a key is installed, plus fail2ban)?" || return 1
  choose_channel || return 1
}

harden_summary() {
  if [ "$FIREWALL" = yes ]; then
    printf 'firewall on'
  else
    printf 'firewall unchanged'
  fi
  if [ "$SSH_HARDEN" = yes ]; then
    printf ', SSH hardened'
  else
    printf ', SSH unchanged'
  fi
  case $CHANNEL in
    stable | testing) printf ', nightly self-update (%s)' "$CHANNEL" ;;
    off) printf ', no self-update' ;;
  esac
}

update_summary() {
  case $AUTO_UPDATE in
    yes)
      if [ "$AUTO_REBOOT" = yes ]; then
        printf 'automatic security updates, reboot at %s when needed' "$(time_12h "$REBOOT_TIME")"
      else
        printf 'automatic security updates, no automatic reboot'
      fi
      ;;
    no) printf 'not automatic' ;;
  esac
}

render_node_unattended() {
  printf 'Unattended-Upgrade::Origins-Pattern {\n'
  printf '  "origin=Debian,codename=%s-security,label=Debian-Security";\n' "$os_codename"
  printf '};\n'
  if [ "$AUTO_REBOOT" = yes ]; then
    printf 'Unattended-Upgrade::Automatic-Reboot "true";\n'
    printf 'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";\n'
    printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$REBOOT_TIME"
  else
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
  fi
}

render_node_periodic() {
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n'
}

ensure_package() {
  if dpkg -s "$1" > /dev/null 2>&1; then
    return 0
  fi
  say "$1 is missing."
  if ! ask_yes "Install $1 now?" y; then
    return 1
  fi
  if [ "$DRY_RUN" = true ]; then
    say "+ apt-get install -y $1"
    return 0
  fi
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"
}

setup_updates() {
  [ "$AUTO_UPDATE" = yes ] || return 0
  if ! ensure_package unattended-upgrades; then
    say "Skipping automatic updates."
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    say "+ write $UPDATE_CONF_DIR/52tinycloud-unattended"
    say "+ write $UPDATE_CONF_DIR/20auto-upgrades"
    return 0
  fi
  mkdir -p "$UPDATE_CONF_DIR" || return 1
  render_node_unattended > "$UPDATE_CONF_DIR/52tinycloud-unattended" || return 1
  render_node_periodic > "$UPDATE_CONF_DIR/20auto-upgrades" || return 1
  chmod 644 "$UPDATE_CONF_DIR/52tinycloud-unattended" "$UPDATE_CONF_DIR/20auto-upgrades"
}

choose_basics() {
  if [ -z "$NODE_NAME" ]; then
    choose_value "Name for this node (lowercase letters, numbers, dashes)" "$(default_name)" valid_name || return 1
    NODE_NAME=$ANSWER
  fi
  valid_name "$NODE_NAME" || { fail "bad node name"; return 1; }
  if [ -z "$OWNER" ]; then
    choose_value "Owner of this node (the person it belongs to)" "$(existing_value OWNER)" valid_name || return 1
    OWNER=$ANSWER
  fi
  valid_name "$OWNER" || { fail "bad owner"; return 1; }
  if [ -z "$ROLE" ]; then
    choose_role || return 1
  fi
  valid_role "$ROLE" || { fail "bad role"; return 1; }
  if [ -z "$TZ_NAME" ]; then
    choose_value "Timezone" "$(default_tz)" valid_tz_name || return 1
    TZ_NAME=$ANSWER
  fi
  valid_tz_name "$TZ_NAME" || { fail "bad timezone"; return 1; }
}

line_value() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -n 1 | tr -d "\r \"'"
}

bad_secret() {
  case $1 in
    REDACTED | changeme | '') return 0 ;;
  esac
  return 1
}

parse_gateway() {
  pg_host=$(line_value "$1" GATEWAY_HOST)
  pg_gid=$(line_value "$1" GATEWAY_ID)
  pg_rid=$(line_value "$1" RELAY_ID)
  pg_did=$(line_value "$1" DISCOVERY_ID)
  pg_tok=$(line_value "$1" RELAY_TOKEN)
  valid_host "$pg_host" || { say "GATEWAY_HOST is missing or not valid."; return 1; }
  valid_device_id "$pg_gid" || { say "GATEWAY_ID is missing or not valid."; return 1; }
  valid_device_id "$pg_rid" || { say "RELAY_ID is missing or not valid."; return 1; }
  valid_device_id "$pg_did" || { say "DISCOVERY_ID is missing or not valid."; return 1; }
  valid_token "$pg_tok" || { say "RELAY_TOKEN is missing or not valid."; return 1; }
  if bad_secret "$pg_tok"; then
    say "RELAY_TOKEN is a placeholder. Use the real token from the gateway."
    return 1
  fi
  G_HOST=$pg_host
  G_ID=$pg_gid
  R_ID=$pg_rid
  D_ID=$pg_did
  G_TOKEN=$pg_tok
}

read_pasted() {
  rp_text=
  while read -r rp_line <&3; do
    [ -n "$rp_line" ] || break
    rp_text="$rp_text$rp_line
"
  done
  printf '%s' "$rp_text"
}

choose_gateway() {
  if [ -n "$CONFIG_FILE" ]; then
    [ -r "$CONFIG_FILE" ] || { fail "cannot read $CONFIG_FILE"; return 1; }
    parse_gateway "$(cat "$CONFIG_FILE")" || { fail "the gateway lines in $CONFIG_FILE are not valid"; return 1; }
    return 0
  fi
  cg_try=0
  while [ "$cg_try" -lt 3 ]; do
    say "On the gateway, run: tinycloud-gw config"
    say "Paste the five lines here, then press Enter on an empty line:"
    cg_text=$(read_pasted)
    if parse_gateway "$cg_text"; then
      return 0
    fi
    cg_try=$((cg_try + 1))
  done
  fail "no valid gateway lines"
}

check_existing() {
  if [ ! -f "$NODE_HOME/tinycloud.conf" ]; then
    return 0
  fi
  say "A node is already set up here ($(existing_value NODE_NAME))."
  if ask_yes "Keep its settings and just update the software?" y; then
    KEEP_CONFIG=true
  fi
}

show_plan() {
  say ""
  say "This will:"
  say "  - make sure Docker is installed"
  say "  - install the node into $NODE_HOME"
  say "  - start the Syncthing and agent containers"
  say "  - add the tinycloud command and a ~/tinycloud shortcut to your files"
  say ""
  if [ "$KEEP_CONFIG" = true ]; then
    say "Settings: keep the existing ones"
  else
    say "Node:     $NODE_NAME (owner $OWNER, role $ROLE)"
    say "Gateway:  $G_HOST"
    say "Timezone: $TZ_NAME"
  fi
  if [ -n "$AUTO_UPDATE" ]; then
    say "Updates:  $(update_summary)"
  fi
  if [ -n "$FIREWALL$SSH_HARDEN$CHANNEL" ]; then
    say "Security: $(harden_summary)"
  fi
  if [ "$SMB" = yes ]; then
    say "SMB:      $(smb_summary)"
  elif [ "$SMB" = no ] && smb_present; then
    say "SMB:      off, the existing share is removed"
  fi
  say "System:   $os_id $os_version"
  say ""
}

install_docker() {
  if command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
    return 0
  fi
  say "Docker with the compose plugin is missing."
  if ! ask_yes "Install Docker now (Docker's official script, get.docker.com)?" y; then
    fail "Docker is needed"
    return 1
  fi
  ensure_tool curl || return 1
  if [ "$DRY_RUN" = true ]; then
    say "+ curl -fsSL https://get.docker.com | sh"
    return 0
  fi
  curl -fsSL https://get.docker.com | sh || { fail "Docker install failed"; return 1; }
  docker compose version > /dev/null 2>&1 || { fail "Docker installed but the compose plugin is missing"; return 1; }
}

install_files() {
  run mkdir -p "$NODE_HOME" || return 1
  if [ "$DRY_RUN" = true ]; then
    say "+ copy node files into $NODE_HOME"
    return 0
  fi
  tar -C "$SRC/node" --exclude=./data --exclude=./tinycloud.conf --exclude=./tests -cf - . | tar -C "$NODE_HOME" -xf - || return 1
  mkdir -p "$NODE_HOME/data/library" "$NODE_HOME/host"
  chown 1000:1000 "$NODE_HOME/data/library" 2> /dev/null || true
  if [ -n "${OWNER:-}" ]; then
    mkdir -p "$NODE_HOME/data/library/$OWNER"
    chown 1000:1000 "$NODE_HOME/data/library/$OWNER" 2> /dev/null || true
  fi
  chmod +x "$NODE_HOME/bin/tinycloud"
  if cp "$SRC/setup-node.sh" "$NODE_HOME/setup-node.sh.new" 2> /dev/null; then
    chmod 755 "$NODE_HOME/setup-node.sh.new"
    mv -f "$NODE_HOME/setup-node.sh.new" "$NODE_HOME/setup-node.sh"
  fi
}

backup_node() {
  tar -C "$NODE_HOME" --exclude=./data --exclude=./tinycloud.conf -cf "$PREV_TAR" .
}

restore_node() {
  [ -s "$PREV_TAR" ] || return 1
  tar -C "$NODE_HOME" -xf "$PREV_TAR" || return 1
  docker compose --project-directory "$NODE_HOME" up -d --build
}

node_healthy() {
  nh_running=$(docker compose --project-directory "$NODE_HOME" ps --status running --services 2> /dev/null)
  for nh_name in syncthing agent web; do
    printf '%s\n' "$nh_running" | grep -qx "$nh_name" || return 1
  done
}

update_main() {
  ensure_root "$@" || return 1
  if [ ! -f "$NODE_HOME/tinycloud.conf" ]; then
    fail "no node is set up in $NODE_HOME"
    return 1
  fi
  find_tree || return 1
  load_lib
  say "Updating TinyCloud from $TC_REF"
  backup_node || { fail "could not back up the current version"; return 1; }
  install_files || { restore_node; fail "could not install the new version"; return 1; }
  docker compose --project-directory "$NODE_HOME" pull --ignore-buildable > /dev/null 2>&1 || say "Could not check for newer container images."
  if ! docker compose --project-directory "$NODE_HOME" up -d --build; then
    say "The new version did not start. Going back to the previous one."
    restore_node
    fail "update failed, previous version restored"
    return 1
  fi
  sleep "${SETUP_HEALTH_WAIT:-45}"
  if ! node_healthy; then
    say "The new version is not healthy. Going back to the previous one."
    restore_node
    fail "update failed, previous version restored"
    return 1
  fi
  sh "$NODE_HOME/harden/host-status.sh" 2> /dev/null
  say "Update done."
}

write_config() {
  if [ "$KEEP_CONFIG" = true ]; then
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    say "+ write $NODE_HOME/tinycloud.conf"
    return 0
  fi
  wc_tmp=$NODE_HOME/tinycloud.conf.tmp
  (
    umask 077
    {
      printf 'NODE_NAME=%s\n' "$NODE_NAME"
      printf 'OWNER=%s\n' "$OWNER"
      printf 'ROLE=%s\n' "$ROLE"
      printf 'TIMEZONE=%s\n' "$TZ_NAME"
      printf 'GATEWAY_HOST=%s\n' "$G_HOST"
      printf 'GATEWAY_ID=%s\n' "$G_ID"
      printf 'RELAY_ID=%s\n' "$R_ID"
      printf 'DISCOVERY_ID=%s\n' "$D_ID"
      printf 'RELAY_TOKEN=%s\n' "$G_TOKEN"
    } > "$wc_tmp"
  ) || return 1
  chown 1000:1000 "$wc_tmp" 2> /dev/null || true
  mv "$wc_tmp" "$NODE_HOME/tinycloud.conf"
}

link_command() {
  if [ "$DRY_RUN" = true ]; then
    say "+ ln -sfn $NODE_HOME/bin/tinycloud ${SETUP_BIN_DIR:-/usr/local/bin}/tinycloud"
    return 0
  fi
  mkdir -p "${SETUP_BIN_DIR:-/usr/local/bin}"
  ln -sfn "$NODE_HOME/bin/tinycloud" "${SETUP_BIN_DIR:-/usr/local/bin}/tinycloud"
}

user_home() {
  if [ -n "${SETUP_USER_HOME:-}" ]; then
    printf '%s' "$SETUP_USER_HOME"
    return 0
  fi
  getent passwd "$1" 2> /dev/null | cut -d : -f 6
}

first_normal_user() {
  getent passwd 2> /dev/null | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ {print $1; exit}'
}

setup_user() {
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    TARGET_USER=$(first_normal_user)
  fi
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    return 0
  fi
  su_home=$(user_home "$TARGET_USER")
  if [ "$DRY_RUN" = true ]; then
    say "+ add $TARGET_USER to the docker group"
    say "+ link $su_home/tinycloud to the library"
    return 0
  fi
  if command -v usermod > /dev/null 2>&1 && getent group docker > /dev/null 2>&1; then
    usermod -aG docker "$TARGET_USER" 2> /dev/null || say "Could not add $TARGET_USER to the docker group."
  fi
  if [ -d "$su_home" ] && [ ! -e "$su_home/tinycloud" ] && [ ! -L "$su_home/tinycloud" ]; then
    ln -s "$NODE_HOME/data/library" "$su_home/tinycloud"
    chown -h "$TARGET_USER" "$su_home/tinycloud" 2> /dev/null || true
  fi
}

start_node() {
  if [ "$DRY_RUN" = true ]; then
    say "+ docker compose up -d --build"
    return 0
  fi
  docker compose --project-directory "$NODE_HOME" up -d --build || { fail "could not start the node"; return 1; }
}

wait_join() {
  wj_try=0
  while [ "$wj_try" -lt "${SETUP_WAIT_TRIES:-30}" ]; do
    wj_out=$("$NODE_HOME/bin/tinycloud" join 2> /dev/null) || wj_out=
    case $wj_out in
      *"tinycloud-gw approve"*)
        printf '%s\n' "$wj_out"
        return 0
        ;;
    esac
    sleep "${SETUP_WAIT_SECONDS:-5}"
    wj_try=$((wj_try + 1))
  done
  return 1
}

finish_up() {
  if [ "$DRY_RUN" = true ]; then
    say "dry run finished, nothing changed"
    return 0
  fi
  say ""
  say "The node is running. Waiting for it to get ready..."
  if ! wait_join; then
    say "It is not ready yet. In a minute, run: tinycloud join"
    say "If it stays stuck, run: tinycloud doctor"
  fi
  say ""
  say "Next: send that line to the gateway owner, who runs it on the gateway."
  if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ]; then
    say "To use tinycloud without sudo, log out and back in once."
  fi
  say "Copy files to this node from another machine with: scp file.epub ${TARGET_USER:-root}@$(hostname):tinycloud/${OWNER:-}/"
  if [ "$SMB" = yes ]; then
    say "From a PC on your network: \\\\$(hostname)\\tinycloud (Windows) or smb://$(hostname)/tinycloud (Mac)"
  fi
}

main() {
  parse_args "$@" || return 1
  if [ "$UPDATE_ONLY" = true ]; then
    update_main "$@"
    return $?
  fi
  open_input || return 1
  say "TinyCloud node setup"
  say ""
  ensure_root "$@" || return 1
  find_tree || return 1
  load_lib
  if ! detect_os || ! os_supported; then
    fail "unsupported system: ${os_id:-unknown} ${os_version:-}. Use Debian 12 or newer."
    return 1
  fi
  say "System: $os_id $os_version ($os_codename)"
  check_existing
  if [ "$KEEP_CONFIG" != true ]; then
    choose_basics || return 1
    choose_gateway || return 1
  fi
  if [ "$KEEP_CONFIG" != true ] || [ -n "$AUTO_UPDATE$FIREWALL$SSH_HARDEN$CHANNEL" ]; then
    choose_updates || return 1
    choose_hardening || return 1
  fi
  if [ "$KEEP_CONFIG" != true ] || [ -n "$SMB" ]; then
    choose_smb || return 1
  fi
  show_plan
  if ! ask_yes "Continue?" y; then
    say "cancelled"
    return 1
  fi
  install_docker || return 1
  install_files || return 1
  write_config || return 1
  setup_updates || return 1
  setup_host_status || return 1
  setup_firewall || return 1
  setup_ssh_hardening || return 1
  setup_smb || return 1
  if [ "$FIREWALL" != yes ] && [ -n "$SMB" ] && [ -f "$HARDEN_FW_FILE" ]; then
    FIREWALL=yes
    setup_firewall || return 1
  fi
  setup_autoupdate || return 1
  link_command || return 1
  setup_user
  start_node || return 1
  finish_up
}

if [ "${SETUP_NO_MAIN:-}" != 1 ]; then
  main "$@"
  exit $?
fi
