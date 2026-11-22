#!/bin/sh
HARDEN_FW_FILE=${HARDEN_FW_FILE:-/etc/tinycloud/firewall.nft}
HARDEN_UNIT_DIR=${HARDEN_UNIT_DIR:-/etc/systemd/system}
HARDEN_SSH_DIR=${HARDEN_SSH_DIR:-/etc/ssh/sshd_config.d}
HARDEN_F2B_DIR=${HARDEN_F2B_DIR:-/etc/fail2ban/jail.d}
HARDEN_APT_DIR=${HARDEN_APT_DIR:-/etc/apt/apt.conf.d}

ssh_port() {
  sp_port=${TC_SSH_PORT:-$(sshd -T 2> /dev/null | sed -n 's/^port //p' | head -n 1)}
  case $sp_port in
    '' | *[!0-9]*) sp_port=22 ;;
  esac
  printf '%s' "$sp_port"
}

render_node_firewall() {
  rnf_port=$1
  printf 'add table inet tinycloud_fw\n'
  printf 'delete table inet tinycloud_fw\n'
  printf 'table inet tinycloud_fw {\n'
  printf '  set lan4 {\n    type ipv4_addr\n    flags interval\n'
  printf '    elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 }\n  }\n'
  printf '  set lan6 {\n    type ipv6_addr\n    flags interval\n'
  printf '    elements = { fc00::/7, fe80::/10 }\n  }\n'
  printf '  chain input {\n    type filter hook input priority 0; policy drop;\n'
  printf '    iif "lo" accept\n'
  printf '    ct state established,related accept\n'
  printf '    ct state invalid drop\n'
  printf '    ip protocol icmp accept\n'
  printf '    ip6 nexthdr icmpv6 accept\n'
  printf '    udp dport 68 accept\n'
  printf '    udp dport 546 accept\n'
  printf '    ip saddr @lan4 tcp dport %s accept\n' "$rnf_port"
  printf '    ip6 saddr @lan6 tcp dport %s accept\n' "$rnf_port"
  printf '    ip saddr @lan4 udp dport 5353 accept\n'
  printf '    ip6 saddr @lan6 udp dport 5353 accept\n'
  printf '  }\n'
  printf '  chain forward {\n    type filter hook forward priority -10; policy accept;\n'
  printf '    ct status dnat ip saddr != @lan4 drop\n'
  printf '    ct status dnat ip6 saddr != @lan6 drop\n'
  printf '  }\n}\n'
}

render_firewall_unit() {
  printf '[Unit]\nDescription=TinyCloud firewall\nBefore=network-pre.target\nWants=network-pre.target\n\n'
  printf '[Service]\nType=oneshot\nRemainAfterExit=yes\n'
  printf 'ExecStart=/usr/sbin/nft -f %s\n' "$HARDEN_FW_FILE"
  printf 'ExecStop=/usr/sbin/nft delete table inet tinycloud_fw\n\n'
  printf '[Install]\nWantedBy=multi-user.target\n'
}

render_node_ssh() {
  printf 'PermitRootLogin prohibit-password\n'
  printf 'PubkeyAuthentication yes\n'
  if [ "$1" = keys ]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
  fi
  printf 'MaxAuthTries 3\nX11Forwarding no\n'
}

render_node_fail2ban() {
  printf '[sshd]\nenabled = true\nbackend = systemd\nport = %s\nmaxretry = 4\nfindtime = 10m\nbantime = 1h\n' "$1"
}

user_has_ssh_key() {
  uhk_user=${TARGET_USER:-}
  if [ -z "$uhk_user" ] || [ "$uhk_user" = root ]; then
    uhk_home=/root
  else
    uhk_home=$(user_home "$uhk_user")
  fi
  [ -n "$uhk_home" ] && [ -s "$uhk_home/.ssh/authorized_keys" ]
}

setup_firewall() {
  [ "$FIREWALL" = yes ] || return 0
  if ! ensure_package nftables; then
    say "Skipping the firewall."
    return 0
  fi
  sf_port=$(ssh_port)
  if [ "$DRY_RUN" = true ]; then
    say "+ write $HARDEN_FW_FILE (SSH $sf_port from the local network only)"
    say "+ systemctl enable --now tinycloud-firewall"
    return 0
  fi
  mkdir -p "$(dirname "$HARDEN_FW_FILE")" "$HARDEN_UNIT_DIR" || return 1
  render_node_firewall "$sf_port" > "$HARDEN_FW_FILE" || return 1
  chmod 644 "$HARDEN_FW_FILE"
  if ! nft -c -f "$HARDEN_FW_FILE"; then
    rm -f "$HARDEN_FW_FILE"
    fail "the firewall rules did not check out, so they were not applied"
    return 1
  fi
  render_firewall_unit > "$HARDEN_UNIT_DIR/tinycloud-firewall.service" || return 1
  systemctl daemon-reload
  systemctl enable tinycloud-firewall > /dev/null 2>&1
  systemctl restart tinycloud-firewall || { fail "the firewall did not start"; return 1; }
}

