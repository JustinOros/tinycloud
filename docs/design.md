# TinyCloud design

A private file cloud for trusted friends. Nodes sync one library through one small gateway. Nobody controls anyone else's node.

## Parts

| Part | Where | Job |
|---|---|---|
| Syncthing | every node and the gateway | syncs files |
| Relay and discovery | gateway | lets nodes find and reach each other |
| Agent | every node | small script, talks only to its own Syncthing |
| Aggregator | gateway | builds status views |
| `tinycloud` command | gateway and nodes | approve, remove, doctor, logs, dashboard |

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
- Pi hosts run an nftables firewall: default deny, outbound only to the gateway, DNS, and NTP. IPv6 is blocked in v1.
- LAN-only inbound: the status page (port 80), plus SSH and SMB only if the owner turns them on.

## Joining

1. The node makes its own ID on first boot and shows it on a local page with a short code and QR. The code is the first 6 characters of the SHA-256 of the device ID.
2. The person sends the owner one line: `NAME DEVICEID ROLE OWNER`.
3. The owner runs `tinycloud approve "<line>"`. It prints the code to compare with the person.
4. Every node picks up the new peer on its next check. Nothing to accept.
5. `tinycloud remove NAME` undoes it. `tinycloud leave` on a node leaves.

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

- Each node reports a tiny `status.json`: role, version, percent stored, free space, low space, case conflicts.
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
3. Write status if it needs to.

## Config

One file, `tinycloud.conf`, with `KEY=value` lines.

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
PEERS_CONFIRM=auto
SMB_ENABLED=false
```

Pi images keep it on the FAT partition named TINYCLOUD and delete it after first boot. Docker nodes keep it next to `docker-compose.yml`.

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

## Local status page

Each node serves a read-only page: connection state, space, warnings, and (until connected) the join line, code, and QR. It holds no secrets and no config. It refreshes every minute.

- Pi images: LAN only, port 80. This is the one inbound rule added to the brief.
- Docker nodes: `127.0.0.1:8080` by default (`TC_STATUS_BIND` changes it).

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

## Dashboard

`tinycloud dashboard` on the gateway owner's computer fetches the full view over SSH and opens a page on localhost. Each friend sees only their own nodes. The page escapes all text.

## If the gateway goes down

- Sync stops for everyone. Nodes keep their files.
- Fix: build a new Linode, run `gateway.sh`, restore the identity backup, and keep the same IP and hostname.
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

## To verify in Phase 1

- Sync works through the relay with the firewall open only to the gateway.
- The relay token works in the listen address.
- Nodes on the same LAN do not try direct connections.
- Min free space and pull order behave on a nearly full card.
- Gateway RAM stays fine on 1 GB.
- No secret in any log or support bundle.
- Everything works on both Debian and Ubuntu.

## Build order

1. Node stack: Syncthing, agent, status page, firewall, doctor.
2. Docker node.
3. Gateway and aggregator.
4. Approval commands.
5. Test with rocky, grace, and Finn's Linode.
