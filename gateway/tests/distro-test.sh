#!/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
failed=0

if ! docker info > /dev/null 2>&1; then
  echo "docker is not installed or not running"
  exit 1
fi

for image in debian:12 debian:13 ubuntu:22.04 ubuntu:24.04; do
  printf '%s: ' "$image"
  if docker run --rm -v "$ROOT:/gw:ro" "$image" sh /gw/gateway.sh --dry-run --host gw.example.com 2>&1 | tail -n 1 | grep -q "dry run finished"; then
    echo ok
  else
    echo FAIL
    failed=1
  fi
done

exit "$failed"
