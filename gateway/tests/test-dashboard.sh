#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
BIN=$SANDBOX/bin
mkdir -p "$BIN"
VIEW_FILE=$SANDBOX/view.json
PATH=$BIN:$PATH
export PATH

cat > "$BIN/ssh" << 'EOT'
#!/bin/sh
printf 'ssh %s\n' "$*" >> "$FAKE_SSH_LOG"
[ "${FAKE_SSH_FAIL:-0}" = 1 ] && exit 255
[ -f "$FAKE_SSH_FAIL_FILE" ] && exit 255
case "$*" in
  *"tinycloud-gw status"*)
    [ -f "$FAKE_STATUS_RC" ] && exit "$(cat "$FAKE_STATUS_RC")"
    cat "$FAKE_STATUS"
    ;;
  *) cat "$FAKE_VIEW" ;;
esac
EOT
chmod +x "$BIN/ssh"
FAKE_SSH_LOG=$SANDBOX/ssh.log
FAKE_VIEW=$VIEW_FILE
FAKE_SSH_FAIL_FILE=$SANDBOX/ssh.fail
FAKE_STATUS=$SANDBOX/status.txt
FAKE_STATUS_RC=$SANDBOX/status.rc
export FAKE_SSH_LOG FAKE_VIEW FAKE_SSH_FAIL_FILE FAKE_STATUS FAKE_STATUS_RC

cat > "$VIEW_FILE" << 'EOT'
{"version":1,"generated":"2026-11-21T20:00:00Z","nodes":[{"name":"adrian","role":"contributor","owner":"justin","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":167600000000,"low_space":false,"case_conflicts":0,"reported":"2026-11-21T19:55:00Z"}},{"name":"grace","role":"contributor","owner":"justin","online":false,"status":null}]}
EOT

OUT=$SANDBOX/page.html
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open --out "$OUT" root@gw.example.com 2>&1)
assert_contains "writes the page" "$out" "Wrote $OUT"
assert_eq "page exists" 1 "$([ -f "$OUT" ] && echo 1 || echo 0)"
page=$(cat "$OUT")
assert_contains "page has data" "$page" '"name":"adrian"'
assert_contains "page has title" "$page" "<title>TinyCloud</title>"
assert_contains "ssh asked for the view" "$(cat "$FAKE_SSH_LOG")" "root@gw.example.com tinycloud-gw view"
assert_eq "page is private" 600 "$(stat -c %a "$OUT" 2> /dev/null || stat -f %Lp "$OUT")"

cat > "$VIEW_FILE" << 'EOT'
{"version":1,"generated":"x","nodes":[{"name":"</script><script>alert(1)</script>","role":"reader","owner":"a","online":true,"status":null}]}
EOT
sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open --out "$OUT" gw.example.com > /dev/null 2>&1
page=$(cat "$OUT")
assert_not_contains "data cannot close the script tag" "$page" "</script><script>alert(1)"
assert_contains "angle bracket escaped" "$page" 'u003c/script>'
assert_eq "only the page scripts exist" 2 "$(grep -c '^<script' "$OUT")"

FAKE_SSH_FAIL=1
export FAKE_SSH_FAIL
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open --out "$OUT" gw.example.com 2>&1)
assert_contains "ssh failure explained" "$out" "Could not read the view"
FAKE_SSH_FAIL=0
export FAKE_SSH_FAIL

printf 'not json\n' > "$VIEW_FILE"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open --out "$OUT" gw.example.com 2>&1)
assert_contains "bad reply refused" "$out" "did not return a status view"

out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open 2>&1)
assert_contains "host needed" "$out" "usage:"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open 'bad host;rm' 2>&1)
assert_contains "bad host refused" "$out" "not a valid host"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --bogus gw 2>&1)
assert_contains "unknown flag" "$out" "usage:"

page=$(cat "$OUT")
assert_not_contains "no auto refresh by default" "$page" "http-equiv"

cat > "$VIEW_FILE" << 'EOT'
{"version":1,"generated":"x","nodes":[{"name":"first","role":"reader","owner":"a","online":true,"status":null}]}
EOT
WOUT=$SANDBOX/watch.html
TC_DASHBOARD_INTERVAL=1 sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open --watch --out "$WOUT" gw.example.com > "$SANDBOX/watch.log" 2>&1 &
watch_pid=$!
sleep 1
page=$(cat "$WOUT")
assert_contains "watch page refreshes itself" "$page" '<meta http-equiv="refresh" content="1">'
assert_contains "watch first fetch" "$page" '"name":"first"'
cat > "$VIEW_FILE" << 'EOT'
{"version":1,"generated":"x","nodes":[{"name":"second","role":"reader","owner":"a","online":true,"status":null}]}
EOT
sleep 3
page=$(cat "$WOUT")
assert_contains "watch picks up new data" "$page" '"name":"second"'
touch "$FAKE_SSH_FAIL_FILE"
printf 'not json\n' > "$VIEW_FILE"
sleep 3
page=$(cat "$WOUT")
assert_contains "watch keeps last page on failure" "$page" '"name":"second"'
assert_contains "watch reports refresh failure" "$(cat "$SANDBOX/watch.log")" "Could not refresh"
rm -f "$FAKE_SSH_FAIL_FILE"
kill "$watch_pid" 2> /dev/null
wait "$watch_pid" 2> /dev/null
assert_contains "watch says how to stop" "$(cat "$SANDBOX/watch.log")" "Ctrl+C"

