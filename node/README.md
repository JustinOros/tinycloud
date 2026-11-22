# TinyCloud node

## Run a node

On a Debian 12+ or Ubuntu 22.04+ machine, run:

```
curl -fsSL https://raw.githubusercontent.com/JustinOros/tinycloud/main/setup-node.sh -o setup-node.sh && sh setup-node.sh
```

It asks for a node name, owner, and role, then for the five lines the gateway owner gives you (`tinycloud-gw config` on the gateway prints them). It installs Docker if needed, starts the node, and prints one line. Send that line to the gateway owner. They run it, read the code back to you, and your node starts syncing.

Your files live in `data/library`, and the setup makes a shortcut named `tinycloud` in your home folder. Copy files in from another machine with `scp book.epub NODE:tinycloud/`. Check on things with `tinycloud doctor`.

## Files


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
| `agent/join.sh` | prints the line to send to the gateway owner |
| `agent/confirm.sh` | confirms new peers in manual mode |
| `agent/leave.sh` | leaves the cloud, keeps the files |
| `agent/relay.sh` | applies a new relay token |
| `bin/tinycloud` | the command people type: doctor, logs, debug, support, join, path, confirm, relay-token, leave |
| `firewall/` | nftables rules and the script that loads them |
| `docker-compose.yml` | Syncthing and the agent, no published ports |
| `tinycloud.conf.example` | all config keys |
| `tests/run.sh` | runs all tests and shellcheck |

## Test

```
sh tests/run.sh
```

Needs `sh`, `jq`, and optionally `shellcheck`.
