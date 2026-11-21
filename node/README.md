# TinyCloud node

Scripts that run inside the agent container.

| File | Job |
|---|---|
| `agent/lib.sh` | shared helpers: logging, checks, Syncthing API |
| `agent/firstboot.sh` | one time setup from `tinycloud.conf` |
| `agent/apply-peers.sh` | reads `peers.json`, adds or removes peers |
| `agent/status.sh` | builds `status.json`, writes it only when it changed |
| `agent/agent.sh` | one agent run: first boot, peers, status |
| `agent/loop.sh` | runs the agent every 5 minutes, exits on failure |
| `agent/doctor.sh` | plain English health checks |
| `agent/render.sh` | builds the local status page |
| `agent/debug.sh` | extra Syncthing logging that turns itself off |
| `agent/confirm.sh` | confirms new peers in manual mode |
| `agent/leave.sh` | leaves the cloud, keeps the files |
| `bin/tinycloud` | the command people type: doctor, logs, debug, support, confirm, leave |
| `firewall/` | nftables rules and the script that loads them |
| `docker-compose.yml` | Syncthing and the agent, no published ports |
| `tinycloud.conf.example` | all config keys |
| `tests/run.sh` | runs all tests and shellcheck |

## Test

```
sh tests/run.sh
```

Needs `sh`, `jq`, and optionally `shellcheck`.
