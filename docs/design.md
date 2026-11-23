# TinyCloud design

A private file cloud for trusted friends. Nodes sync your shared files through a gateway. More gateways can be added later. Nobody controls anyone else's node.

## Parts

| Part | Node | Gateway | PC | Job |
|---|---|---|---|---|
| Syncthing | ✓ | ✓ | | syncs files |
| Relay and discovery | | ✓ | | lets nodes find and reach each other |
| Agent | ✓ | | | small script, talks only to its own Syncthing |
| Aggregator | | ✓ | | `tinycloud-gw aggregate` builds the status views every 5 minutes |
| `tinycloud` command | ✓ | | | doctor, logs, debug, support, join, path, confirm, leave |
| `tinycloud-gw` command | | ✓ | | approve, remove, list, status, alert, config, aggregate, view, backup, restore |
| `setup-node.sh` | ✓ | | | installs the node, then sets up updates, firewall, and SSH hardening |
| `flash-sd.sh` | | | ✓ | writes an Armbian image to a card with a first-boot preset |
| `tinycloud-dashboard` | | | ✓ | shows the status table, or a page with `--web` |

PC means the owner's own computer, such as a Mac.

The gateway never stores the library. Anchor nodes hold full copies.

## Node roles

| Role | Does |
|---|---|
| anchor | always on, full copy, 30 day versioning |
| contributor | sends and receives |
| partial | stores what fits |
| reader | receives only (default) |

## Folders

| Folder | Direction | Holds |
|---|---|---|
| `tinycloud-library` | between nodes | your shared files |
| `tinycloud-peers` | gateway to nodes | `peers.json` |
| `tc-status-NAME` | node to gateway | that node's status |
| `tc-view-OWNER` | gateway to that owner's nodes | what that owner may see |

Nobody ever auto-accepts a folder or a device. The introducer feature is never used.

## Network

- Nodes talk only to the gateway: sync, relay, and discovery ports, plus DNS and NTP.
- Local discovery, NAT, and public relays are off.
- The relay needs a token, so only our nodes can use it.
- Syncthing's web page and API are never exposed.
- Pi images run an nftables firewall: default deny, outbound only to the gateway, DNS, and NTP. IPv6 is blocked in v1.
- `setup-node.sh` can add a host firewall: inbound is dropped except the status page and SSH from the LAN, and Docker published ports are closed to anything outside the LAN. Outbound is not limited.
- Pi images allow SMB only if the owner turns it on.

## Host security and updates

- Setup asks about each of these, and a plain `--yes` leaves them alone.
- Debian security updates install automatically. Reboots happen only at the chosen time, and only when an update needs one.
- Armbian kernel and firmware are never auto-updated, because a bad kernel can stop a board from booting.
- If a reboot has been pending for 36 hours, the node reports it and the dashboard shows "Reboot needed".
- SSH allows keys only once an `authorized_keys` file exists, limits login attempts, and fail2ban bans repeat offenders.
- A nightly timer updates TinyCloud itself from the `stable` branch (default), from `main` (testing), or not at all.
- An update that leaves Syncthing, the agent or the web page unhealthy is rolled back from a saved copy.
- Publish a release with `git push origin main:stable`.
- The gateway asks the same reboot question during `setup.sh` (default yes, at 4:00 AM), and which time zone the server uses, because reboots and the daily alert reminder follow its clock. If it does not reboot automatically, an alert says when a reboot has been waiting too long.

## Joining

1. The node makes its own ID on first boot. `tinycloud join` prints one line and a short code. The local status page shows them too, with a QR. The code is the first 6 characters of the SHA-256 of the device ID.
2. The person sends the owner the line: `tinycloud-gw approve NAME DEVICEID ROLE OWNER`.
3. The owner runs `tinycloud-gw approve NAME DEVICEID ROLE OWNER` on the gateway. It prints the code to compare with the person.
4. Every node picks up the new peer on its next check. Nothing to accept.
5. `tinycloud-gw remove NAME` undoes it. `tinycloud leave` on a node leaves.

## peers.json

The gateway writes it. Nodes only read it.

An agent applies it only if every entry is valid:

- version 1, 1 to 64 peers, no duplicate IDs or names
- name and owner: lowercase letters, digits, dashes, 32 characters max
- role: anchor, contributor, partial, or reader
- device ID in the Syncthing format

Anything else rejects the whole file. Unknown fields are ignored.

The agent changes two things only: which devices exist, and which devices get the library. Readers skip other readers.

Optional: `PEERS_CONFIRM=manual` makes the node's owner confirm each new peer first.

