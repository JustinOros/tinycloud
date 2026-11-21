#!/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
failed=0

for t in "$HERE"/test-*.sh; do
  sh "$t" || failed=1
done

if command -v shellcheck > /dev/null 2>&1; then
  shellcheck -x -s sh "$ROOT"/*.sh "$ROOT"/../setup.sh "$ROOT"/../setup-node.sh "$ROOT"/bin/* "$HERE"/*.sh || failed=1
else
  echo "shellcheck not installed, skipped"
fi

if [ "$failed" -eq 0 ]; then
  echo "all good"
else
  echo "failures found"
fi
exit "$failed"
