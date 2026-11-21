#!/bin/sh
TC_ROOT=${TC_ROOT:-/app}

echo "tinycloud agent loop starting"
while true; do
  if ! sh "$TC_ROOT/agent/agent.sh"; then
    echo "agent run failed, exiting so the container restarts"
    sleep 30
    exit 1
  fi
  sleep "${TC_INTERVAL:-300}"
done
