#!/bin/sh
set -eu
GW_DIR=${GW_DIR:-$(cd "$(dirname "$0")" && pwd)}
. "$GW_DIR/lib.sh"

DRY_RUN=false
HOST=
SSH_PORT=22
AUTO_REBOOT=no
REBOOT_TIME=04:00
TIMEZONE=

usage() {
  echo "usage: sudo sh gateway.sh --host HOSTNAME [--ssh-port N] [--auto-reboot yes|no] [--reboot-time TIME] [--timezone NAME] [--dry-run]"
}

run() {
  if [ "$DRY_RUN" = true ]; then
    printf '+ %s\n' "$*"
    return 0
  fi
  "$@"
}

put_file() {
  pf_path=$1
  pf_mode=$2
  pf_content=$(cat)
  if [ "$DRY_RUN" = true ]; then
    printf '+ write %s (%s)\n' "$pf_path" "$pf_mode"
    return 0
  fi
  mkdir -p "$(dirname "$pf_path")"
  (umask 077 && printf '%s\n' "$pf_content" > "$pf_path.tmp")
  chmod "$pf_mode" "$pf_path.tmp"
  mv "$pf_path.tmp" "$pf_path"
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
      --timezone)
        [ $# -ge 2 ] || { usage; return 1; }
        TIMEZONE=$2
        shift 2
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
  if ! valid_host "$HOST"; then
    log ERROR "--host is missing or invalid"
    usage
    return 1
  fi
  if ! valid_port "$SSH_PORT"; then
    log ERROR "--ssh-port is invalid"
    return 1
  fi
  case $AUTO_REBOOT in
    yes | no) ;;
    *)
      log ERROR "--auto-reboot must be yes or no"
      return 1
      ;;
  esac
  if ! valid_reboot_time "$REBOOT_TIME"; then
    log ERROR "--reboot-time is invalid"
    return 1
  fi
  REBOOT_TIME=$(time_24h "$REBOOT_TIME")
  if [ -n "$TIMEZONE" ] && ! valid_timezone "$TIMEZONE"; then
    log ERROR "--timezone is invalid, use a name like America/Phoenix"
    return 1
  fi
}

check_os() {
  if ! detect_os; then
    log ERROR "cannot read $GW_OS_RELEASE"
    return 1
  fi
  if ! os_supported; then
    log ERROR "unsupported system: $os_id $os_version (need Debian 12 or newer, or Ubuntu 22.04 or newer)"
    return 1
  fi
  log INFO "system: $os_id $os_version ($os_codename)"
}

check_root() {
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    log ERROR "run as root"
    return 1
  fi
}

render_docker_sources() {
  printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$os_id" "$os_codename"
}

render_unattended() {
  printf 'Unattended-Upgrade::Origins-Pattern {\n'
  if [ "$os_id" = ubuntu ]; then
    printf '  "origin=Ubuntu,archive=%s-security";\n' "$os_codename"
  else
    printf '  "origin=Debian,codename=%s-security,label=Debian-Security";\n' "$os_codename"
  fi
  printf '  "origin=Docker";\n};\n'
  if [ "$AUTO_REBOOT" = yes ]; then
    printf 'Unattended-Upgrade::Automatic-Reboot "true";\n'
    printf 'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";\n'
    printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$REBOOT_TIME"
  else
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
  fi
}

render_periodic() {
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n'
}

render_ssh() {
  cat <<'EOT'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
EOT
}

render_fail2ban() {
  printf '[sshd]\nenabled = true\nbackend = systemd\nport = %s\nmaxretry = 4\nfindtime = 10m\nbantime = 1h\n' "$SSH_PORT"
}

render_firewall() {
  sed "s/SSH_PORT/$SSH_PORT/" "$GW_DIR/firewall.nft"
}

render_aggregate_service() {
  printf '[Unit]\nDescription=TinyCloud status views\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/tinycloud-gw aggregate\n'
}

render_aggregate_timer() {
  printf '[Unit]\nDescription=TinyCloud status views every 5 minutes\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\n\n[Install]\nWantedBy=timers.target\n'
}

render_env() {
  printf 'GATEWAY_HOST=%s\nRELAY_TOKEN=%s\n' "$HOST" "$1"
}

setup_aggregate() {
  render_aggregate_service | put_file /etc/systemd/system/tinycloud-aggregate.service 644
  render_aggregate_timer | put_file /etc/systemd/system/tinycloud-aggregate.timer 644
  run systemctl daemon-reload
  run systemctl enable --now tinycloud-aggregate.timer
}

install_packages() {
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg jq nftables fail2ban python3-systemd unattended-upgrades openssl
}

install_docker() {
  run install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL "https://download.docker.com/linux/$os_id/gpg" -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc
  render_docker_sources | put_file /etc/apt/sources.list.d/docker.sources 644
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  run systemctl enable --now docker
}

setup_timezone() {
  if [ -z "$TIMEZONE" ] || [ "$TIMEZONE" = "$(current_timezone)" ]; then
    return 0
  fi
  run timedatectl set-timezone "$TIMEZONE"
}

setup_upgrades() {
  render_unattended | put_file /etc/apt/apt.conf.d/52tinycloud-unattended 644
  render_periodic | put_file /etc/apt/apt.conf.d/20auto-upgrades 644
}