## Status

- Each node reports a tiny `status.json`: role, version, percent stored, free space, low space, case conflicts, when the node container started (the dashboard turns it into uptime), and whether a reboot has been pending for more than 36 hours.
- It is written only when percent stored moves 2 points or more, low space flips, the version or role changes, case conflicts change, or once a day.
- Low space means free space is under 1.5 times the free space floor.
- Online or offline comes from the gateway, not from this file.
- The gateway keeps only known fields and checks them.
- Everyone sees only their own nodes. The gateway owner sees all.
- Current status only. No history.

## Storage

- Free space floor: 10 percent or 1 GB, whichever is larger.
- Pull order: smallest first (changeable).
- Ignored files: `.DS_Store`, `Thumbs.db`, `._*`.

## Agent

Runs every 5 minutes, then exits. It never hangs.

1. Wait for Syncthing.
2. Apply `peers.json` if it changed.
3. Check status every third run (about every 15 minutes) and write it if it needs to.

## Config

One file, `tinycloud.conf`, with `KEY=value` lines.

```
NODE_NAME=rocky
OWNER=justin
ROLE=anchor
TIMEZONE=America/Phoenix
GATEWAY_HOST=gateway.example.com
GATEWAY_ID=AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH
RELAY_ID=AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH
DISCOVERY_ID=AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH
RELAY_TOKEN=changeme
SSH_PUBLIC_KEY=ssh-ed25519 AAAA...
WIFI_SSID=
WIFI_PASSWORD=
STATIC_IP=
FREE_SPACE_PERCENT=10
FREE_SPACE_MIN_GB=1
PULL_ORDER=smallestFirst
PEERS_CONFIRM=auto
SMB_ENABLED=false
```

Pi images keep it on the FAT partition named TINYCLOUD and delete it after first boot. Docker nodes keep it next to `docker-compose.yml`. `setup-node.sh` puts it in `/opt/tinycloud-node`. The update, reboot, and channel choices from setup are kept in the system's own files, not here. Run setup again to change them.

## Logs and debug

- Every log line starts with the script version.
- Secrets never appear in logs or in the support bundle.
- Gateway: logs kept 30 days (500 MB cap), plus an audit line for every approve, remove, and backup.
- Node: logs live in RAM (50 MB cap), plus a 1 MB errors-only file on disk that survives reboots.
- `tinycloud logs` shows recent lines.
- `tinycloud debug on` turns on extra Syncthing logging for 30 minutes, then off.
- `tinycloud support` makes one text bundle to paste in a chat. No secrets, no IPs.
- `tinycloud confirm` lists and confirms new peers (manual mode only).
- `tinycloud leave` leaves the cloud. Files stay on the node.

## Adding files

Every node has a shortcut named `tinycloud` in its owner's home folder, pointing at the library. From another machine: `scp book.epub NODE:tinycloud/`. `tinycloud path` prints the real location.

## Local status page

Each node serves a read-only page: connection state, space, warnings, and (until connected) the join line, code, and QR. It holds no secrets and no config. It refreshes every minute.

- Pi images: LAN only, port 80. This is the one inbound rule added to the brief.
- Docker nodes: `127.0.0.1:8080` by default (`TC_STATUS_BIND` changes it).

Docker containers are named `tinycloud-syncthing`, `tinycloud-agent`, `tinycloud-web`, and `tinycloud-init`. To run a second node on the same host, use its own folder, set `TC_PREFIX` to a different name, and set a different `TC_STATUS_BIND` port.

## Discord bot (optional, off by default)

Phase 5. Read-only. Lives in `apps/discord-bot/`. Each owner runs their own.

