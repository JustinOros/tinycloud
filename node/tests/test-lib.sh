#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TC_ROOT=$(cd "$HERE/.." && pwd)
export TC_ROOT
TC_SOURCED=1
. "$HERE/harness.sh"
. "$TC_ROOT/agent/lib.sh"

new_sandbox

assert_eq "name ok" 0 "$(valid_name rocky-1 && echo 0 || echo 1)"
assert_eq "name upper rejected" 1 "$(valid_name Rocky && echo 0 || echo 1)"
assert_eq "name empty rejected" 1 "$(valid_name '' && echo 0 || echo 1)"
assert_eq "name too long rejected" 1 "$(valid_name aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && echo 0 || echo 1)"
assert_eq "name newline rejected" 1 "$(valid_name 'ok
bad' && echo 0 || echo 1)"
assert_eq "name space rejected" 1 "$(valid_name 'a b' && echo 0 || echo 1)"

assert_eq "device id ok" 0 "$(valid_device_id "$(mkid A)" && echo 0 || echo 1)"
assert_eq "device id short rejected" 1 "$(valid_device_id AAAAAAA-AAAAAAA && echo 0 || echo 1)"
assert_eq "device id bad chars rejected" 1 "$(valid_device_id "$(mkid 1)" && echo 0 || echo 1)"

assert_eq "int ok" 0 "$(valid_int 1073741824 && echo 0 || echo 1)"
assert_eq "10 digit int ok for disks over 1 TB" 0 "$(valid_int 2147483648 && echo 0 || echo 1)"
assert_eq "int with letters rejected" 1 "$(valid_int 12a && echo 0 || echo 1)"
assert_eq "huge int rejected" 1 "$(valid_int 1234567890123 && echo 0 || echo 1)"
assert_eq "role ok" 0 "$(valid_role anchor && echo 0 || echo 1)"
assert_eq "role bad" 1 "$(valid_role admin && echo 0 || echo 1)"
assert_eq "order ok" 0 "$(valid_order smallestFirst && echo 0 || echo 1)"
assert_eq "order bad" 1 "$(valid_order whatever && echo 0 || echo 1)"
assert_eq "host ok" 0 "$(valid_host gw.example.com && echo 0 || echo 1)"
assert_eq "host with slash rejected" 1 "$(valid_host 'gw.example.com/x' && echo 0 || echo 1)"
assert_eq "token ok" 0 "$(valid_token abc_DEF-123 && echo 0 || echo 1)"
assert_eq "token with ampersand rejected" 1 "$(valid_token 'a&b' && echo 0 || echo 1)"

assert_eq "min free uses percent when larger" 20480 "$(calc_min_free_mb 209715200 10 1)"
assert_eq "min free uses floor when larger" 1024 "$(calc_min_free_mb 1000000 10 1)"

printf 'NODE_NAME=rocky\nROLE=anchor\r\nEMPTY=\n' > "$TC_CONF"
assert_eq "conf_get value" rocky "$(conf_get NODE_NAME)"
assert_eq "conf_get strips CR" anchor "$(conf_get ROLE)"
assert_eq "conf_get default" fallback "$(conf_get MISSING fallback)"
assert_eq "conf_get empty uses default" fallback "$(conf_get EMPTY fallback)"

out=$(log INFO "hello
world")
assert_contains "log has version" "$out" "tinycloud-agent $TC_VERSION INFO hello?world"

log INFO "quiet" > /dev/null
assert_eq "info not in error file" 0 "$(test -f "$TC_LOG_DIR/errors.log" && echo 1 || echo 0)"
log ERROR "bad thing" > /dev/null
assert_contains "error in error file" "$(cat "$TC_LOG_DIR/errors.log")" "ERROR bad thing"

head -c 1100000 /dev/zero | tr '\0' 'x' > "$TC_LOG_DIR/errors.log"
log WARN "after rotate" > /dev/null
assert_eq "rotated file exists" 1 "$(test -f "$TC_LOG_DIR/errors.log.1" && echo 1 || echo 0)"
assert_contains "new file has line" "$(cat "$TC_LOG_DIR/errors.log")" "WARN after rotate"

assert_eq "sha256 of abc" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(sha256_text abc)"
assert_eq "verification code is 6 upper case characters" BA7816 "$(verify_code abc)"
assert_eq "tz ok" 0 "$(valid_tz America/Phoenix && echo 0 || echo 1)"
assert_eq "tz with space rejected" 1 "$(valid_tz 'Bad Zone' && echo 0 || echo 1)"
printf 'hello' > "$SANDBOX/h"
assert_eq "sha256 of file" 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824 "$(sha256 "$SANDBOX/h")"

write_atomic "$SANDBOX/x" "value"
assert_eq "write_atomic" value "$(cat "$SANDBOX/x")"
assert_eq "read_state missing" "" "$(read_state nothing)"

finish
