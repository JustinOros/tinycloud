# TinyCloud node

Scripts that run inside the agent container.

| File | Job |
|---|---|
| `agent/lib.sh` | shared helpers: logging, checks, Syncthing API |
| `agent/firstboot.sh` | one time setup from `tinycloud.conf` |
| `agent/apply-peers.sh` | reads `peers.json`, adds or removes peers |
| `tests/run.sh` | runs all tests and shellcheck |

## Test

```
sh tests/run.sh
```

Needs `sh`, `jq`, and optionally `shellcheck`.
