# TinyCloud Phase 1 design

Scope: approval, peer discovery, and status collection. Everything else follows the project brief.

## 1. Components

| Part | Runs on | What it is |
|---|---|---|
| Syncthing | every node and the gateway | file sync, API on localhost only |
| strelaysrv | gateway | relay, token protected, public pool disabled |
| stdiscosrv | gateway | discovery for the cloud only |
| agent | every node | small shell script run by a systemd timer, talks only to local Syncthing |
| aggregator | gateway | small shell script run by a systemd timer, builds status views |
| tinycloud CLI | gateway (and node for doctor, leave, update) | approve, remove, map, backup |

The gateway Syncthing device holds no library. It carries only the tiny folders below.

## 2. Syncthing folders

| Folder ID | Who sends | Who receives | Contents |
|---|---|---|---|
| tinycloud-library | anchors, contributors | everyone except where noted | the ebooks |
| tinycloud-peers | gateway (send only) | every node (receive only) | peers.json |
| tc-status-NAME | node NAME (send only) | gateway (receive only) | status.json for that node |
| tc-view-OWNER | gateway (send only) | that owner's nodes only (receive only) | view.json for that owner |

Library folder settings by role:

| Role | Folder type | Extras |
|---|---|---|
| anchor | send and receive | staggered versioning, 30 days |
| contributor | send and receive | |
| partial node | send and receive | min free space, pull order |
| reader | receive only | default role |

All nodes: ignore list for `.DS_Store`, `Thumbs.db`, `._*`. Share folder mounted noexec. Auto accept of folders and devices is never enabled. Introducer is never enabled.

## 3. Network settings on a node

- Global discovery points only at the gateway discovery server.
- Local discovery off. NAT traversal off. Public relays off.
- Listen address is only the gateway relay URL, including the token.
- Gateway device address is the gateway host on the sync port.
- Peers have no fixed address. They are found through the gateway discovery server and reached through the gateway relay.
- Firewall allows outbound only to the gateway on the sync, relay, and discovery ports, plus DNS and NTP.

Gateway ports: sync 22000, relay 22067, discovery 8443, SSH. Relay status service and Syncthing GUI bound to localhost.

## 4. Join and approval flow

1. First boot: Syncthing generates the device ID. The agent adds the gateway device and the node's own status folder from tinycloud.conf.
2. The local status page shows the device ID, a QR code, and a short verification code. The code is the first 6 characters of the base32 SHA-256 of the device ID, so it can be recomputed from the ID.
3. The Join page builds one copy line: `NAME DEVICEID ROLE OWNER`. The person sends it to the cloud owner.
4. Owner runs `tinycloud approve "<line>"` on the gateway. The CLI:
   - validates every field strictly (see section 5)
   - recomputes and prints the verification code and asks the owner to compare it with what the person sees
   - on `y`: adds the device to the gateway Syncthing, shares `tc-status-NAME` receive only, shares `tc-view-OWNER`, adds the node to peers.json
5. Within one agent cycle every node applies the new peers.json. Each node adds the new device and shares the library with it. Both sides are defined locally, so nobody has to accept anything.
6. `tinycloud remove NAME` reverses all of step 4. Node agents drop the device on the next cycle.
7. `tinycloud leave` on a node removes the gateway and all peers from its Syncthing and stops the agent. Files stay on disk.

## 5. peers.json

```
{
  "version": 1,
  "generated": "2026-11-21T03:00:00Z",
  "peers": [
    {"name": "rocky", "id": "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH", "role": "anchor", "owner": "justin"}
  ]
}
```

Agent rules:

- Only the gateway can write this folder. Nodes receive only.
- Apply nothing if the file does not parse or `version` is unknown. An empty list is treated as a failure, not as remove everyone.
- `name` must match `^[a-z0-9-]{1,32}$`. `owner` the same. `role` must be one of anchor, contributor, partial, reader. `id` must match the Syncthing device ID format. More than 64 peers is rejected.
- Unknown fields are ignored.
- The agent changes exactly two things: the device list, and which devices the library folder is shared with. It never sets paths, folder types, addresses, or any other setting from this file.
- Reader to reader pairs are skipped. Everything else is shared.
- Devices that disappear from the list are removed. The gateway device is never removed.
- Optional per node setting `PEERS_CONFIRM=manual`: new peers wait on the local status page until the node owner confirms. Default is `auto`.