reload_ssh() {
  systemctl reload ssh 2> /dev/null || systemctl reload sshd 2> /dev/null
}

setup_ssh_hardening() {
  [ "$SSH_HARDEN" = yes ] || return 0
  sh_mode=password
  if user_has_ssh_key; then
    sh_mode=keys
  else
    say "No SSH key is installed for ${TARGET_USER:-root}, so password login stays on. Add a key and run setup again to turn it off."
  fi
  if [ "$DRY_RUN" = true ]; then
    say "+ write $HARDEN_SSH_DIR/00-tinycloud.conf ($sh_mode)"
    say "+ install and start fail2ban for SSH"
    return 0
  fi
  mkdir -p "$HARDEN_SSH_DIR" || return 1
  render_node_ssh "$sh_mode" > "$HARDEN_SSH_DIR/00-tinycloud.conf" || return 1
  chmod 644 "$HARDEN_SSH_DIR/00-tinycloud.conf"
  if ! sshd -t; then
    rm -f "$HARDEN_SSH_DIR/00-tinycloud.conf"
    fail "the SSH settings did not check out, so they were not applied"
    return 1
  fi
  reload_ssh
  setup_fail2ban
}

setup_fail2ban() {
  if ! ensure_package fail2ban || ! ensure_package python3-systemd; then
    say "Skipping fail2ban."
    return 0
  fi
  mkdir -p "$HARDEN_F2B_DIR" || return 1
  render_node_fail2ban "$(ssh_port)" > "$HARDEN_F2B_DIR/tinycloud.local" || return 1
  chmod 644 "$HARDEN_F2B_DIR/tinycloud.local"
  systemctl enable fail2ban > /dev/null 2>&1
  systemctl restart fail2ban
}

channel_ref() {
  case $1 in
    stable) printf 'stable' ;;
    testing) printf 'main' ;;
  esac
}

render_update_service() {
  printf '[Unit]\nDescription=TinyCloud self-update\nAfter=network-online.target docker.service\nWants=network-online.target\n\n'
  printf '[Service]\nType=oneshot\n'
  printf 'Environment=NODE_HOME=%s\nEnvironment=TC_REF=%s\n' "$NODE_HOME" "$1"
  printf 'ExecStart=/bin/sh %s/setup-node.sh --update\n' "$NODE_HOME"
}

render_update_timer() {
  printf '[Unit]\nDescription=TinyCloud nightly self-update\n\n'
  printf '[Timer]\nOnCalendar=*-*-* 04:00:00\nRandomizedDelaySec=45min\nPersistent=true\n\n'
  printf '[Install]\nWantedBy=timers.target\n'
}

setup_autoupdate() {
  case $CHANNEL in
    '') return 0 ;;
    off)
      if [ "$DRY_RUN" = true ]; then
        say "+ remove the TinyCloud self-update timer"
        return 0
      fi
      systemctl disable --now tinycloud-update.timer > /dev/null 2>&1
      rm -f "$HARDEN_UNIT_DIR/tinycloud-update.timer" "$HARDEN_UNIT_DIR/tinycloud-update.service"
      systemctl daemon-reload
      return 0
      ;;
  esac
  sa_ref=$(channel_ref "$CHANNEL")
  if [ "$DRY_RUN" = true ]; then
    say "+ write $HARDEN_UNIT_DIR/tinycloud-update.timer (channel $CHANNEL, branch $sa_ref)"
    return 0
  fi
  mkdir -p "$HARDEN_UNIT_DIR" || return 1
  render_update_service "$sa_ref" > "$HARDEN_UNIT_DIR/tinycloud-update.service" || return 1
  render_update_timer > "$HARDEN_UNIT_DIR/tinycloud-update.timer" || return 1
  systemctl daemon-reload
  systemctl enable --now tinycloud-update.timer > /dev/null 2>&1 || { fail "could not start the update timer"; return 1; }
}

setup_host_status() {
  shs_hook=$HARDEN_APT_DIR/53tinycloud-host-status
  if [ "$DRY_RUN" = true ]; then
    say "+ write $shs_hook"
    return 0
  fi
  mkdir -p "$HARDEN_APT_DIR" "$NODE_HOME/host" || return 1
  printf 'DPkg::Post-Invoke { "sh %s/harden/host-status.sh || true"; };\n' "$NODE_HOME" > "$shs_hook" || return 1
  chmod 644 "$shs_hook"
  sh "$NODE_HOME/harden/host-status.sh"
}
