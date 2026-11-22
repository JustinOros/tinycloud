#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
NODE_HOME=$SANDBOX/node
TC_PREV_TAR=$SANDBOX/prev.tar
SETUP_HEALTH_WAIT=0
SETUP_NO_MAIN=1
SETUP_SELF_DIR=$REPO
export NODE_HOME TC_PREV_TAR SETUP_HEALTH_WAIT SETUP_NO_MAIN SETUP_SELF_DIR
. "$REPO/setup-node.sh"
SRC=$REPO
load_lib
set +e

HARDEN_UNIT_DIR=$SANDBOX/units
LOG=$SANDBOX/log
: > "$LOG"
DOCKER_UP_RC=0
DOCKER_RUNNING="syncthing
agent
web"

docker() {
  echo "docker $*" >> "$LOG"
  case $* in
    *"ps --status running"*) printf '%s\n' "$DOCKER_RUNNING" ;;
    *" up "*) return "$DOCKER_UP_RC" ;;
  esac
  return 0
}
systemctl() { echo "systemctl $*" >> "$LOG"; return 0; }
ensure_root() { return 0; }
sleep() { return 0; }

reset_node() {
  rm -rf "$NODE_HOME"
  mkdir -p "$NODE_HOME/data/library" "$NODE_HOME/bin"
  printf 'OLD\n' > "$NODE_HOME/docker-compose.yml"
  printf 'NODE_NAME=adrian\n' > "$NODE_HOME/tinycloud.conf"
  printf 'keep\n' > "$NODE_HOME/data/library/book.epub"
  : > "$LOG"
  DOCKER_UP_RC=0
  DOCKER_RUNNING="syncthing
agent
web"
}

reset_node
out=$(update_main 2>&1)
assert_eq "update succeeds" 0 "$?"
assert_contains "update reports done" "$out" "Update done."
assert_eq "new files installed" 0 "$(grep -c '^OLD$' "$NODE_HOME/docker-compose.yml")"
assert_eq "config kept" "NODE_NAME=adrian" "$(cat "$NODE_HOME/tinycloud.conf")"
assert_eq "library kept" keep "$(cat "$NODE_HOME/data/library/book.epub")"
assert_eq "update script installed" 1 "$([ -x "$NODE_HOME/setup-node.sh" ] && echo 1 || echo 0)"
assert_eq "no temp script left" 0 "$([ -e "$NODE_HOME/setup-node.sh.new" ] && echo 1 || echo 0)"
assert_contains "images checked" "$(cat "$LOG")" "pull --ignore-buildable"
assert_contains "stack rebuilt" "$(cat "$LOG")" "up -d --build"

reset_node
DOCKER_RUNNING="syncthing
web"
out=$(update_main 2>&1)
assert_eq "unhealthy update fails" 1 "$?"
assert_contains "unhealthy update explained" "$out" "previous version restored"
assert_eq "old files restored" 1 "$(grep -c '^OLD$' "$NODE_HOME/docker-compose.yml")"
assert_eq "library kept after rollback" keep "$(cat "$NODE_HOME/data/library/book.epub")"
assert_eq "config kept after rollback" "NODE_NAME=adrian" "$(cat "$NODE_HOME/tinycloud.conf")"

reset_node
DOCKER_UP_RC=1
out=$(update_main 2>&1)
assert_eq "failed start fails" 1 "$?"
assert_contains "failed start explained" "$out" "did not start"
assert_eq "failed start restored" 1 "$(grep -c '^OLD$' "$NODE_HOME/docker-compose.yml")"

rm -rf "$NODE_HOME"
out=$(update_main 2>&1)
assert_eq "no node no update" 1 "$?"
assert_contains "no node explained" "$out" "no node is set up"

assert_eq "stable channel branch" stable "$(channel_ref stable)"
assert_eq "testing channel branch" main "$(channel_ref testing)"
assert_contains "service runs the update" "$(render_update_service stable)" "ExecStart=/bin/sh $NODE_HOME/setup-node.sh --update"
assert_contains "service pins the branch" "$(render_update_service stable)" "Environment=TC_REF=stable"
assert_contains "timer is nightly" "$(render_update_timer)" "OnCalendar=*-*-* 04:00:00"
assert_contains "timer catches up" "$(render_update_timer)" "Persistent=true"
if command -v systemd-analyze > /dev/null 2>&1; then
  mkdir -p "$SANDBOX/verify"
  render_update_timer > "$SANDBOX/verify/t.timer"
  assert_eq "systemd accepts the calendar" 0 "$(systemd-analyze calendar '*-*-* 04:00:00' > /dev/null 2>&1; echo $?)"
fi

DRY_RUN=false
reset_node
CHANNEL=stable
setup_autoupdate
assert_eq "timer unit written" 1 "$([ -s "$HARDEN_UNIT_DIR/tinycloud-update.timer" ] && echo 1 || echo 0)"
assert_eq "service unit written" 1 "$([ -s "$HARDEN_UNIT_DIR/tinycloud-update.service" ] && echo 1 || echo 0)"
assert_contains "timer enabled" "$(cat "$LOG")" "systemctl enable --now tinycloud-update.timer"
CHANNEL=off
setup_autoupdate
assert_eq "off removes the timer" 0 "$([ -e "$HARDEN_UNIT_DIR/tinycloud-update.timer" ] && echo 1 || echo 0)"
rm -rf "$HARDEN_UNIT_DIR"
CHANNEL=
setup_autoupdate
assert_eq "unset channel touches nothing" 0 "$([ -e "$HARDEN_UNIT_DIR" ] && echo 1 || echo 0)"

finish
