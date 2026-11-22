ALERT_DEFAULT_OFFLINE=120
ALERT_DEFAULT_NOSTATUS=2160
ALERT_DEFAULT_LOWSPACE=30
ALERT_DEFAULT_CONFLICTS=60
ALERT_DEFAULT_REBOOT=0
ALERT_DEFAULT_GWREBOOT=2160
ALERT_DEFAULT_REMINDER=9
ALERT_DEFAULT_RECOVERED=yes
ALERT_MAX_MINUTES=43200

alert_conf() {
  printf '%s' "$GW_HOME/alerts.conf"
}

alert_get() {
  ag_val=$(sed -n "s/^$1=//p" "$(alert_conf)" 2> /dev/null | tail -n 1)
  if [ -n "$ag_val" ]; then
    printf '%s' "$ag_val"
  else
    printf '%s' "$2"
  fi
}

alert_put() {
  ap_conf=$(alert_conf)
  ap_tmp=$ap_conf.tmp
  mkdir -p "$(dirname "$ap_conf")"
  (
    umask 077
    {
      grep -v "^$1=" "$ap_conf" 2> /dev/null || true
      if [ -n "$2" ]; then
        printf '%s=%s\n' "$1" "$2"
      fi
    } > "$ap_tmp"
  ) || return 1
  chmod 600 "$ap_tmp"
  mv "$ap_tmp" "$ap_conf"
}

alert_minutes() {
  am_in=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  valid "$am_in" '^[0-9]{1,6}[mhd]?$' || return 1
  am_num=$(printf '%s' "$am_in" | tr -d 'mhd')
  case $am_in in
    *h) am_num=$((am_num * 60)) ;;
    *d) am_num=$((am_num * 1440)) ;;
  esac
  [ "$am_num" -le "$ALERT_MAX_MINUTES" ] || return 1
  printf '%s' "$am_num"
}

alert_hour() {
  ah_in=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if [ "$ah_in" = off ]; then
    printf 'off'
    return 0
  fi
  valid "$ah_in" '^[0-9]{1,2}(:00)? ?(am|pm)?$' || return 1
  ah_num=$(printf '%s' "$ah_in" | sed 's/[^0-9].*//')
  ah_num=$((ah_num + 0))
  case $ah_in in
    *am | *pm)
      [ "$ah_num" -ge 1 ] && [ "$ah_num" -le 12 ] || return 1
      case $ah_in in
        *am) [ "$ah_num" -eq 12 ] && ah_num=0 ;;
        *pm) [ "$ah_num" -ne 12 ] && ah_num=$((ah_num + 12)) ;;
      esac
      ;;
    *)
      [ "$ah_num" -le 23 ] || return 1
      ;;
  esac
  printf '%s' "$ah_num"
}

fmt_hour() {
  fh_h=$1
  fh_suffix=AM
  [ "$fh_h" -ge 12 ] && fh_suffix=PM
  fh_h=$((fh_h % 12))
  [ "$fh_h" -eq 0 ] && fh_h=12
  printf '%s:00 %s' "$fh_h" "$fh_suffix"
}

fmt_unit() {
  if [ "$1" -eq 1 ]; then
    printf '1 %s' "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}

fmt_minutes() {
  fm_n=$1
  if [ "$fm_n" -eq 0 ]; then
    printf 'right away'
  elif [ "$fm_n" -lt 60 ]; then
    fmt_unit "$fm_n" minute
  elif [ "$fm_n" -lt 1440 ]; then
    fm_h=$((fm_n / 60))
    fm_m=$((fm_n % 60))
    fmt_unit "$fm_h" hour
    [ "$fm_m" -gt 0 ] && printf ' %s' "$(fmt_unit "$fm_m" minute)"
  else
    fm_d=$((fm_n / 1440))
    fm_h=$(((fm_n % 1440) / 60))
    fmt_unit "$fm_d" day
    [ "$fm_h" -gt 0 ] && printf ' %s' "$(fmt_unit "$fm_h" hour)"
  fi
  return 0
}

valid_alert_url() {
  valid "$1" '^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]{4,500}$'
}

alert_setting_key() {
  case $1 in
    offline) printf 'ALERT_OFFLINE' ;;
    no-status) printf 'ALERT_NOSTATUS' ;;
    low-space) printf 'ALERT_LOWSPACE' ;;
    conflicts) printf 'ALERT_CONFLICTS' ;;
    reboot) printf 'ALERT_REBOOT' ;;
    gateway-reboot) printf 'ALERT_GWREBOOT' ;;
    *) return 1 ;;
  esac
}

