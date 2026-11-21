#!/bin/sh
. "${TC_ROOT:-/app}/agent/lib.sh"

WEB_DIR=${TC_WEB_DIR:-/web}

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

make_qr() {
  if command -v qrencode > /dev/null 2>&1; then
    printf '%s' "$1" | qrencode -t SVG -o - -m 1 -s 4 | sed -n '/<svg/,$p'
  fi
}

now_label() {
  nl_tz=$(conf_get TIMEZONE)
  if valid_tz "$nl_tz"; then
    TZ=$nl_tz date '+%I:%M %p' | sed 's/^0//'
  else
    date -u '+%I:%M %p UTC' | sed 's/^0//'
  fi
}

gateway_connected() {
  gc_json=$(st_api GET /rest/system/connections 2> /dev/null) || return 1
  [ "$(printf '%s' "$gc_json" | jq -r --arg id "$(conf_get GATEWAY_ID)" '.connections[$id].connected // false' 2> /dev/null)" = true ]
}

write_page() {
  mkdir -p "$WEB_DIR"
  wp_tmp=$WEB_DIR/.index.html.tmp
  printf '%s\n' "$1" > "$wp_tmp" && mv "$wp_tmp" "$WEB_DIR/index.html"
}

page() {
  cat << EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>TinyCloud node</title>
<style>
body { font-family: system-ui, sans-serif; max-width: 34rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.4; }
h1 { font-size: 1.4rem; }
.ok { color: #1a7f37; font-weight: 600; }
.bad { color: #b42318; font-weight: 600; }
.warn { color: #9a6700; font-weight: 600; }
code { display: block; padding: 0.6rem; background: #f2f2f2; color: #111; word-break: break-all; user-select: all; }
.code { font-size: 2rem; letter-spacing: 0.15em; font-family: monospace; }
svg { width: 12rem; height: 12rem; }
small { color: #666; }
</style>
</head>
<body>
$1
<p><small>Updated $2</small></p>
</body>
</html>
EOF
}

starting_body() {
  printf '<h1>TinyCloud node</h1>\n<p class="warn">Starting up. This page refreshes by itself.</p>'
}

problem_body() {
  printf '<h1>TinyCloud node</h1>\n<p class="bad">The config file has a problem.</p>\n<p>Run <b>tinycloud doctor</b> to see what to fix.</p>'
}

stats_body() {
  sb_file=$(state_file status.local.json)
  if [ ! -s "$sb_file" ]; then
    printf '<p>Waiting for the first status check.</p>'
    return 0
  fi
  sb_pct=$(html_escape "$(jq -r '.percent_stored // "?"' "$sb_file")")
  sb_free=$(jq -r '(.free_bytes // 0) / 1073741824 * 10 | floor / 10' "$sb_file")
  sb_free=$(html_escape "$sb_free")
  sb_version=$(html_escape "$(jq -r '.version // "?"' "$sb_file")")
  sb_low=$(jq -r '.low_space // false' "$sb_file")
  sb_cc=$(html_escape "$(jq -r '.case_conflicts // 0' "$sb_file")")
  printf '<p>Stored: %s%%<br>Free space: %s GB<br>Version: %s</p>' "$sb_pct" "$sb_free" "$sb_version"
  if [ "$sb_low" = true ]; then
    printf '\n<p class="warn">Disk space is low.</p>'
  fi
  if [ "$sb_cc" != 0 ]; then
    printf '\n<p class="warn">%s filenames differ only by upper and lower case. Windows and macOS will have trouble with them.</p>' "$sb_cc"
  fi
}

pending_body() {
  pb_file=$(state_file pending.json)
  [ -s "$pb_file" ] || return 0
  pb_list=$(jq -r '.[] | .name' "$pb_file" 2> /dev/null | tr '\n' ' ')
  if [ -n "$pb_list" ]; then
    printf '\n<p class="warn">Waiting for you to confirm: %s<br>Run <b>tinycloud confirm</b>.</p>' "$(html_escape "$pb_list")"
  fi
}

join_body() {
  jb_line=$(html_escape "$1")
  printf '<h2>Join the cloud</h2>\n<p>Send this line to the cloud owner:</p>\n<code>%s</code>\n' "$jb_line"
  printf '<p>Your verification code. Tell the owner this code too:</p>\n<p class="code">%s</p>\n' "$(html_escape "$2")"
  printf '%s\n' "$(make_qr "$1")"
}

main() {
  rn_name=$(conf_get NODE_NAME)
  rn_role=$(conf_get ROLE reader)
  rn_owner=$(conf_get OWNER)
  rn_time=$(now_label)
  if ! valid_name "$rn_name" || ! valid_role "$rn_role" || ! valid_name "$rn_owner"; then
    write_page "$(page "$(problem_body)" "$rn_time")"
    return 0
  fi
  rn_id=$(read_state device-id)
  if ! valid_device_id "$rn_id"; then
    write_page "$(page "$(starting_body)" "$rn_time")"
    return 0
  fi
  rn_code=$(verify_code "$rn_id")
  rn_line="$rn_name $rn_id $rn_role $rn_owner"
  rn_body="<h1>TinyCloud node: $(html_escape "$rn_name")</h1>
<p>Role: $(html_escape "$rn_role")</p>"
  if gateway_connected; then
    rn_body="$rn_body
<p class=\"ok\">Connected to the cloud</p>"
  else
    rn_body="$rn_body
<p class=\"bad\">Not connected yet</p>
<p>If you just set this up, send the line below to the cloud owner. Otherwise check this machine's internet.</p>"
  fi
  rn_body="$rn_body
$(stats_body)$(pending_body)"
  if ! gateway_connected; then
    rn_body="$rn_body
$(join_body "$rn_line" "$rn_code")"
  fi
  rn_body="$rn_body
<p><small>Device ID: $(html_escape "$rn_id")<br>Code: $(html_escape "$rn_code")</small></p>"
  write_page "$(page "$rn_body" "$rn_time")"
}

if [ "${TC_SOURCED:-0}" != 1 ]; then
  set -eu
  main "$@"
fi
