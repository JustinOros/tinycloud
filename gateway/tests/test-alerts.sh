#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(cd "$HERE/.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
GW_HOME=$SANDBOX/gw
GW_STATE=$GW_HOME/state
GW_ALLOW_NONROOT=1
GW_NO_MAIN=1
GW_LIB_DIR=$GW
export GW_HOME GW_ALLOW_NONROOT GW_NO_MAIN GW_LIB_DIR
. "$GW/bin/tinycloud-gw"

mkdir -p "$SANDBOX/fakebin"
cat > "$SANDBOX/fakebin/curl" <<EOT
#!/bin/sh
cat > "$SANDBOX/curl.stdin"
printf '%s\n' "\$*" >> "$SANDBOX/curl.args"
body=
while [ \$# -gt 0 ]; do
  case \$1 in
    --data-raw) body=\$2; shift ;;
  esac
  shift
done
printf '%s\n---\n' "\$body" >> "$SANDBOX/sent"
exit "\$(cat "$SANDBOX/curl.rc" 2> /dev/null || echo 0)"
EOT
chmod +x "$SANDBOX/fakebin/curl"
PATH=$SANDBOX/fakebin:$PATH
ALERT_REBOOT_FILE=$SANDBOX/reboot-required
export ALERT_REBOOT_FILE
st_api() { return "${ST_RC:-0}"; }

T0=$(date -u -d 2026-11-21T12:00:00Z +%s)
REPORTED=2026-11-21T11:00:00Z

reset() {
  rm -rf "$GW_HOME" "$SANDBOX/sent" "$SANDBOX/curl.rc" "$SANDBOX/curl.args"
  mkdir -p "$GW_STATE"
  : > "$SANDBOX/sent"
}

view() {
  jq -nc --arg r "$REPORTED" --argjson n "$1" '{version: 1, generated: "x", nodes: $n}' > "$GW_STATE/view.json"
}

node() {
  jq -nc --arg r "$REPORTED" --arg name "$1" --argjson online "$2" --argjson low "${3:-false}" --argjson cc "${4:-0}" --argjson rb "${5:-false}" \
    '{name: $name, role: "contributor", owner: "justin", online: $online,
      status: {version: "0.1.0", percent_stored: 100, free_bytes: 1000, low_space: $low, case_conflicts: $cc, reported: $r, booted: null, reboot_required: $rb}}'
}

tick() {
  ALERT_NOW=$1 ALERT_HOUR=${2:-3} run_alerts
}

sent_count() {
  grep -c '^---$' "$SANDBOX/sent"
}

assert_eq "minutes plain" 5 "$(alert_minutes 5)"
assert_eq "minutes m" 60 "$(alert_minutes 60m)"
assert_eq "minutes h" 120 "$(alert_minutes 2h)"
assert_eq "minutes d" 1440 "$(alert_minutes 1d)"
assert_eq "minutes upper" 120 "$(alert_minutes 2H)"
assert_eq "minutes junk" 1 "$(alert_minutes abc > /dev/null 2>&1; echo $?)"
assert_eq "minutes too big" 1 "$(alert_minutes 99999 > /dev/null 2>&1; echo $?)"
assert_eq "hour 9am" 9 "$(alert_hour 9am)"
assert_eq "hour 6:00 PM" 18 "$(alert_hour '6:00 PM')"
assert_eq "hour 12am" 0 "$(alert_hour 12am)"
assert_eq "hour 12pm" 12 "$(alert_hour 12pm)"
assert_eq "hour 24h" 13 "$(alert_hour 13)"
assert_eq "hour off" off "$(alert_hour off)"
assert_eq "hour 24 rejected" 1 "$(alert_hour 24 > /dev/null 2>&1; echo $?)"
assert_eq "hour 13pm rejected" 1 "$(alert_hour 13pm > /dev/null 2>&1; echo $?)"
assert_eq "fmt zero" "right away" "$(fmt_minutes 0)"
assert_eq "fmt one minute" "1 minute" "$(fmt_minutes 1)"
assert_eq "fmt hour" "1 hour" "$(fmt_minutes 60)"
assert_eq "fmt hours minutes" "2 hours 5 minutes" "$(fmt_minutes 125)"
assert_eq "fmt day" "1 day" "$(fmt_minutes 1440)"
assert_eq "fmt day hour" "1 day 1 hour" "$(fmt_minutes 1500)"
assert_eq "fmt hour 9pm" "9:00 PM" "$(fmt_hour 21)"
assert_eq "fmt hour midnight" "12:00 AM" "$(fmt_hour 0)"