alert_setting_min() {
  case $1 in
    offline) printf '1' ;;
    no-status) printf '1500' ;;
    *) printf '0' ;;
  esac
}

alert_set() {
  as_name=${1:-}
  as_value=${2:-}
  if [ -z "$as_name" ] || [ -z "$as_value" ]; then
    usage
    return 1
  fi
  case $as_name in
    url)
      if [ "$as_value" = off ]; then
        alert_put ALERT_URL ""
        echo "alerts are off"
        return 0
      fi
      if ! valid_alert_url "$as_value"; then
        log ERROR "that does not look like a web address (http or https)"
        return 1
      fi
      alert_put ALERT_URL "$as_value"
      echo "alert address saved. Test it with: tinycloud-gw alert test"
      ;;
    heartbeat)
      if [ "$as_value" = off ]; then
        alert_put ALERT_HEARTBEAT ""
        echo "heartbeat is off"
        return 0
      fi
      if ! valid_alert_url "$as_value"; then
        log ERROR "that does not look like a web address (http or https)"
        return 1
      fi
      alert_put ALERT_HEARTBEAT "$as_value"
      echo "heartbeat address saved. The gateway pings it after every status build."
      ;;
    reminder)
      as_hour=$(alert_hour "$as_value") || {
        log ERROR "reminder must be a time on the hour like 9am or 6:00 PM, or off"
        return 1
      }
      alert_put ALERT_REMINDER "$as_hour"
      if [ "$as_hour" = off ]; then
        echo "daily reminders are off"
      else
        echo "reminders at $(fmt_hour "$as_hour")"
      fi
      ;;
    recovered)
      case $as_value in
        yes | no) alert_put ALERT_RECOVERED "$as_value" ;;
        *)
          log ERROR "recovered must be yes or no"
          return 1
          ;;
      esac
      echo "recovery messages: $as_value"
      ;;
    *)
      as_key=$(alert_setting_key "$as_name") || {
        usage
        return 1
      }
      as_min=$(alert_setting_min "$as_name")
      as_num=$(alert_minutes "$as_value") || {
        log ERROR "use a time like 5m, 60m, 2h, or 1d (up to 30 days)"
        return 1
      }
      if [ "$as_num" -lt "$as_min" ]; then
        log ERROR "$as_name must be at least $(fmt_minutes "$as_min")"
        return 1
      fi
      alert_put "$as_key" "$as_num"
      echo "$as_name: $(fmt_minutes "$as_num")"
      ;;
  esac
}

alert_show_line() {
  printf '%-18s %s\n' "$1" "$2"
}

alert_show() {
  sh_url=$(alert_get ALERT_URL "")
  if [ -n "$sh_url" ]; then
    sh_host=$(printf '%s' "$sh_url" | sed 's#^https\{0,1\}://\([^/]*\).*#\1#')
    echo "Alerts are on (sending to $sh_host)"
  else
    echo "Alerts are off. Turn them on with: tinycloud-gw alert set url ADDRESS"
  fi
  echo ""
  alert_show_line "offline after" "$(fmt_minutes "$(alert_get ALERT_OFFLINE "$ALERT_DEFAULT_OFFLINE")")"
  alert_show_line "no status after" "$(fmt_minutes "$(alert_get ALERT_NOSTATUS "$ALERT_DEFAULT_NOSTATUS")")"
  alert_show_line "low space after" "$(fmt_minutes "$(alert_get ALERT_LOWSPACE "$ALERT_DEFAULT_LOWSPACE")")"
  alert_show_line "conflicts after" "$(fmt_minutes "$(alert_get ALERT_CONFLICTS "$ALERT_DEFAULT_CONFLICTS")")"
  alert_show_line "reboot after" "$(fmt_minutes "$(alert_get ALERT_REBOOT "$ALERT_DEFAULT_REBOOT")")"
  alert_show_line "gw reboot after" "$(fmt_minutes "$(alert_get ALERT_GWREBOOT "$ALERT_DEFAULT_GWREBOOT")")"
  sh_rem=$(alert_get ALERT_REMINDER "$ALERT_DEFAULT_REMINDER")
  if [ "$sh_rem" = off ]; then
    alert_show_line "daily reminder" "off"
  else
    alert_show_line "daily reminder" "$(fmt_hour "$sh_rem")"
  fi
  alert_show_line "recovery messages" "$(alert_get ALERT_RECOVERED "$ALERT_DEFAULT_RECOVERED")"
  sh_hb=$(alert_get ALERT_HEARTBEAT "")
  if [ -n "$sh_hb" ]; then
    alert_show_line "heartbeat" "on ($(printf '%s' "$sh_hb" | sed 's#^https\{0,1\}://\([^/]*\).*#\1#'))"
  else
    alert_show_line "heartbeat" "off"
  fi
}

