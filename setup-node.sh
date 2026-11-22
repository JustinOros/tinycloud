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
  say "usage: sh setup-node.sh [--name NAME] [--owner OWNER] [--role ROLE] [--timezone TZ] [--config FILE] [--yes] [--dry-run]"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --name | --owner | --role | --timezone | --config)
        [ $# -ge 2 ] || { usage; return 1; }
        case $1 in
          --name) NODE_NAME=$2 ;;
          --owner) OWNER=$2 ;;
          --role) ROLE=$2 ;;
          --timezone) TZ_NAME=$2 ;;
          --config) CONFIG_FILE=$2 ;;
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
      *)
        usage
        return 1
        ;;
    esac
  done
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
  mkdir -p "$NODE_HOME/data/library"
  chown 1000:1000 "$NODE_HOME/data/library" 2> /dev/null || true
  chmod +x "$NODE_HOME/bin/tinycloud"
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

setup_user() {
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
  say "Copy files to this node from another machine with: scp file.epub $TARGET_USER@$(hostname):tinycloud/"
}

main() {
  parse_args "$@" || return 1
  open_input || return 1
  say "TinyCloud node setup"
  say ""
  ensure_root "$@" || return 1
  find_tree || return 1
  load_lib
  if ! detect_os || ! os_supported; then
    fail "unsupported system: ${os_id:-unknown} ${os_version:-}. Use Debian 12 or newer, or Ubuntu 22.04 or newer."
    return 1
  fi
  say "System: $os_id $os_version ($os_codename)"
  check_existing
  if [ "$KEEP_CONFIG" != true ]; then
    choose_basics || return 1
    choose_gateway || return 1
  fi
  show_plan
  if ! ask_yes "Continue?" y; then
    say "cancelled"
    return 1
  fi
  install_docker || return 1
  install_files || return 1
  write_config || return 1
  link_command || return 1
  setup_user
  start_node || return 1
  finish_up
}

if [ "${SETUP_NO_MAIN:-}" != 1 ]; then
  main "$@"
  exit $?
fi