## 6. status.json from a node

```
{
  "v": 1,
  "name": "rocky",
  "role": "anchor",
  "version": "0.1.0",
  "percent_stored": 100,
  "free_bytes": 52000000000,
  "low_space": false,
  "case_conflicts": 0,
  "location": {"lat": 32.2, "lon": -110.9},
  "time": "2026-11-21T03:00:00Z"
}
```

- The agent checks every 15 minutes. It writes the file only if percent stored moved by 2 points or more, low space flipped, version changed, or 24 hours passed.
- `location` is optional, entered and rounded by the owner. Never derived from an IP.
- The aggregator on the gateway accepts only these fields, checks types and ranges, clamps values, and drops anything else. A node can only describe itself.
- Online or offline is not read from this file. The aggregator reads connected devices from the gateway Syncthing API.

## 7. Views

The aggregator runs every minute. For each owner it writes `view.json` into `tc-view-OWNER`: that owner's nodes only, each with online flag, health fields, and last seen time. Only current status is kept, no history.

The owner of the gateway gets the full view over SSH through `tinycloud map`. All text in view.json is untrusted and the map page escapes everything.

## 8. Node agent loop

Runs as a systemd oneshot timer every 5 minutes. It never stays running, so it cannot hang.

1. Wait up to 30 seconds for the local Syncthing API, else exit non-zero.
2. If peers.json changed since last run, validate it and apply it.
3. Compute min free space: the larger of 10 percent of the disk and 1 GB, written as an absolute value.
4. Apply folder order from the config (default smallest first).
5. Every third run (15 minutes), build status and write it if the rules in section 6 say so.
6. Exit.

## 9. tinycloud.conf

```
NODE_NAME=rocky
OWNER=justin
ROLE=anchor
TIMEZONE=America/Phoenix
UPDATE_HOUR=3
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
LOCATION=
PEERS_CONFIRM=auto
SMB_ENABLED=false
```

On Raspberry Pi and Orange Pi the file sits on the FAT partition named TINYCLOUD and is deleted after first boot. On Docker nodes it sits beside docker-compose.yml.

## 10. Proposed change to the brief

The local status page needs inbound TCP 80 from the LAN only (read only, static, no secrets, no config). The brief says inbound is blocked except optional SSH, SFTP, and SMB. I propose adding this one rule. Docker nodes serve the page on localhost.

## 11. Logging and debug

What is logged:

| Source | What | Notes |
|---|---|---|
| node agent | one line per run with the result, one line per action | peer added or removed, peers.json rejected and why, status written, Syncthing API wait timed out |
| Syncthing, relay, discovery | container logs to journald at the default level | |
| gateway audit | one line per approve, remove, and backup | time, node name, device ID |
| gateway aggregator | one line per node online or offline change | for troubleshooting only, not shown on the map |

Rules for every log line:

- The first line of each run includes the script version.
- Never log tokens, passwords, the Syncthing API key, or the contents of tinycloud.conf.
- Everything the agent logs from peers.json, status files, or approve lines is treated as untrusted text and printed escaped.

Where logs live:

| Machine | Storage | Cap |
|---|---|---|
| gateway | persistent journald, plus the audit file | 500 MB and 30 days |
| node | journald in RAM (log2ram) | 50 MB |
| node | errors-only file on disk, rotated | 1 MB |

The errors-only file survives a reboot or power loss, which is when many problems start. It writes very little, so it is safe for an SD card.

Debug and support commands:

- `tinycloud logs [agent|syncthing|relay|discovery]` shows recent lines with times in 12-hour format.
- `tinycloud debug on` turns on Syncthing connection, discovery, and relay debug facets for 30 minutes, then turns them off by itself. `tinycloud debug off` ends it early.
- `tinycloud doctor` includes the most recent errors it found in the logs.
- `tinycloud support` writes one text bundle to paste into a chat: doctor output, the last 500 log lines, component versions, and tinycloud.conf with secrets removed. It contains no IP addresses.

## 12. Discord bot (optional, Phase 5)

A small read-only bot that reports health problems and answers status questions. It lives in `apps/discord-bot/`, is off by default, and is not part of the core shell scripts. Each owner runs their own bot with their own Discord application.

