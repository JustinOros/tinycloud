TC_ROOT=${TC_ROOT:-/app}
TC_CONF=${TC_CONF:-/config/tinycloud.conf}
TC_STATE_DIR=${TC_STATE_DIR:-/state}
TC_LOG_DIR=${TC_LOG_DIR:-/logs}
TC_LIBRARY_DIR=${TC_LIBRARY_DIR:-/data/library}
TC_SYSTEM_DIR=${TC_SYSTEM_DIR:-/data/system}
TC_ST_URL=${TC_ST_URL:-http://syncthing:8384}
TC_ST_CONFIG=${TC_ST_CONFIG:-/syncthing-config/config.xml}

if [ -z "${TC_VERSION:-}" ]; then
  TC_VERSION=$(cat "$TC_ROOT/VERSION" 2>/dev/null || echo unknown)
fi

log_to_file() {
  [ -d "$TC_LOG_DIR" ] || return 0
  ltf_file=$TC_LOG_DIR/errors.log
  if [ -f "$ltf_file" ] && [ "$(wc -c < "$ltf_file")" -gt 1048576 ]; then
    mv "$ltf_file" "$ltf_file.1"
  fi
  printf '%s\n' "$1" >> "$ltf_file"
}

log() {
  log_level=$1
  shift
  log_msg=$(printf '%s' "$*" | tr -c '[:print:]' '?')
  log_line="$(date -u +%Y-%m-%dT%H:%M:%SZ) tinycloud-agent $TC_VERSION $log_level $log_msg"
  printf '%s\n' "$log_line"
  case $log_level in
    WARN|ERROR) log_to_file "$log_line" ;;
  esac
}

valid() {
  case $1 in
    *'
'*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq "$2"
}

valid_name() { valid "$1" '^[a-z0-9-]{1,32}$'; }
valid_device_id() { valid "$1" '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$'; }
valid_host() { valid "$1" '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'; }
valid_token() { valid "$1" '^[A-Za-z0-9_-]{1,128}$'; }
valid_int() { valid "$1" '^[0-9]{1,9}$'; }

valid_role() {
  case $1 in
    anchor|contributor|partial|reader) return 0 ;;
  esac
  return 1
}

valid_order() {
  case $1 in
    random|alphabetic|smallestFirst|largestFirst|oldestFirst|newestFirst) return 0 ;;
  esac
  return 1
}

conf_get() {
  cg_value=$(sed -n "s/^$1=//p" "$TC_CONF" 2>/dev/null | tail -n 1 | tr -d '\r')
  if [ -n "$cg_value" ]; then
    printf '%s' "$cg_value"
  else
    printf '%s' "${2:-}"
  fi
}

state_file() {
  printf '%s/%s' "$TC_STATE_DIR" "$1"
}

read_state() {
  cat "$(state_file "$1")" 2>/dev/null || true
}

write_atomic() {
  printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

calc_min_free_mb() {
  cmf_pct_mb=$(($1 * $2 / 100 / 1024))
  cmf_gb_mb=$(($3 * 1024))
  if [ "$cmf_pct_mb" -gt "$cmf_gb_mb" ]; then
    printf '%s' "$cmf_pct_mb"
  else
    printf '%s' "$cmf_gb_mb"
  fi
}

st_key() {
  sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$TC_ST_CONFIG" 2>/dev/null | head -n 1
}

st_api() {
  api_method=$1
  api_path=$2
  api_body=${3:-}
  api_key=$(st_key)
  if [ -z "$api_key" ]; then
    log ERROR "syncthing api key not found"
    return 1
  fi
  if [ -n "$api_body" ]; then
    printf 'header = "X-API-Key: %s"\n' "$api_key" |
      curl -sS --fail --connect-timeout 5 --max-time 15 -K - -X "$api_method" \
        -H 'Content-Type: application/json' --data "$api_body" "$TC_ST_URL$api_path"
  else
    printf 'header = "X-API-Key: %s"\n' "$api_key" |
      curl -sS --fail --connect-timeout 5 --max-time 15 -K - -X "$api_method" "$TC_ST_URL$api_path"
  fi
}

st_wait() {
  sw_n=0
  while [ "$sw_n" -lt "${1:-30}" ]; do
    if st_api GET /rest/system/ping > /dev/null 2>&1; then
      return 0
    fi
    sw_n=$((sw_n + 1))
    sleep 1
  done
  log ERROR "syncthing api not reachable"
  return 1
}

put_device() {
  pd_defaults=$(st_api GET /rest/config/defaults/device) || return 1
  pd_body=$(printf '%s' "$pd_defaults" | jq -c --arg id "$1" --arg name "$2" --argjson addr "$3" \
    '. * {deviceID: $id, name: $name, addresses: $addr, compression: "metadata", introducer: false, autoAcceptFolders: false, paused: false, untrusted: false}')
  st_api PUT "/rest/config/devices/$1" "$pd_body" > /dev/null
}

put_folder() {
  pf_extra=${6:-}
  [ -n "$pf_extra" ] || pf_extra='{}'
  pf_defaults=$(st_api GET /rest/config/defaults/folder) || return 1
  pf_body=$(printf '%s' "$pf_defaults" | jq -c --arg id "$1" --arg label "$2" --arg path "$3" --arg type "$4" \
    --argjson devices "$5" --argjson extra "$pf_extra" \
    '. * {id: $id, label: $label, path: $path, type: $type, devices: $devices, rescanIntervalS: 3600, fsWatcherEnabled: true, fsWatcherDelayS: 10} * $extra')
  st_api PUT "/rest/config/folders/$1" "$pf_body" > /dev/null
}