setup_ssh() {
  if [ "$DRY_RUN" != true ] && ! has_ssh_key; then
    log WARN "no ssh key found, ssh settings left as they are. add a key, then run this again"
    return 0
  fi
  render_ssh | put_file /etc/ssh/sshd_config.d/00-tinycloud.conf 644
  run sshd -t
  run systemctl reload ssh
}

setup_fail2ban() {
  render_fail2ban | put_file /etc/fail2ban/jail.d/tinycloud.local 644
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
}

setup_firewall() {
  if [ "$DRY_RUN" = true ]; then
    printf '+ nft -c -f firewall (ssh port %s)\n' "$SSH_PORT"
  else
    sf_tmp=$(mktemp)
    render_firewall > "$sf_tmp"
    nft -c -f "$sf_tmp"
    rm -f "$sf_tmp"
  fi
  if [ -f /etc/nftables.conf ] && [ ! -f /etc/nftables.conf.tinycloud-backup ]; then
    run cp /etc/nftables.conf /etc/nftables.conf.tinycloud-backup
  fi
  { printf '#!/usr/sbin/nft -f\n'; render_firewall; } | put_file /etc/nftables.conf 644
  run nft -f /etc/nftables.conf
  run systemctl enable nftables
}

existing_token() {
  sed -n 's/^RELAY_TOKEN=//p' "$GW_HOME/.env" 2> /dev/null | tail -n 1
}

install_stack() {
  is_token=$(existing_token)
  if ! valid_token "$is_token"; then
    is_token=$(gen_token)
  fi
  run mkdir -p "$GW_HOME/data/syncthing" "$GW_HOME/data/relay" "$GW_HOME/data/disco"
  run chown -R 1000:1000 "$GW_HOME/data"
  run mkdir -p "$GW_HOME/state"
  run cp "$GW_DIR/docker-compose.yml" "$GW_DIR/lib.sh" "$GW_DIR/alerts.sh" "$GW_DIR/VERSION" "$GW_HOME/"
  run cp "$GW_DIR/bin/tinycloud-gw" "$GW_HOME/tinycloud-gw"
  run chmod 755 "$GW_HOME/tinycloud-gw"
  run ln -sf "$GW_HOME/tinycloud-gw" /usr/local/bin/tinycloud-gw
  render_env "$is_token" | put_file "$GW_HOME/.env" 600
  run docker compose -f "$GW_HOME/docker-compose.yml" --project-directory "$GW_HOME" up -d
}

configure_syncthing() {
  if [ "$DRY_RUN" = true ]; then
    echo "+ configure syncthing options and read ids"
    return 0
  fi
  st_wait 90
  cs_options='{"globalAnnounceEnabled":false,"localAnnounceEnabled":false,"relaysEnabled":false,"natEnabled":false,"urAccepted":-1,"crashReportingEnabled":false,"startBrowser":false,"autoUpgradeIntervalH":0,"listenAddresses":["tcp://0.0.0.0:22000"],"stunServers":[]}'
  st_api PATCH /rest/config/options "$cs_options" > /dev/null
  gateway_id=$(st_api GET /rest/system/status | jq -r '.myID')
  if ! valid_device_id "$gateway_id"; then
    log ERROR "could not read the gateway id"
    return 1
  fi
  cs_n=0
  relay_id=
  disc_id=
  while [ "$cs_n" -lt 30 ]; do
    relay_id=$(find_id "$(docker compose -f "$GW_HOME/docker-compose.yml" --project-directory "$GW_HOME" logs relay 2> /dev/null)")
    disc_id=$(find_id "$(docker compose -f "$GW_HOME/docker-compose.yml" --project-directory "$GW_HOME" logs discovery 2> /dev/null)")
    if [ -n "$relay_id" ] && [ -n "$disc_id" ]; then
      break
    fi
    cs_n=$((cs_n + 1))
    sleep 2
  done
  if [ -z "$relay_id" ] || [ -z "$disc_id" ]; then
    log ERROR "could not read relay or discovery id from logs"
    return 1
  fi
}

print_summary() {
  if [ "$DRY_RUN" = true ]; then
    echo "dry run finished, nothing changed"
    return 0
  fi
  token=$(existing_token)
  ps_lines=$(printf 'GATEWAY_HOST=%s\nGATEWAY_ID=%s\nRELAY_ID=%s\nDISCOVERY_ID=%s\nRELAY_TOKEN=%s' "$HOST" "$gateway_id" "$relay_id" "$disc_id" "$token")
  printf '%s\n' "$ps_lines" | put_file "$GW_HOME/node-lines.txt" 600
  printf '\nCopy these into each node tinycloud.conf:\n\n%s\n\n' "$ps_lines"
  printf 'They are saved in %s/node-lines.txt. Show them again with: tinycloud-gw config\n' "$GW_HOME"
  printf 'The relay token is secret.\n'
}

main() {
  parse_args "$@"
  check_os
  check_root
  install_packages
  install_docker
  setup_timezone
  setup_upgrades
  setup_ssh
  setup_fail2ban
  setup_firewall
  install_stack
  configure_syncthing
  setup_aggregate
  print_summary
}

if [ "${GW_NO_MAIN:-}" != 1 ]; then
  main "$@"
fi
