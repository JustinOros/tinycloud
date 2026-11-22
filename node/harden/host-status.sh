#!/bin/sh
HOST_DIR=${TC_HOST_DIR:-$(cd "$(dirname "$0")/.." && pwd)/host}
REBOOT_FLAG=${TC_REBOOT_FLAG_SRC:-/var/run/reboot-required}
UPTIME_FILE=${TC_UPTIME_FILE:-/proc/uptime}

mkdir -p "$HOST_DIR" || exit 1
file=$HOST_DIR/reboot_required
if [ ! -e "$REBOOT_FLAG" ]; then
  rm -f "$file"
  exit 0
fi
now=$(date +%s)
up=$(cut -d . -f 1 "$UPTIME_FILE" 2> /dev/null)
case $up in
  '' | *[!0-9]*) up=0 ;;
esac
boot=$((now - up))
since=$(cat "$file" 2> /dev/null)
case $since in
  '' | *[!0-9]*) since=0 ;;
esac
if [ "$since" -le "$boot" ]; then
  printf '%s\n' "$now" > "$file"
fi
