TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" != "$3" ]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

assert_contains() {
  TESTS_RUN=$((TESTS_RUN + 1))
  case $2 in
    *"$3"*) ;;
    *)
      TESTS_FAILED=$((TESTS_FAILED + 1))
      printf 'FAIL %s\n  missing: %s\n' "$1" "$3"
      ;;
  esac
}

assert_not_contains() {
  TESTS_RUN=$((TESTS_RUN + 1))
  case $2 in
    *"$3"*)
      TESTS_FAILED=$((TESTS_FAILED + 1))
      printf 'FAIL %s\n  found: %s\n' "$1" "$3"
      ;;
  esac
}

assert_jq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if ! printf '%s' "$2" | jq -e "$3" > /dev/null 2>&1; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s\n  jq check failed: %s\n  on: %s\n' "$1" "$3" "$2"
  fi
}

finish() {
  printf '%s: %s checks, %s failed\n' "$(basename "$0")" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}

conf_set() {
  grep -v "^$2=" "$1" > "$1.new"
  printf '%s=%s\n' "$2" "$3" >> "$1.new"
  mv "$1.new" "$1"
}

mkid() {
  mk_g="$1$1$1$1$1$1$1"
  printf '%s-%s-%s-%s-%s-%s-%s-%s' "$mk_g" "$mk_g" "$mk_g" "$mk_g" "$mk_g" "$mk_g" "$mk_g" "$mk_g"
}

new_sandbox() {
  SANDBOX=$(mktemp -d)
  TC_STATE_DIR=$SANDBOX/state
  TC_LOG_DIR=$SANDBOX/logs
  TC_LIBRARY_DIR=$SANDBOX/data/library
  TC_SYSTEM_DIR=$SANDBOX/data/system
  TC_CONF=$SANDBOX/tinycloud.conf
  TC_ST_CONFIG=$SANDBOX/config.xml
  FAKE_DIR=$SANDBOX/fake
  mkdir -p "$TC_STATE_DIR" "$TC_LOG_DIR" "$TC_LIBRARY_DIR" "$TC_SYSTEM_DIR/peers" "$FAKE_DIR"
  : > "$FAKE_DIR/calls"
  printf '{"state":"idle","globalBytes":1000,"localBytes":500,"pullErrors":0}' > "$FAKE_DIR/dbstatus.json"
  printf '{"connections":{}}' > "$FAKE_DIR/connections.json"
  printf '[{"id":"tc-lib-justin"},{"id":"tinycloud-peers"}]' > "$FAKE_DIR/folders.json"
  FAKE_FAIL=
  FAKE_RESTART=false
  PEERS_FILE=$TC_SYSTEM_DIR/peers/peers.json
}

fake_st_api() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FAKE_DIR/calls"
  if [ -n "${FAKE_FAIL:-}" ]; then
    case "$1 $2" in
      *"$FAKE_FAIL"*) return 1 ;;
    esac
  fi
  case "$1 $2" in
    "GET /rest/system/ping") printf '{"ping":"pong"}' ;;
    "GET /rest/system/status") printf '{"myID":"%s"}' "$FAKE_MY_ID" ;;
    "GET /rest/config/restart-required") printf '{"requiresRestart":%s}' "$FAKE_RESTART" ;;
    "GET /rest/config/defaults/folder")
      printf '{"id":"","label":"","path":"","type":"sendreceive","devices":[],"order":"random","rescanIntervalS":3600,"minDiskFree":{"value":1,"unit":"%%"},"versioning":{"type":"","params":{}}}'
      ;;
    "GET /rest/config/defaults/device")
      printf '{"deviceID":"","name":"","addresses":["dynamic"],"compression":"metadata","introducer":false,"autoAcceptFolders":false,"paused":false,"untrusted":false}'
      ;;
    "GET /rest/config/folders") cat "$FAKE_DIR/folders.json" ;;
    "GET /rest/config/folders/tinycloud-library")
      [ -f "$FAKE_DIR/legacy.json" ] || return 1
      cat "$FAKE_DIR/legacy.json"
      ;;
    "GET /rest/config/folders/tc-lib-"*)
      [ -f "$FAKE_DIR/folder-${2##*/tc-lib-}.json" ] || return 1
      cat "$FAKE_DIR/folder-${2##*/tc-lib-}.json"
      ;;
    "GET /rest/db/status?folder=tc-lib-"*) cat "$FAKE_DIR/dbstatus.json" ;;
    "GET /rest/system/connections") cat "$FAKE_DIR/connections.json" ;;
  esac
  return 0
}

body_of() {
  awk -v k="$1" 'index($0, k " ") == 1 {print substr($0, length(k) + 2)}' "$FAKE_DIR/calls" | tail -n 1
}

count_calls() {
  grep -c "^$1" "$FAKE_DIR/calls" || true
}