reset
assert_contains "show off" "$(alert_show)" "Alerts are off"
assert_contains "show default offline" "$(alert_show)" "2 hours"
assert_contains "show default reminder" "$(alert_show)" "9:00 AM"
alert_set offline 5m > /dev/null
assert_eq "offline saved" 5 "$(alert_get ALERT_OFFLINE 0)"
assert_contains "show new offline" "$(alert_show)" "offline after      5 minutes"
alert_set offline 0 > /dev/null 2>&1
assert_eq "offline zero rejected" 5 "$(alert_get ALERT_OFFLINE 0)"
alert_set no-status 60m > /dev/null 2>&1
assert_eq "no-status below a day rejected" "" "$(alert_get ALERT_NOSTATUS '')"
alert_set no-status 2d > /dev/null
assert_eq "no-status saved" 2880 "$(alert_get ALERT_NOSTATUS 0)"
alert_set low-space 0 > /dev/null
assert_eq "low-space zero allowed" 0 "$(alert_get ALERT_LOWSPACE 9)"
alert_set reminder 6pm > /dev/null
assert_eq "reminder saved" 18 "$(alert_get ALERT_REMINDER 0)"
alert_set reminder off > /dev/null
assert_contains "reminder off shown" "$(alert_show)" "daily reminder     off"
alert_set recovered no > /dev/null
assert_eq "recovered saved" no "$(alert_get ALERT_RECOVERED yes)"
alert_set recovered maybe > /dev/null 2>&1
assert_eq "recovered junk rejected" no "$(alert_get ALERT_RECOVERED yes)"
alert_set url 'not a url' > /dev/null 2>&1
assert_eq "bad url rejected" "" "$(alert_get ALERT_URL '')"
alert_set url 'https://ntfy.sh/secrettopic123' > /dev/null
assert_eq "url saved" "https://ntfy.sh/secrettopic123" "$(alert_get ALERT_URL '')"
assert_eq "config is private" 600 "$(stat -c %a "$GW_HOME/alerts.conf")"
assert_contains "show host only" "$(alert_show)" "sending to ntfy.sh)"
assert_not_contains "show hides topic" "$(alert_show)" "secrettopic123"
alert_set bogus 5 > /dev/null 2>&1
assert_eq "unknown setting rejected" 1 "$(alert_set bogus 5 > /dev/null 2>&1; echo $?)"
alert_set url off > /dev/null
assert_eq "url off" "" "$(alert_get ALERT_URL '')"
assert_contains "backup includes alerts.conf" "$(backup_paths)" "alerts.conf"

reset
view "[$(node grace false)]"
tick "$T0"
assert_eq "no url sends nothing" 0 "$(sent_count)"
assert_eq "no url keeps no state" 0 "$([ -e "$GW_STATE/alerts.json" ] && echo 1 || echo 0)"

