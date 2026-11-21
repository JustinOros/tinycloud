#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
. "$HERE/harness.sh"

ME=$(mkid A)
GW=$(mkid B)

setup() {
  new_sandbox
  TC_WEB_DIR=$SANDBOX/web
  export TC_STATE_DIR TC_LOG_DIR TC_LIBRARY_DIR TC_SYSTEM_DIR TC_CONF TC_ST_CONFIG TC_WEB_DIR
  . "$TC_ROOT/agent/lib.sh"
  . "$TC_ROOT/agent/render.sh"
  st_api() { fake_st_api "$@"; }
  make_qr() { printf '<svg>QRSTUB</svg>'; }
  cat > "$TC_CONF" << CONF
NODE_NAME=rocky
OWNER=justin
ROLE=anchor
TIMEZONE=America/Phoenix
GATEWAY_ID=$GW
CONF
  printf '%s\n' "$ME" > "$TC_STATE_DIR/device-id"
  FAKE_MY_ID=$ME
}

page_text() {
  cat "$WEB_DIR/index.html"
}

setup
rm -f "$TC_STATE_DIR/device-id"
main
assert_contains "starting page" "$(page_text)" "Starting up"

setup
conf_set "$TC_CONF" NODE_NAME 'Bad<name>'
main
assert_contains "bad config page" "$(page_text)" "config file has a problem"
assert_not_contains "bad name not echoed" "$(page_text)" "Bad<name>"

setup
main
page=$(page_text)
assert_contains "shows node name" "$page" "TinyCloud node: rocky"
assert_contains "not connected message" "$page" "Not connected yet"
assert_contains "join section shown" "$page" "Join the cloud"
assert_contains "join line shown" "$page" "rocky $ME anchor justin"
assert_contains "verification code shown" "$page" "$(verify_code "$ME")"
assert_contains "qr shown" "$page" "QRSTUB"
assert_contains "csp present" "$page" "Content-Security-Policy"
assert_contains "updated time is 12 hour" "$(printf '%s' "$page" | grep -o 'Updated [^<]*')" "M"
assert_eq "12 hour format" 1 "$(printf '%s' "$page" | grep -Ec 'Updated [0-9]{1,2}:[0-9]{2} (AM|PM)')"
assert_eq "no temp file left" 0 "$(find "$WEB_DIR" -name '.index*' | wc -l | tr -d ' ')"

setup
printf '{"connections":{"%s":{"connected":true}}}' "$GW" > "$FAKE_DIR/connections.json"
main
page=$(page_text)
assert_contains "connected message" "$page" "Connected to the cloud"
assert_not_contains "join section hidden" "$page" "Join the cloud"
assert_contains "device id still shown" "$page" "$ME"

setup
printf '{"percent_stored":50,"free_bytes":11274289152,"version":"<script>x</script>","low_space":true,"case_conflicts":2}' > "$TC_STATE_DIR/status.local.json"
main
page=$(page_text)
assert_contains "percent shown" "$page" "Stored: 50%"
assert_contains "free space in GB" "$page" "Free space: 10.5 GB"
assert_contains "low space warned" "$page" "Disk space is low"
assert_contains "case conflicts warned" "$page" "2 filenames differ only by upper and lower case"
assert_not_contains "version is escaped" "$page" "<script>x"
assert_contains "escaped version shown" "$page" "&lt;script&gt;x&lt;/script&gt;"

setup
printf '[{"name":"grace"},{"name":"<b>x"}]' > "$TC_STATE_DIR/pending.json"
main
page=$(page_text)
assert_contains "pending peers shown" "$page" "grace"
assert_contains "pending command hinted" "$page" "tinycloud confirm"
assert_not_contains "pending names escaped" "$page" "<b>x"

assert_eq "escape handles all five" '&amp;&lt;&gt;&quot;&#39;' "$(html_escape "&<>\"'")"

finish