What it can see:

- Justin's bot runs on the gateway and reads the full `view.json`.
- Finn's bot runs on his Linode and reads only `view-finn.json`, which already syncs to his nodes.
- The container gets that one file mounted read-only. It has no Syncthing API key, no SSH key, and no `tinycloud` CLI. A stolen bot token can post messages and read status, nothing else.

Commands (replies visible only to the person who asked):

| Command | Result |
|---|---|
| `/status` | gateway up, nodes online out of total, whether a complete node is online, open warnings |
| `/nodes` | each node with online or offline, role, percent stored, free space, version, last seen |
| `/node <name>` | details for one node, including case-conflict warnings |

Health alerts, posted to the `#tinycloud` channel:

| Condition | Default |
|---|---|
| node offline | 48 hours |
| node low on space | as soon as the node reports it |
| no complete node online | 1 hour |
| node on an old version | as soon as seen |
| filename case conflicts on a node | as soon as the node reports it |
| view file stale (Finn's bot only) | 10 minutes, means the gateway is probably down |

Alert behavior:

- Silent while healthy.
- One message when a problem starts, one when it clears, and one reminder each day at 9:00 AM while it is still open.
- Reports only the nodes in the bot's own view.
- The bot remembers what it already reported in its own small state file, the only thing it can write.

Config, in the bot's own file (`bot.conf`, never in tinycloud.conf):

```
DISCORD_APP_ID=
DISCORD_TOKEN_FILE=/run/secrets/discord_token
DISCORD_CHANNEL_ID=
DISCORD_ALLOWED_USER_IDS=
VIEW_FILE=/data/view.json
ALERT_OFFLINE_HOURS=48
ALERT_NO_COMPLETE_HOURS=1
STALE_MINUTES=10
REMINDER_HOUR=9
```

Security and limits:

- The App ID is public and only registers the slash commands. The bot token is the secret. It lives in a root-only file on the host, never in the repo, never on a node, and is never logged.
- Commands work only for the allowed Discord user IDs, and only in the configured channel.
- The bot connects outbound to Discord, so no port is opened.
- Everything shown in Discord (node names, status fields) is untrusted text and is escaped.
- Bot permissions are the minimum: view channel and send messages.
- Discord sees node names and online status, never IP addresses.
- Your bot goes silent if the gateway dies. Finn's bot reports the stale view, and a free external uptime check can be added later.
- The webhook or ntfy alerts stay available for anyone who does not run the bot.
- The bot is a small Python container, roughly 50 to 80 MB of RAM (an estimate, to verify), kept short enough for Finn to read.

## 13. Known limits

- A compromised or malicious gateway owner can add a device ID that then receives the library. Every node already trusts the gateway for this. `PEERS_CONFIRM=manual` removes that for a node owner who wants it.
- The relay carries all sync traffic, so the Nanode's monthly transfer cap and one CPU are the ceiling.
- Admins and anchors can read the data.
- Syncthing is the main attack surface, so keep it updated.

## 14. To verify while building Phase 1

- A node with the firewall allowing only the gateway ports can still sync with another node through the relay.
- Relay token works through the listen address URL on the current Syncthing release.
- Discovery server certificate is verified using the device ID in the discovery URL.
- Nodes on the same LAN do not announce or try direct addresses.
- Order and min free space settings behave as expected on a nearly full card.
- Gateway RAM use with relay, discovery, one Syncthing device, and 10 status folders on 1 GB.
- Agent handles a Syncthing restart in the middle of a run.
- No secret appears in any log or in the support bundle.
- Debug mode turns itself off after 30 minutes, even if the node reboots.
- Log sizes stay under their caps after a week of normal use.
- Phase 5: the bot's real RAM use on the Nanode, and that it never needs more than the one mounted view file.
- Everything above on both Debian and Ubuntu Linodes.

## 15. Phase 1 build order

1. Node container stack: Syncthing, status page, agent, nftables rules, doctor.
2. Docker node compose file and tinycloud.conf.
3. Gateway compose file (relay, discovery, Syncthing) and aggregator, tested by hand.
4. Approval CLI.
5. End to end test with rocky, grace, and Finn's Linode as a Docker node.
