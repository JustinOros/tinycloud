GW_HOME=${GW_HOME:-/opt/tinycloud-gateway}
GW_OS_RELEASE=${GW_OS_RELEASE:-/etc/os-release}
GW_ST_URL=${GW_ST_URL:-http://127.0.0.1:8384}
GW_ST_CONFIG=${GW_ST_CONFIG:-$GW_HOME/data/syncthing/config/config.xml}

log() {
  log_level=$1
  shift
  log_msg=$(printf '%s' "$*" | LC_ALL=C tr -c ' -~' '?')
  printf '%s tinycloud-gateway %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$log_level" "$log_msg"
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
valid_role() {
  case $1 in
    anchor|contributor|partial|reader) return 0 ;;
  esac
  return 1
}

valid_port() { valid "$1" '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

detect_os() {
  if [ ! -r "$GW_OS_RELEASE" ]; then
    return 1
  fi
  os_id=$(sed -n 's/^ID=//p' "$GW_OS_RELEASE" | head -n 1 | tr -d '"')
  os_version=$(sed -n 's/^VERSION_ID=//p' "$GW_OS_RELEASE" | head -n 1 | tr -d '"')
  os_codename=$(sed -n 's/^VERSION_CODENAME=//p' "$GW_OS_RELEASE" | head -n 1 | tr -d '"')
  os_ubuntu_codename=$(sed -n 's/^UBUNTU_CODENAME=//p' "$GW_OS_RELEASE" | head -n 1 | tr -d '"')
  if [ "$os_id" = ubuntu ] && [ -n "$os_ubuntu_codename" ]; then
    os_codename=$os_ubuntu_codename
  fi
  [ -n "$os_id" ]
}

os_supported() {
  [ -n "$os_version" ] && [ -n "$os_codename" ] || return 1
  case $os_id in
    debian)
      os_major=${os_version%%.*}
      valid "$os_major" '^[0-9]{1,3}$' && [ "$os_major" -ge 12 ]
      ;;
    ubuntu)
      os_num=$(printf '%s' "$os_version" | tr -d '.')
      valid "$os_num" '^[0-9]{4}$' && [ "$os_num" -ge 2204 ]
      ;;
    *) return 1 ;;
  esac
}

has_ssh_key() {
  if [ -s "${GW_ROOT_HOME:-/root}/.ssh/authorized_keys" ]; then
    return 0
  fi
  if [ -n "${SUDO_USER:-}" ] && [ -s "/home/$SUDO_USER/.ssh/authorized_keys" ]; then
    return 0
  fi
  return 1
}

gen_token() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

find_id() {
  printf '%s' "$1" | grep -Eo '[A-Z2-7]{7}(-[A-Z2-7]{7}){7}' | head -n 1
}

sha256_text() {
  if command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
  fi
}

verify_code() {
  sha256_text "$1" | cut -c 1-6 | tr '[:lower:]' '[:upper:]'
}

st_key() {
  sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$GW_ST_CONFIG" 2> /dev/null | head -n 1
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
        -H 'Content-Type: application/json' --data "$api_body" "$GW_ST_URL$api_path"
  else
    printf 'header = "X-API-Key: %s"\n' "$api_key" |
      curl -sS --fail --connect-timeout 5 --max-time 15 -K - -X "$api_method" "$GW_ST_URL$api_path"
  fi
}

st_wait() {
  sw_n=0
  while [ "$sw_n" -lt "${1:-60}" ]; do
    if st_api GET /rest/system/ping > /dev/null 2>&1; then
      return 0
    fi
    sw_n=$((sw_n + 1))
    sleep 1
  done
  log ERROR "syncthing api not reachable"
  return 1
}

write_atomic() {
  printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

put_device() {
  pd_defaults=$(st_api GET /rest/config/defaults/device) || return 1
  pd_body=$(printf '%s' "$pd_defaults" | jq -c --arg id "$1" --arg name "$2" --argjson addr "$3" \
    '. * {deviceID: $id, name: $name, addresses: $addr, compression: "metadata", introducer: false, autoAcceptFolders: false, paused: false, untrusted: false}')
  st_api PUT "/rest/config/devices/$1" "$pd_body" > /dev/null
}

put_folder() {
  pf_defaults=$(st_api GET /rest/config/defaults/folder) || return 1
  pf_body=$(printf '%s' "$pf_defaults" | jq -c --arg id "$1" --arg label "$2" --arg path "$3" --arg type "$4" \
    --argjson devices "$5" \
    '. * {id: $id, label: $label, path: $path, type: $type, devices: $devices, rescanIntervalS: 3600, fsWatcherEnabled: true, fsWatcherDelayS: 10}')
  st_api PUT "/rest/config/folders/$1" "$pf_body" > /dev/null
}