printf 'TinyCloud: 1 node, 1 online, 0 with warnings. Updated just now.\n\nNODE\nfirst\n' > "$FAKE_STATUS"
: > "$FAKE_SSH_LOG"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" gw.example.com 2>&1)
assert_contains "text is the default" "$out" "TinyCloud: 1 node, 1 online"
assert_contains "text asks the gateway for status" "$(cat "$FAKE_SSH_LOG")" "gw.example.com tinycloud-gw status"
assert_not_contains "text mode writes no page" "$out" "Wrote"
assert_not_contains "no color when not a terminal" "$(cat "$FAKE_SSH_LOG")" "--color"

echo 255 > "$FAKE_STATUS_RC"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" gw.example.com 2>&1)
assert_contains "text ssh failure explained" "$out" "Could not read the status"
echo 1 > "$FAKE_STATUS_RC"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" gw.example.com 2>&1)
assert_contains "old gateway explained" "$out" "up to date"
rm -f "$FAKE_STATUS_RC"

TC_DASHBOARD_INTERVAL=1 sh "$ROOT/dashboard/tinycloud-dashboard" --watch gw.example.com > "$SANDBOX/tw.log" 2>&1 &
tw_pid=$!
sleep 1
printf 'TinyCloud: 1 node, 1 online, 0 with warnings. Updated just now.\n\nNODE\nchanged\n' > "$FAKE_STATUS"
sleep 3
echo 255 > "$FAKE_STATUS_RC"
sleep 2
kill "$tw_pid" 2> /dev/null
wait "$tw_pid" 2> /dev/null
rm -f "$FAKE_STATUS_RC"
tw=$(cat "$SANDBOX/tw.log")
assert_contains "text watch shows first data" "$tw" "first"
assert_contains "text watch picks up new data" "$tw" "changed"
assert_contains "text watch clears the screen" "$tw" "$(printf '\033[H\033[2J')"
assert_contains "text watch says how to stop" "$tw" "Ctrl+C"
assert_contains "text watch survives failures" "$tw" "Could not refresh"

if command -v node > /dev/null 2>&1; then
  cat > "$VIEW_FILE" << 'EOT'
{"version":1,"generated":"2026-11-21T20:00:00Z","nodes":[{"name":"adrian","role":"contributor","owner":"justin","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":167600000000,"low_space":true,"case_conflicts":2,"reported":"2026-11-21T19:55:00Z"}},{"name":"grace","role":"contributor","owner":"justin","online":false,"status":null},{"name":"x","role":"reader","owner":"finn","online":null,"status":null}]}
EOT
  sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open --out "$OUT" gw.example.com > /dev/null 2>&1
  cat > "$SANDBOX/run.js" << 'EOT'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const scripts = [...html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)];
const dataText = scripts[0][2];
const code = scripts[1][2];
function mk(tag) {
  return {tag, children: [], style: {}, textContent: '', className: '', title: '',
    appendChild(c) { this.children.push(c); return c; }};
}
const root = mk('out');
const sub = mk('sub');
const doc = {
  getElementById(id) { return id === 'data' ? {textContent: dataText} : id === 'sub' ? sub : root; },
  createElement: mk,
  createTextNode(t) { return {text: t}; }
};
new Function('document', code)(doc);
function text(n) { return (n.text || '') + (n.textContent || '') + (n.children || []).map(text).join('|'); }
console.log(sub.textContent);
console.log(text(root));
EOT
  js=$(node "$SANDBOX/run.js" "$OUT" 2>&1)
  assert_contains "js runs and summarizes" "$js" "3 nodes, 1 online, 3 with warnings"
  assert_contains "js shows offline" "$js" "Offline"
  assert_contains "js shows low space" "$js" "Low space"
  assert_contains "js shows conflicts" "$js" "2 name conflicts"
  assert_contains "js shows free space" "$js" "156.1 GB"
  assert_contains "js shows unknown state" "$js" "Unknown"
  assert_contains "js has an uptime column" "$js" "Uptime"

  nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > "$VIEW_FILE" << EOT
{"version":1,"generated":"$nowiso","nodes":[{"name":"old","role":"reader","owner":"a","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":1,"low_space":false,"case_conflicts":0,"reported":"$nowiso","booted":"2020-01-01T00:00:00Z"}},{"name":"down","role":"reader","owner":"a","online":false,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":1,"low_space":false,"case_conflicts":0,"reported":"$nowiso","booted":"2020-01-01T00:00:00Z"}}]}
EOT
  sh "$ROOT/dashboard/tinycloud-dashboard" --web --no-open --out "$OUT" gw.example.com > /dev/null 2>&1
  js=$(node "$SANDBOX/run.js" "$OUT" 2>&1)
  assert_contains "js shows uptime in days" "$js" "days"
  assert_eq "offline node has no uptime in js" 1 "$(printf '%s\n' "$js" | tail -1 | tr '|' '\n' | grep -c ' days$')"
fi

assert_contains "web page flags a needed reboot" "$(cat "$ROOT/dashboard/tinycloud-dashboard")" "Reboot needed"

finish
