#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
SETUP_NO_MAIN=1
SETUP_SELF_DIR=$REPO
export SETUP_NO_MAIN SETUP_SELF_DIR
. "$REPO/setup-node.sh"
SRC=$REPO
load_lib
set +e

HARDEN_FW_FILE=$SANDBOX/etc/firewall.nft
HARDEN_UNIT_DIR=$SANDBOX/units
HARDEN_SSH_DIR=$SANDBOX/ssh
HARDEN_F2B_DIR=$SANDBOX/f2b
SETUP_USER_HOME=$SANDBOX/home
mkdir -p "$SANDBOX/home/.ssh"
TARGET_USER=tester
DRY_RUN=false
LOG=$SANDBOX/log
: > "$LOG"

dpkg() { return 0; }
systemctl() { echo "systemctl $*" >> "$LOG"; return 0; }
nft() { echo "nft $*" >> "$LOG"; return "${NFT_RC:-0}"; }
sshd() { echo "sshd $*" >> "$LOG"; return "${SSHD_RC:-0}"; }

assert_eq "default ssh port" 22 "$(TC_SSH_PORT='' ssh_port)"
assert_eq "custom ssh port" 2222 "$(TC_SSH_PORT=2222 ssh_port)"
assert_eq "junk port falls back" 22 "$(TC_SSH_PORT=abc ssh_port)"

fw=$(render_node_firewall 2222)
assert_contains "fw drops by default" "$fw" "policy drop"
assert_contains "fw allows the ssh port from the lan" "$fw" "ip saddr @lan4 tcp dport 2222 accept"
assert_contains "fw allows established" "$fw" "ct state established,related accept"
assert_contains "fw guards published ports" "$fw" "ct status dnat ip saddr != @lan4 drop"
assert_contains "fw lan covers private ranges" "$fw" "192.168.0.0/16"
assert_contains "unit loads the rules" "$(render_firewall_unit)" "ExecStart=/usr/sbin/nft -f $HARDEN_FW_FILE"
assert_contains "unit starts before the network" "$(render_firewall_unit)" "Before=network-pre.target"

if command -v nft > /dev/null 2>&1 && /usr/sbin/nft --version > /dev/null 2>&1; then
  render_node_firewall 22 > "$SANDBOX/real.nft"
  assert_eq "real nft accepts the rules" 0 "$(/usr/sbin/nft -c -f "$SANDBOX/real.nft" > /dev/null 2>&1; echo $?)"
fi

assert_contains "ssh with keys" "$(render_node_ssh keys)" "PasswordAuthentication no"
assert_not_contains "ssh without keys keeps passwords" "$(render_node_ssh password)" "PasswordAuthentication no"
assert_contains "root never by password" "$(render_node_ssh keys)" "PermitRootLogin prohibit-password"
assert_contains "fail2ban port" "$(render_node_fail2ban 2222)" "port = 2222"
assert_contains "fail2ban uses journal" "$(render_node_fail2ban 22)" "backend = systemd"

FIREWALL=no
setup_firewall
assert_eq "firewall off writes nothing" 0 "$([ -e "$HARDEN_FW_FILE" ] && echo 1 || echo 0)"
FIREWALL=yes
TC_SSH_PORT=22
export TC_SSH_PORT
setup_firewall
assert_eq "rules written" 1 "$([ -s "$HARDEN_FW_FILE" ] && echo 1 || echo 0)"
assert_eq "unit written" 1 "$([ -s "$HARDEN_UNIT_DIR/tinycloud-firewall.service" ] && echo 1 || echo 0)"
assert_contains "rules checked before use" "$(cat "$LOG")" "nft -c -f $HARDEN_FW_FILE"
assert_contains "firewall enabled and started" "$(cat "$LOG")" "systemctl restart tinycloud-firewall"
rm -f "$HARDEN_FW_FILE"
NFT_RC=1
setup_firewall > "$SANDBOX/out" 2>&1
assert_eq "bad rules refused" 1 "$?"
assert_eq "bad rules removed" 0 "$([ -e "$HARDEN_FW_FILE" ] && echo 1 || echo 0)"
NFT_RC=0