reset
alert_set url 'https://ntfy.sh/secrettopic123' > /dev/null
alert_set offline 60m > /dev/null
view "[$(node grace false)]"
tick "$T0"
assert_eq "first sighting is quiet" 0 "$(sent_count)"
tick $((T0 + 1800))
assert_eq "still under the limit" 0 "$(sent_count)"
tick $((T0 + 3600))
assert_eq "alert at the limit" 1 "$(sent_count)"
assert_contains "alert names the node" "$(cat "$SANDBOX/sent")" "grace (justin) has been offline for 1 hour"
assert_contains "alert has NEW heading" "$(cat "$SANDBOX/sent")" "NEW"
assert_not_contains "url not in curl arguments" "$(cat "$SANDBOX/curl.args")" "secrettopic123"
assert_contains "url passed on stdin" "$(cat "$SANDBOX/curl.stdin")" "secrettopic123"
tick $((T0 + 3900))
assert_eq "no repeat" 1 "$(sent_count)"
tick $((T0 + 90000)) 10
assert_eq "no reminder at the wrong hour" 1 "$(sent_count)"
tick $((T0 + 90300)) 9
assert_eq "reminder at the reminder hour" 2 "$(sent_count)"
assert_contains "reminder heading" "$(cat "$SANDBOX/sent")" "STILL OPEN"
tick $((T0 + 90600)) 9
assert_eq "one reminder per day" 2 "$(sent_count)"
view "[$(node grace true)]"
tick $((T0 + 91000)) 3
assert_eq "recovery message" 3 "$(sent_count)"
assert_contains "recovery text" "$(cat "$SANDBOX/sent")" "grace (justin) is back online after"
tick $((T0 + 91300)) 3
assert_eq "recovery sent once" 3 "$(sent_count)"
assert_jq "state is empty after recovery" "$(cat "$GW_STATE/alerts.json")" '.p == {}'

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
alert_set offline 60m > /dev/null
view "[$(node grace false)]"
tick "$T0"
view "[$(node grace true)]"
tick $((T0 + 600))
view "[$(node grace false)]"
tick $((T0 + 3600))
assert_eq "a short blip never alerts" 0 "$(sent_count)"

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
alert_set offline 5m > /dev/null
alert_set low-space 0 > /dev/null
alert_set conflicts 0 > /dev/null
view "[$(node grace false true 2 true)]"
tick "$T0"
assert_eq "immediate problems share one message" 1 "$(sent_count)"
assert_contains "low space in group" "$(cat "$SANDBOX/sent")" "grace (justin) is low on space"
assert_contains "conflicts in group" "$(cat "$SANDBOX/sent")" "has file name conflicts"
assert_contains "reboot in group" "$(cat "$SANDBOX/sent")" "needs a reboot"
assert_not_contains "offline waits for its limit" "$(cat "$SANDBOX/sent")" "offline"
tick $((T0 + 300))
assert_eq "offline follows once it is due" 2 "$(sent_count)"
assert_contains "offline text" "$(cat "$SANDBOX/sent")" "offline for 5 minutes"

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
alert_set offline 5m > /dev/null
view "[$(node grace false)]"
tick "$T0"
echo 1 > "$SANDBOX/curl.rc"
tick $((T0 + 300)) 3 > /dev/null 2>&1
assert_eq "failed send reports failure" 1 "$(ALERT_NOW=$((T0 + 300)) run_alerts > /dev/null 2>&1; echo $?)"
assert_jq "failed send keeps old state" "$(cat "$GW_STATE/alerts.json")" '.p["grace:offline"].notified == 0'
rm -f "$SANDBOX/curl.rc"
: > "$SANDBOX/sent"
tick $((T0 + 360))
assert_eq "retries after a failure" 1 "$(sent_count)"
assert_jq "state saved after success" "$(cat "$GW_STATE/alerts.json")" '.p["grace:offline"].notified > 0'

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
alert_set offline 5m > /dev/null
view "[$(node grace false)]"
tick "$T0"
tick $((T0 + 300))
view "[$(node grace null)]"
tick $((T0 + 600))
assert_eq "unknown connection state keeps the problem" 1 "$(sent_count)"
assert_jq "unknown state keeps the entry" "$(cat "$GW_STATE/alerts.json")" '.p["grace:offline"] != null'
view '[]'
tick $((T0 + 900))
assert_eq "removed node clears quietly" 1 "$(sent_count)"
assert_jq "removed node leaves no state" "$(cat "$GW_STATE/alerts.json")" '.p == {}'

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
alert_set offline 5m > /dev/null
alert_set recovered no > /dev/null
view "[$(node grace false)]"
tick "$T0"
tick $((T0 + 300))
view "[$(node grace true)]"
tick $((T0 + 600))
assert_eq "recovered no sends nothing more" 1 "$(sent_count)"

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
alert_set offline 5m > /dev/null
alert_set reminder off > /dev/null
view "[$(node grace false)]"
tick "$T0"
tick $((T0 + 300))
tick $((T0 + 90000)) 9
assert_eq "reminders off" 1 "$(sent_count)"

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
OLD=2026-11-19T00:00:00Z
view "[$(REPORTED=$OLD node grace true)]"
tick "$T0"
assert_eq "stale status alerts right away" 1 "$(sent_count)"
assert_contains "stale status text" "$(cat "$SANDBOX/sent")" "has not reported its status"

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
view "[$(jq -nc '{name: "grace", role: "contributor", owner: "justin", online: true, status: null}')]"
tick "$T0"
assert_eq "missing status waits" 0 "$(sent_count)"
tick $((T0 + 129600))
assert_eq "missing status alerts after the limit" 1 "$(sent_count)"

