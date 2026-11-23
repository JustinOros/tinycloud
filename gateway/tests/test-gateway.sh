#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(cd "$HERE/.." && pwd)
. "$HERE/harness.sh"

dry() {
  GW_OS_RELEASE=$HERE/fixtures/$1 sh "$GW/gateway.sh" --dry-run --host gw.example.com 2>&1
}

out=$(dry debian12)
assert_contains "debian dry run ends" "$out" "dry run finished, nothing changed"
assert_contains "debian docker key" "$out" "download.docker.com/linux/debian/gpg"
assert_contains "debian ssh dropin first" "$out" "/etc/ssh/sshd_config.d/00-tinycloud.conf"
assert_contains "debian firewall file" "$out" "write /etc/nftables.conf"
assert_contains "debian stack up" "$out" "docker compose"
assert_contains "debian installs admin command" "$out" "/usr/local/bin/tinycloud-gw"

out=$(dry ubuntu2404)
assert_contains "ubuntu dry run ends" "$out" "dry run finished, nothing changed"
assert_contains "ubuntu docker key" "$out" "download.docker.com/linux/ubuntu/gpg"

out=$(dry fedora || true)
assert_contains "fedora refused" "$out" "unsupported system"
out=$(dry debian11 || true)
assert_contains "debian 11 refused" "$out" "unsupported system"

out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run 2>&1 || true)
assert_contains "host required" "$out" "--host is missing or invalid"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host gw.example.com --auto-reboot yes --reboot-time 9pm 2>&1 || true)
assert_contains "reboot flags accepted" "$out" "dry run finished, nothing changed"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host gw.example.com --timezone Pacific/Honolulu 2>&1 || true)
assert_contains "time zone is set" "$out" "timedatectl set-timezone Pacific/Honolulu"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host gw.example.com --timezone Nope/Zone 2>&1 || true)
assert_contains "bad time zone refused" "$out" "--timezone is invalid"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host gw.example.com 2>&1 || true)
assert_not_contains "no time zone change by default" "$out" "set-timezone"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host gw.example.com --auto-reboot maybe 2>&1 || true)
assert_contains "bad auto reboot refused" "$out" "--auto-reboot must be yes or no"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host gw.example.com --reboot-time 99:99 2>&1 || true)
assert_contains "bad reboot time refused" "$out" "--reboot-time is invalid"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host 'a/b' 2>&1 || true)
assert_contains "bad host refused" "$out" "--host is missing or invalid"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --dry-run --host gw.example.com --ssh-port 99999 2>&1 || true)
assert_contains "bad ssh port refused" "$out" "--ssh-port is invalid"
out=$(GW_OS_RELEASE=$HERE/fixtures/debian12 sh "$GW/gateway.sh" --bogus 2>&1 || true)
assert_contains "unknown flag usage" "$out" "usage:"

GW_NO_MAIN=1
GW_DIR=$GW
export GW_NO_MAIN GW_DIR
. "$GW/gateway.sh"
HOST=gw.example.com
SSH_PORT=2222

GW_OS_RELEASE=$HERE/fixtures/debian12
detect_os
assert_contains "debian docker sources" "$(render_docker_sources)" "URIs: https://download.docker.com/linux/debian"
assert_contains "debian docker suite" "$(render_docker_sources)" "Suites: bookworm"
assert_contains "debian security origin" "$(render_unattended)" "origin=Debian,codename=bookworm-security,label=Debian-Security"
assert_contains "docker origin" "$(render_unattended)" "origin=Docker"
assert_contains "no auto reboot" "$(render_unattended)" 'Automatic-Reboot "false"'
AUTO_REBOOT=yes
REBOOT_TIME=04:00
assert_contains "reboot on" "$(render_unattended)" 'Automatic-Reboot "true"'
assert_contains "reboot time set" "$(render_unattended)" 'Automatic-Reboot-Time "04:00"'
assert_contains "reboot with users" "$(render_unattended)" 'Automatic-Reboot-WithUsers "true"'
AUTO_REBOOT=no

GW_OS_RELEASE=$HERE/fixtures/ubuntu2404
detect_os
assert_contains "ubuntu docker sources" "$(render_docker_sources)" "URIs: https://download.docker.com/linux/ubuntu"
assert_contains "ubuntu docker suite" "$(render_docker_sources)" "Suites: noble"
assert_contains "ubuntu security origin" "$(render_unattended)" "origin=Ubuntu,archive=noble-security"

