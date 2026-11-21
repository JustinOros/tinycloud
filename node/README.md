# TinyCloud node

## Run a node

On any machine with Docker and the `docker compose` plugin:

```
git clone https://github.com/JustinOros/tinycloud.git
cd tinycloud/node
cp tinycloud.conf.example tinycloud.conf
```

Edit `tinycloud.conf`. Set `NODE_NAME`, `OWNER`, `ROLE`, and paste in the five lines the gateway owner gives you (`tinycloud-gw config` on the gateway prints them). Then:

```
docker compose up -d --build
./bin/tinycloud join
```

`join` prints one line and a short code. Send the line to the gateway owner. They run it, read the code back to you, and your node starts syncing.

Your files live in `data/library`. Check on things with `./bin/tinycloud doctor`.

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
| `bin/tinycloud` | the command people type: doctor, logs, debug, support, join, confirm, leave |
| `firewall/` | nftables rules and the script that loads them |
| `docker-compose.yml` | Syncthing and the agent, no published ports |
| `tinycloud.conf.example` | all config keys |
| `tests/run.sh` | runs all tests and shellcheck |

## Test

```
sh tests/run.sh
```

Needs `sh`, `jq`, and optionally `shellcheck`.