alert_send() {
  sd_url=$(alert_get ALERT_URL "")
  [ -n "$sd_url" ] || return 1
  sd_msg=$(printf '%s' "$1" | head -c 1800)
  case $sd_url in
    https://discord.com/api/webhooks/* | https://discordapp.com/api/webhooks/*)
      sd_body=$(jq -nc --arg c "$sd_msg" '{content: $c}')
      printf 'url = "%s"\n' "$sd_url" | curl -fsS -K - --max-time 15 -o /dev/null \
        -H 'Content-Type: application/json' --data-raw "$sd_body" 2> /dev/null
      ;;
    *)
      printf 'url = "%s"\n' "$sd_url" | curl -fsS -K - --max-time 15 -o /dev/null \
        -H 'Title: TinyCloud' --data-raw "$sd_msg" 2> /dev/null
      ;;
  esac
}

heartbeat_ping() {
  hp_url=$(alert_get ALERT_HEARTBEAT "")
  [ -n "$hp_url" ] || return 1
  printf 'url = "%s"\n' "$hp_url" | curl -fsS -K - --max-time 15 --retry 2 -o /dev/null 2> /dev/null
}

run_heartbeat() {
  [ -n "$(alert_get ALERT_HEARTBEAT "")" ] || return 0
  st_api GET /rest/system/ping > /dev/null 2>&1 || return 1
  heartbeat_ping || {
    log ERROR "heartbeat could not be sent"
    return 1
  }
}

alert_test() {
  at_url=$(alert_get ALERT_URL "")
  at_hb=$(alert_get ALERT_HEARTBEAT "")
  if [ -z "$at_url" ] && [ -z "$at_hb" ]; then
    log ERROR "nothing is set up, use: tinycloud-gw alert set url ADDRESS"
    return 1
  fi
  at_rc=0
  if [ -n "$at_url" ]; then
    if alert_send "TinyCloud test alert from $(hostname)"; then
      echo "sent"
    else
      log ERROR "could not send, check the address"
      at_rc=1
    fi
  fi
  if [ -n "$at_hb" ]; then
    if heartbeat_ping; then
      echo "heartbeat sent"
    else
      log ERROR "heartbeat could not be sent, check the address"
      at_rc=1
    fi
  fi
  return "$at_rc"
}

alert_text() {
  case $1 in
    offline) printf '%s (%s) has been offline for %s' "$2" "$3" "$(fmt_minutes "$5")" ;;
    nostatus) printf '%s (%s) has not reported its status' "$2" "$3" ;;
    lowspace) printf '%s (%s) is low on space' "$2" "$3" ;;
    conflicts) printf '%s (%s) has file name conflicts' "$2" "$3" ;;
    reboot) printf '%s (%s) needs a reboot' "$2" "$3" ;;
    gwreboot) printf 'The gateway needs a reboot' ;;
  esac
}

alert_cleared_text() {
  case $1 in
    offline) printf '%s (%s) is back online after %s' "$2" "$3" "$(fmt_minutes "$5")" ;;
    nostatus) printf '%s (%s) is reporting its status again' "$2" "$3" ;;
    lowspace) printf '%s (%s) has enough space again' "$2" "$3" ;;
    conflicts) printf '%s (%s) has no more name conflicts' "$2" "$3" ;;
    reboot) printf '%s (%s) was rebooted' "$2" "$3" ;;
    gwreboot) printf 'The gateway was rebooted' ;;
  esac
}