SSH_HARDEN=no
setup_ssh_hardening
assert_eq "ssh off writes nothing" 0 "$([ -e "$HARDEN_SSH_DIR" ] && echo 1 || echo 0)"
SSH_HARDEN=yes
setup_ssh_hardening > "$SANDBOX/out" 2>&1
assert_contains "no key keeps passwords" "$(cat "$SANDBOX/out")" "password login stays on"
assert_not_contains "no key no password ban" "$(cat "$HARDEN_SSH_DIR/00-tinycloud.conf")" "PasswordAuthentication no"
assert_eq "fail2ban jail written" 1 "$([ -s "$HARDEN_F2B_DIR/tinycloud.local" ] && echo 1 || echo 0)"
printf 'ssh-ed25519 AAAAC3Nza test\n' > "$SANDBOX/home/.ssh/authorized_keys"
setup_ssh_hardening > "$SANDBOX/out" 2>&1
assert_contains "key present turns passwords off" "$(cat "$HARDEN_SSH_DIR/00-tinycloud.conf")" "PasswordAuthentication no"
assert_contains "sshd checked" "$(cat "$LOG")" "sshd -t"
SSHD_RC=1
rm -f "$HARDEN_SSH_DIR/00-tinycloud.conf"
setup_ssh_hardening > "$SANDBOX/out" 2>&1
assert_eq "bad ssh config refused" 0 "$([ -e "$HARDEN_SSH_DIR/00-tinycloud.conf" ] && echo 1 || echo 0)"
SSHD_RC=0

DRY_RUN=true
rm -rf "$SANDBOX/units" "$HARDEN_SSH_DIR" "$HARDEN_F2B_DIR" "$HARDEN_FW_FILE"
out=$(setup_firewall; setup_ssh_hardening)
assert_contains "dry run plans the firewall" "$out" "+ write $HARDEN_FW_FILE"
assert_contains "dry run plans ssh" "$out" "+ write $HARDEN_SSH_DIR/00-tinycloud.conf (keys)"
assert_eq "dry run writes no rules" 0 "$([ -e "$HARDEN_FW_FILE" ] && echo 1 || echo 0)"

HS=$REPO/node/harden/host-status.sh
HSDIR=$SANDBOX/hostdir
now_h=$(date +%s)
printf '200000.00 1.00\n' > "$SANDBOX/up"
run_hs() { TC_HOST_DIR=$HSDIR TC_REBOOT_FLAG_SRC=$SANDBOX/flag TC_UPTIME_FILE=$SANDBOX/up sh "$HS"; }
rm -f "$SANDBOX/flag"
run_hs
assert_eq "no flag means no file" 0 "$([ -e "$HSDIR/reboot_required" ] && echo 1 || echo 0)"
: > "$SANDBOX/flag"
run_hs
first=$(cat "$HSDIR/reboot_required")
assert_eq "flag writes the time" 1 "$(printf '%s' "$first" | grep -Ec '^[0-9]{10}$')"
sleep 1
run_hs
assert_eq "pending reboot keeps its first time" "$first" "$(cat "$HSDIR/reboot_required")"
printf '%s\n' $((now_h - 400000)) > "$HSDIR/reboot_required"
run_hs
assert_eq "stale time from before the last boot is replaced" 1 "$([ "$(cat "$HSDIR/reboot_required")" -gt $((now_h - 200000)) ] && echo 1 || echo 0)"
rm -f "$SANDBOX/flag"
run_hs
assert_eq "cleared flag removes the file" 0 "$([ -e "$HSDIR/reboot_required" ] && echo 1 || echo 0)"

HARDEN_APT_DIR=$SANDBOX/apt
NODE_HOME=$SANDBOX/nh
mkdir -p "$NODE_HOME/harden"
cp "$HS" "$NODE_HOME/harden/host-status.sh"
DRY_RUN=false
setup_host_status
assert_contains "apt hook written" "$(cat "$HARDEN_APT_DIR/53tinycloud-host-status")" "DPkg::Post-Invoke"
assert_contains "apt hook runs the script" "$(cat "$HARDEN_APT_DIR/53tinycloud-host-status")" "$NODE_HOME/harden/host-status.sh"
assert_eq "host folder made" 1 "$([ -d "$NODE_HOME/host" ] && echo 1 || echo 0)"
DRY_RUN=true
rm -rf "$HARDEN_APT_DIR"
assert_contains "dry run plans the hook" "$(setup_host_status)" "+ write $HARDEN_APT_DIR/53tinycloud-host-status"
assert_eq "dry run writes no hook" 0 "$([ -e "$HARDEN_APT_DIR" ] && echo 1 || echo 0)"

finish
