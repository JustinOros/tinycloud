#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(cd "$HERE/.." && pwd)
. "$HERE/harness.sh"
. "$GW/lib.sh"

check_os_file() {
  GW_OS_RELEASE=$HERE/fixtures/$1
  if detect_os && os_supported; then
    echo yes
  else
    echo no
  fi
}

assert_eq "debian 12 supported" yes "$(check_os_file debian12)"
assert_eq "debian 13 supported" yes "$(check_os_file debian13)"
assert_eq "debian 11 rejected" no "$(check_os_file debian11)"
assert_eq "ubuntu 22.04 supported" yes "$(check_os_file ubuntu2204)"
assert_eq "ubuntu 24.04 supported" yes "$(check_os_file ubuntu2404)"
assert_eq "ubuntu 20.04 rejected" no "$(check_os_file ubuntu2004)"
assert_eq "fedora rejected" no "$(check_os_file fedora)"
assert_eq "mint rejected" no "$(check_os_file mint)"
GW_OS_RELEASE=$HERE/fixtures/missing
assert_eq "missing os-release" 1 "$(detect_os && echo 0 || echo 1)"

GW_OS_RELEASE=$HERE/fixtures/ubuntu2404
detect_os
assert_eq "ubuntu codename" noble "$os_codename"
GW_OS_RELEASE=$HERE/fixtures/debian12
detect_os
assert_eq "debian codename" bookworm "$os_codename"

assert_eq "valid host" 0 "$(valid_host gw.example.com && echo 0 || echo 1)"
assert_eq "bad host" 1 "$(valid_host 'bad/host' && echo 0 || echo 1)"
assert_eq "newline host" 1 "$(valid_host 'a
b' && echo 0 || echo 1)"
assert_eq "valid port" 0 "$(valid_port 2222 && echo 0 || echo 1)"
assert_eq "port zero" 1 "$(valid_port 0 && echo 0 || echo 1)"
assert_eq "port too big" 1 "$(valid_port 70000 && echo 0 || echo 1)"
assert_eq "port text" 1 "$(valid_port 22a && echo 0 || echo 1)"

id=$(mkid A)
assert_eq "valid device id" 0 "$(valid_device_id "$id" && echo 0 || echo 1)"
assert_eq "lowercase id rejected" 1 "$(valid_device_id "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" && echo 0 || echo 1)"
assert_eq "find id in log" "$id" "$(find_id "2026 relay started URI: relay://x:22067/?id=$id&token=t")"
assert_eq "find id none" "" "$(find_id "nothing here")"

t=$(gen_token)
assert_eq "token length" 32 "${#t}"
assert_eq "token valid" 0 "$(valid_token "$t" && echo 0 || echo 1)"
assert_eq "tokens differ" 1 "$([ "$t" = "$(gen_token)" ] && echo 0 || echo 1)"

code=$(verify_code "$id")
assert_eq "verify code length" 6 "${#code}"
assert_eq "verify code upper" "$(verify_code "$id")" "$(verify_code "$id" | tr '[:lower:]' '[:upper:]')"

assert_eq "valid role" 0 "$(valid_role anchor && echo 0 || echo 1)"
assert_eq "bad role" 1 "$(valid_role boss && echo 0 || echo 1)"

finish