assert_contains "ssh no passwords" "$(render_ssh)" "PasswordAuthentication no"
assert_contains "ssh no kbd" "$(render_ssh)" "KbdInteractiveAuthentication no"
assert_contains "fail2ban port" "$(render_fail2ban)" "port = 2222"
assert_contains "firewall ssh port" "$(render_firewall)" "tcp dport 2222 accept"
assert_contains "firewall gateway ports" "$(render_firewall)" "tcp dport { 22000, 22067, 8443 } accept"
assert_not_contains "firewall placeholder gone" "$(render_firewall)" "SSH_PORT"
assert_contains "env host" "$(render_env tok123)" "GATEWAY_HOST=gw.example.com"
assert_contains "env token" "$(render_env tok123)" "RELAY_TOKEN=tok123"

sandbox=$(mktemp -d)
GW_ROOT_HOME=$sandbox
SUDO_USER=
assert_eq "no key found" 1 "$(has_ssh_key && echo 0 || echo 1)"
mkdir -p "$sandbox/.ssh"
: > "$sandbox/.ssh/authorized_keys"
assert_eq "empty key file" 1 "$(has_ssh_key && echo 0 || echo 1)"
echo "ssh-ed25519 AAAA test" > "$sandbox/.ssh/authorized_keys"
assert_eq "key found" 0 "$(has_ssh_key && echo 0 || echo 1)"

GW_HOME=$sandbox/gw
mkdir -p "$GW_HOME"
printf 'GATEWAY_HOST=x\nRELAY_TOKEN=keepme123\n' > "$GW_HOME/.env"
assert_eq "existing token read" keepme123 "$(existing_token)"

DRY_RUN=false
out_file=$sandbox/out/file.conf
printf 'hello\n' | put_file "$out_file" 600
assert_eq "put_file content" hello "$(cat "$out_file")"
assert_eq "put_file mode" 600 "$(stat -c %a "$out_file" 2> /dev/null || stat -f %Lp "$out_file")"
leftover=0
for f in "$sandbox"/out/*.tmp; do
  [ -e "$f" ] && leftover=1
done
assert_eq "no tmp left" 0 "$leftover"

DRY_RUN=false
GW_HOME=$sandbox/summary
mkdir -p "$GW_HOME"
printf 'GATEWAY_HOST=x\nRELAY_TOKEN=tok999\n' > "$GW_HOME/.env"
HOST=gw.example.com
gateway_id=$(mkid A)
relay_id=$(mkid B)
disc_id=$(mkid C)
token_new=yes
summary=$(print_summary)
assert_contains "summary shows a new relay token" "$summary" "RELAY_TOKEN=tok999"
token_new=
summary=$(print_summary)
assert_not_contains "summary hides an existing relay token" "$summary" "tok999"
assert_contains "summary points to config for the token" "$summary" "RELAY_TOKEN=(hidden"
assert_contains "summary mentions config command" "$summary" "tinycloud-gw config"
saved=$(cat "$GW_HOME/node-lines.txt")
assert_contains "lines saved host" "$saved" "GATEWAY_HOST=gw.example.com"
assert_contains "lines saved discovery" "$saved" "DISCOVERY_ID=$(mkid C)"
assert_contains "lines saved token" "$saved" "RELAY_TOKEN=tok999"
assert_eq "lines file private" 600 "$(stat -c %a "$GW_HOME/node-lines.txt" 2> /dev/null || stat -f %Lp "$GW_HOME/node-lines.txt")"

assert_contains "aggregate service runs the command" "$(render_aggregate_service)" "ExecStart=/usr/local/bin/tinycloud-gw aggregate"
assert_contains "aggregate service is oneshot" "$(render_aggregate_service)" "Type=oneshot"
assert_contains "aggregate timer every 5 minutes" "$(render_aggregate_timer)" "OnUnitActiveSec=5min"
assert_contains "aggregate timer installs" "$(render_aggregate_timer)" "WantedBy=timers.target"
DRY_RUN=true
agg=$(setup_aggregate)
assert_contains "aggregate service file planned" "$agg" "write /etc/systemd/system/tinycloud-aggregate.service"
assert_contains "aggregate timer file planned" "$agg" "write /etc/systemd/system/tinycloud-aggregate.timer"
assert_contains "aggregate timer enabled" "$agg" "systemctl enable --now tinycloud-aggregate.timer"

finish