- Commands: `/status`, `/nodes`, `/node NAME`
- Alerts to `#tinycloud`, once per problem, one reminder a day at 9:00 AM:
  - node offline 48 hours
  - node low on space
  - no full copy online for 1 hour
  - old version or case conflicts
  - gateway looks down (Finn's bot, view older than 10 minutes)
- It reads one mounted `view.json`. No Syncthing key, no SSH, no CLI.
- A stolen bot token can only read status.
- Only allowed Discord user IDs, one channel, no open port.
- Webhook or ntfy alerts still work without it.

## Alerts

The gateway can tell you when something is wrong. It sends one message to a Discord webhook or an ntfy topic. There is no bot and no open port.

- Turn it on with `tinycloud-gw alert set url ADDRESS`, then check it with `tinycloud-gw alert test`. With no address, alerts are off.
- It runs after every status build and reads the same view the dashboard shows.
- One message when a problem starts, one when it is resolved, and one reminder a day at 9:00 AM while it is still open. Problems that start together share a message.
- Every wait time is yours to set, in minutes, hours, or days, for example `tinycloud-gw alert set offline 5m`.

| Problem | Setting | Default wait |
|---|---|---|
| Node offline | `offline` | 2 hours |
| No status reported | `no-status` | 1 day 12 hours (at least 25 hours, nodes report daily) |
| Low on space | `low-space` | 30 minutes |
| File name conflicts | `conflicts` | 1 hour |
| Reboot needed | `reboot` | right away (the node already waits 36 hours) |
| Gateway needs a reboot | `gateway-reboot` | 1 day 12 hours |

- `reminder 9am` sets the reminder hour, or `off` turns reminders off. `recovered no` turns off the resolved messages.
- Status builds run every 5 minutes, so a wait shorter than that acts like 5 minutes.
- If a message cannot be sent, it is tried again on the next build.
- The address is a secret. It is stored in `alerts.conf` (mode 600), included in `tinycloud-gw backup`, and never shown in full or logged.
- A gateway that is down cannot report itself. For that, set `tinycloud-gw alert set heartbeat ADDRESS` to a dead-man's-switch address such as healthchecks.io. The gateway pings it after every status build, and that service tells you when the pings stop. Set its period to 10 minutes and its grace time to 5. The gateway only pings while Syncthing is answering.

## Dashboard

`tinycloud-dashboard USER@GATEWAY` runs on the gateway owner's computer. It prints a table made by `tinycloud-gw status` over SSH. With `--watch` it redraws every minute. With `--web` it fetches the full view (`tinycloud-gw view`), writes one self-contained HTML file, and opens it. Each friend sees only their own nodes. The page escapes all text.

The gateway builds the views every 5 minutes. For each approved node it reads that node's `status.json`, checks every field, and keeps only the known ones. Online or offline comes from Syncthing's connection list. The full view is `state/view.json`. Each owner's view is `view.json` in their `tc-view-OWNER` folder, which syncs to that owner's nodes.

A node shows a warning when it is offline, low on space, has name conflicts, has no status yet, or has not reported in 36 hours, or has needed a reboot for more than 36 hours.

## If the gateway goes down

- Sync stops for everyone. Nodes keep their files.
- Fix: build a new Linode, run `setup.sh`, restore the identity backup, and keep the same IP and hostname.
- `tinycloud-gw backup` saves the gateway identity (keys, IDs, relay token, approved list).

## Later: more than one gateway

- Each owner runs a gateway on their own Linode.
- Every node lists all gateways. One is preferred, the rest are failover.
- Which gateway a node uses and who owns it are separate. A node owned by justin can connect through finn's gateway.
- Each owner signs their own node list. Nodes accept justin's signature only for `OWNER=justin` and finn's only for `OWNER=finn`.
- Gateways are plain infrastructure: relay, discovery, sync. They cannot add devices.
- Adding a gateway needs one owner's signature on the gateway list.
- The library syncs to every node that its role allows.
- Not built yet. The single gateway comes first.

## Known limits

- A gateway owner can add a device that then gets the library. `PEERS_CONFIRM=manual` blocks that on a node.
- All sync goes through the Nanode relay, so its transfer cap and one CPU are the ceiling.
- Admins and anchors can read the data.
- Syncthing is the main attack surface. Keep it updated.

## Verified

- Sync works both ways through the relay, between a Docker node on Unraid and an Orange Pi on another network.
- The relay token works.
- `tinycloud-gw approve` works against a real Syncthing.
- The aggregator and dashboard work on the real gateway.
- A shared folder of epubs syncs from a Docker node on Unraid to an Orange Pi on another network.
- Offline and resolved alerts reach a real Discord webhook, with the wait time set by the owner.
- The heartbeat pings healthchecks.io, which posts to Discord.
- `tinycloud-gw backup` and `restore` work on a real server: a gateway identity restored onto a second Linode in another region matched the original, and restoring the second server's own backup put it back.

## Still to verify

- The firewall on a Pi, open only to the gateway.
- Nodes on the same LAN do not try direct connections.
- Min free space and pull order behave on a nearly full card.
- Gateway RAM stays fine on 1 GB.
- No secret in any log or support bundle.
- Alerts reach a real ntfy topic.
- The gateway reboot alert on a real server.
- A missed heartbeat reaches Discord.
- Everything works on Ubuntu as well as Debian.
- `tinycloud-gw remove` against a real Syncthing.
