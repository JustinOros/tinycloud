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
cat "$FAKE_VIEW"
EOT
chmod +x "$BIN/ssh"
FAKE_SSH_LOG=$SANDBOX/ssh.log
FAKE_VIEW=$VIEW_FILE
export FAKE_SSH_LOG FAKE_VIEW

cat > "$VIEW_FILE" << 'EOT'
{"version":1,"generated":"2026-11-21T20:00:00Z","nodes":[{"name":"adrian","role":"contributor","owner":"justin","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":167600000000,"low_space":false,"case_conflicts":0,"reported":"2026-11-21T19:55:00Z"}},{"name":"grace","role":"contributor","owner":"justin","online":false,"status":null}]}
EOT

OUT=$SANDBOX/page.html
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --no-open --out "$OUT" root@gw.example.com 2>&1)
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
sh "$ROOT/dashboard/tinycloud-dashboard" --no-open --out "$OUT" gw.example.com > /dev/null 2>&1
page=$(cat "$OUT")
assert_not_contains "data cannot close the script tag" "$page" "</script><script>alert(1)"
assert_contains "angle bracket escaped" "$page" 'u003c/script>'
assert_eq "only the page scripts exist" 2 "$(grep -c '^<script' "$OUT")"

FAKE_SSH_FAIL=1
export FAKE_SSH_FAIL
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --no-open --out "$OUT" gw.example.com 2>&1)
assert_contains "ssh failure explained" "$out" "Could not read the view"
FAKE_SSH_FAIL=0
export FAKE_SSH_FAIL

printf 'not json\n' > "$VIEW_FILE"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --no-open --out "$OUT" gw.example.com 2>&1)
assert_contains "bad reply refused" "$out" "did not return a status view"

out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --no-open 2>&1)
assert_contains "host needed" "$out" "usage:"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --no-open 'bad host;rm' 2>&1)
assert_contains "bad host refused" "$out" "not a valid host"
out=$(sh "$ROOT/dashboard/tinycloud-dashboard" --bogus gw 2>&1)
assert_contains "unknown flag" "$out" "usage:"

if command -v node > /dev/null 2>&1; then
  cat > "$VIEW_FILE" << 'EOT'
{"version":1,"generated":"2026-11-21T20:00:00Z","nodes":[{"name":"adrian","role":"contributor","owner":"justin","online":true,"status":{"version":"0.1.0","percent_stored":100,"free_bytes":167600000000,"low_space":true,"case_conflicts":2,"reported":"2026-11-21T19:55:00Z"}},{"name":"grace","role":"contributor","owner":"justin","online":false,"status":null},{"name":"x","role":"reader","owner":"finn","online":null,"status":null}]}
EOT
  sh "$ROOT/dashboard/tinycloud-dashboard" --no-open --out "$OUT" gw.example.com > /dev/null 2>&1
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
fi

finish