ALERT_JQ='
  def mins($a; $b): (($a - $b) / 60 | floor);
  . as $in
  | $in.cfg as $cfg
  | $in.now as $now
  | $in.view.nodes as $nodes
  | (($nodes | map(.name)) + ["gateway"]) as $names
  | ($nodes | map(select(.online == null) | .name)) as $unknown
  | ([ $nodes[] | . as $n
      | ( (if $n.online == false then [{kind: "offline", delay: $cfg.offline}] else [] end)
        + (if $n.status == null then [{kind: "nostatus", delay: $cfg.nostatus}]
           elif ($now - ($n.status.reported | fromdateiso8601)) >= ($cfg.nostatus * 60) then [{kind: "nostatus", delay: 0}]
           else [] end)
        + (if $n.status != null and $n.status.low_space == true then [{kind: "lowspace", delay: $cfg.lowspace}] else [] end)
        + (if $n.status != null and ($n.status.case_conflicts // 0) > 0 then [{kind: "conflicts", delay: $cfg.conflicts}] else [] end)
        + (if $n.status != null and $n.status.reboot_required == true then [{kind: "reboot", delay: $cfg.reboot}] else [] end) )
      | map(. + {name: $n.name, owner: $n.owner, key: "\($n.name):\(.kind)"}) ] | add // []) as $nodeconds
  | ((if $in.gwage >= 0 and $in.gwage >= $cfg.gwreboot then [{kind: "gwreboot", delay: 0, name: "gateway", owner: "gateway", key: "gateway:gwreboot"}] else [] end)) as $gwconds
  | ($nodeconds + $gwconds) as $conds
  | ($conds | map(.key)) as $keys
  | $in.state.p as $old
  | ([ $old | to_entries[]
       | select((.key as $k | $keys | index($k) | not)
                and ((.value.name as $nm | $names | index($nm)) != null)
                and ((.value.name as $nm | $unknown | index($nm)) == null or .value.kind != "offline")) ]) as $cleared
  | ([ $old | to_entries[]
       | select((.value.name as $nm | $unknown | index($nm)) != null and .value.kind == "offline") ]) as $held
  | ([ $conds[] | . as $c
      | ($old[$c.key] // {since: $now, notified: 0, reminded: 0}) as $e
      | {key: $c.key, value: ($e + {name: $c.name, owner: $c.owner, kind: $c.kind, delay: $c.delay})} ]) as $active
  | ($active | map(select(.value.notified == 0 and ($now - .value.since) >= (.value.delay * 60)))) as $due
  | ($active | map(select(.value.notified > 0
        and $cfg.reminder != "off"
        and ($cfg.reminder | tonumber) == $in.hour
        and ($now - .value.reminded) >= 72000))) as $remind
  | ($due | map(.key)) as $dueKeys
  | ($remind | map(.key)) as $remindKeys
  | ($active | map(
      if (.key as $k | $dueKeys | index($k)) != null then .value |= (. + {notified: $now, reminded: $now})
      elif (.key as $k | $remindKeys | index($k)) != null then .value |= (. + {reminded: $now})
      else . end)) as $next
  | {
      p: (($next + $held) | map({key, value: (.value | {name, owner, kind, since, notified, reminded})}) | from_entries),
      problems: ($due | map(.value | [.kind, .name, .owner, mins($now; .since)])),
      reminders: ($remind | map(.value | [.kind, .name, .owner, mins($now; .since)])),
      recovered: (if $cfg.recovered then ($cleared | map(select(.value.notified > 0) | .value | [.kind, .name, .owner, mins($now; .since)])) else [] end)
    }'

alert_state_file() {
  printf '%s' "$GW_STATE/alerts.json"
}

alert_lines() {
  al_list=$1
  al_fn=$2
  printf '%s' "$al_list" | jq -r '.[] | @tsv' | while IFS="$(printf '\t')" read -r al_kind al_name al_owner al_min; do
    printf '%s\n' "- $($al_fn "$al_kind" "$al_name" "$al_owner" "" "$al_min")"
  done
}

run_alerts() {
  ra_url=$(alert_get ALERT_URL "")
  [ -n "$ra_url" ] || return 0
  [ -r "$GW_STATE/view.json" ] || return 0
  ra_now=${ALERT_NOW:-$(date +%s)}
  ra_hour=${ALERT_HOUR:-$(date +%H | sed 's/^0*\([0-9]\)/\1/')}
  ra_view=$(jq -c '.' "$GW_STATE/view.json" 2> /dev/null) || return 0
  ra_state=$(jq -c 'select(.p | type == "object")' "$(alert_state_file)" 2> /dev/null)
  [ -n "$ra_state" ] || ra_state='{"p":{}}'
  ra_gwage=-1
  ra_rf=${ALERT_REBOOT_FILE:-/var/run/reboot-required}
  if [ -e "$ra_rf" ]; then
    ra_gwage=$(((ra_now - $(stat -c %Y "$ra_rf" 2> /dev/null || echo "$ra_now")) / 60))
    [ "$ra_gwage" -ge 0 ] || ra_gwage=0
  fi
  ra_rec=true
  [ "$(alert_get ALERT_RECOVERED "$ALERT_DEFAULT_RECOVERED")" = yes ] || ra_rec=false
  ra_out=$(jq -nc --argjson view "$ra_view" --argjson state "$ra_state" --argjson now "$ra_now" \
    --argjson hour "$ra_hour" --argjson gwage "$ra_gwage" \
    --argjson gwreboot "$(alert_get ALERT_GWREBOOT "$ALERT_DEFAULT_GWREBOOT")" \
    --argjson offline "$(alert_get ALERT_OFFLINE "$ALERT_DEFAULT_OFFLINE")" \
    --argjson nostatus "$(alert_get ALERT_NOSTATUS "$ALERT_DEFAULT_NOSTATUS")" \
    --argjson lowspace "$(alert_get ALERT_LOWSPACE "$ALERT_DEFAULT_LOWSPACE")" \
    --argjson conflicts "$(alert_get ALERT_CONFLICTS "$ALERT_DEFAULT_CONFLICTS")" \
    --argjson reboot "$(alert_get ALERT_REBOOT "$ALERT_DEFAULT_REBOOT")" \
    --arg reminder "$(alert_get ALERT_REMINDER "$ALERT_DEFAULT_REMINDER")" \
    --argjson recovered "$ra_rec" \
    "{view: \$view, state: \$state, now: \$now, hour: \$hour, gwage: \$gwage, cfg: {gwreboot: \$gwreboot, offline: \$offline, nostatus: \$nostatus, lowspace: \$lowspace, conflicts: \$conflicts, reboot: \$reboot, reminder: \$reminder, recovered: \$recovered}} | $ALERT_JQ") || {
    log ERROR "alerts could not read the status view"
    return 1
  }
  ra_msg=""
  ra_new=$(alert_lines "$(printf '%s' "$ra_out" | jq -c '.problems')" alert_text)
  ra_old=$(alert_lines "$(printf '%s' "$ra_out" | jq -c '.reminders')" alert_text)
  ra_ok=$(alert_lines "$(printf '%s' "$ra_out" | jq -c '.recovered')" alert_cleared_text)
  [ -n "$ra_new" ] && ra_msg="$ra_msg
NEW
$ra_new"
  [ -n "$ra_old" ] && ra_msg="$ra_msg
STILL OPEN
$ra_old"
  [ -n "$ra_ok" ] && ra_msg="$ra_msg
RESOLVED
$ra_ok"
  if [ -n "$ra_msg" ]; then
    if ! alert_send "TinyCloud$ra_msg"; then
      log ERROR "alert could not be sent, will try again"
      return 1
    fi
  fi
  ra_file=$(alert_state_file)
  printf '%s' "$ra_out" | jq -c '{p: .p}' > "$ra_file.tmp" && mv "$ra_file.tmp" "$ra_file"
}

cmd_alert() {
  ca_sub=${1:-show}
  [ $# -gt 0 ] && shift
  case $ca_sub in
    show) alert_show ;;
    set) alert_set "$@" ;;
    test) alert_test ;;
    *)
      usage
      return 1
      ;;
  esac
}