reset
alert_set url 'https://discord.com/api/webhooks/123/abc' > /dev/null
alert_set offline 5m > /dev/null
view "[$(node grace false)]"
tick "$T0"
tick $((T0 + 300))
assert_jq "discord body is json" "$(sed -n 1p "$SANDBOX/sent")" '.content | test("grace")'
assert_contains "discord header" "$(cat "$SANDBOX/curl.args")" "application/json"

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
assert_eq "test command works" sent "$(alert_test)"
assert_contains "test message" "$(cat "$SANDBOX/sent")" "TinyCloud test alert"
echo 1 > "$SANDBOX/curl.rc"
assert_eq "test command fails loudly" 1 "$(alert_test > /dev/null 2>&1; echo $?)"
alert_set url off > /dev/null
assert_eq "test without url fails" 1 "$(alert_test > /dev/null 2>&1; echo $?)"

reset
alert_set url 'https://ntfy.sh/t' > /dev/null
alert_set offline 5m > /dev/null
view "[$(node grace false)]"
printf 'garbage' > "$GW_STATE/alerts.json"
tick "$T0"
assert_jq "bad state file is replaced" "$(cat "$GW_STATE/alerts.json")" '.p["grace:offline"] != null'

reset
alert_set heartbeat 'not a url' > /dev/null 2>&1
assert_eq "bad heartbeat rejected" "" "$(alert_get ALERT_HEARTBEAT '')"
alert_set heartbeat 'https://hc-ping.com/secret-uuid-1234' > /dev/null
assert_eq "heartbeat saved" "https://hc-ping.com/secret-uuid-1234" "$(alert_get ALERT_HEARTBEAT '')"
assert_contains "show heartbeat host" "$(alert_show)" "heartbeat          on (hc-ping.com)"
assert_not_contains "show hides heartbeat secret" "$(alert_show)" "secret-uuid-1234"
run_heartbeat
assert_eq "heartbeat pings" 1 "$(sent_count)"
assert_contains "heartbeat url on stdin" "$(cat "$SANDBOX/curl.stdin")" "secret-uuid-1234"
assert_not_contains "heartbeat url not in arguments" "$(cat "$SANDBOX/curl.args")" "secret-uuid-1234"
ST_RC=1
: > "$SANDBOX/sent"
run_heartbeat
assert_eq "no ping when syncthing is down" 0 "$(sent_count)"
assert_eq "syncthing down reports failure" 1 "$(run_heartbeat > /dev/null 2>&1; echo $?)"
ST_RC=0
echo 1 > "$SANDBOX/curl.rc"
assert_eq "failed ping reports failure" 1 "$(run_heartbeat > /dev/null 2>&1; echo $?)"
rm -f "$SANDBOX/curl.rc"
assert_contains "test pings the heartbeat" "$(alert_test)" "heartbeat sent"
alert_set heartbeat off > /dev/null
assert_contains "heartbeat off shown" "$(alert_show)" "heartbeat          off"
: > "$SANDBOX/sent"
run_heartbeat
assert_eq "heartbeat off sends nothing" 0 "$(sent_count)"
assert_eq "test with nothing set fails" 1 "$(alert_test > /dev/null 2>&1; echo $?)"

reset
alert_set gateway-reboot 1h > /dev/null
assert_eq "gateway reboot saved" 60 "$(alert_get ALERT_GWREBOOT 0)"
assert_contains "show gateway reboot" "$(alert_show)" "gw reboot after    1 hour"
alert_set gateway-reboot 36h > /dev/null
alert_set url 'https://ntfy.sh/t' > /dev/null
view "[$(node grace true)]"
touch -d "@$((T0 - 3600))" "$ALERT_REBOOT_FILE"
tick "$T0"
assert_eq "recent reboot request stays quiet" 0 "$(sent_count)"
touch -d "@$((T0 - 130000))" "$ALERT_REBOOT_FILE"
tick "$T0"
assert_eq "old reboot request alerts" 1 "$(sent_count)"
assert_contains "gateway reboot text" "$(cat "$SANDBOX/sent")" "The gateway needs a reboot"
tick $((T0 + 300))
assert_eq "gateway reboot alert once" 1 "$(sent_count)"
rm -f "$ALERT_REBOOT_FILE"
tick $((T0 + 600))
assert_eq "reboot done is announced" 2 "$(sent_count)"
assert_contains "gateway rebooted text" "$(cat "$SANDBOX/sent")" "The gateway was rebooted"
assert_jq "state clear after reboot" "$(cat "$GW_STATE/alerts.json")" '.p == {}'

rm -rf "$SANDBOX"
finish
