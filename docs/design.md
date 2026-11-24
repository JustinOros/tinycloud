# TinyCloud design

A private file cloud for trusted friends. Nodes sync your shared files through a gateway. Clouds can be linked later. Nobody controls anyone else's node.

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
| `tc-lib-OWNER` | between nodes | that owner's files, at `library/OWNER` on every node |
| `tinycloud-peers` | gateway to nodes | `peers.json` |
| `tc-status-NAME` | node to gateway | that node's status |
| `tc-view-OWNER` | gateway to that owner's nodes | what that owner may see |

A node holds its own owner's folder by its role, and every other owner's folder as Receive Only. Nobody ever auto-accepts a folder or a device. The introducer feature is never used.

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
- Setup can share the library over SMB so a PC on the local network can copy files in and out (default off). Read-write shares only the owner's own folder, so everything added syncs. Read-only shares the whole library. A password is required, except for read-only, where the owner may choose none. Setup creates a locked system account for the SMB login, adds one `include` line to `smb.conf` instead of replacing it, allows only private LAN addresses, turns SMB1 off, and opens ports 139 and 445 on the host firewall for the LAN only. Reader nodes are read-only.
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

Optional `links`: up to 16 linked gateways, each with `host`, `relay_id`, `disc_id` and `token`. A node adds each one's discovery and relay servers next to its own gateway's. Bad or duplicate entries reject the whole file. Without `links`, nothing changes.

Optional `folders` on a peer: owner names. A node shares that owner's folder with the peer only if it is listed. Without `folders`, the peer gets every folder.

The agent changes two things only: which devices exist, and which devices get the owner folders. It also creates a folder for each owner it sees, and removes the folder setting, never the files, for an owner who has left. Readers skip other readers.

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

Every node has a shortcut named `tinycloud` in its owner's home folder, pointing at the library. Your files go in your own owner folder. From another machine: `scp book.epub NODE:tinycloud/OWNER/`. `tinycloud path` prints the real location.

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
- A timer runs the backup every Sunday at about 3:30 AM and keeps the last 10. If a weekly backup fails, an alert goes out. Copying backups off the server stays manual, since they hold secrets.

## Later: linked clouds

Built, but only tested with fake data so far. Not yet tried with two real clouds.

- Each person runs their own cloud: their own gateway, nodes, and approvals. Nobody controls anyone else's node or gateway.
- Clouds are linked by exchanging a gateway code. A link gives each side a read-only copy of the other's files, so more people means more copies.
- Each owner's files live in one folder named for the owner. On disk it is `library/OWNER`, and its Syncthing ID is `tc-lib-OWNER`. Owner names must be unique across linked clouds, and a link that would repeat one is refused.
- In its own cloud, an owner's folder works as it does today. In a linked cloud, its nodes hold that folder as Receive Only, so they never send changes back.
- Two clouds can link one way or both ways. Each side chooses which of its own folders to offer, and which offered folders to accept. The default is none.

### The link

- `tinycloud-gw link export` prints a code: the gateway host, its three IDs, its relay token, and its nodes. The relay token is secret, so send the code privately. It lists no folders; each side chooses on its own.
- `tinycloud-gw link add NAME CODE` reads the code and shows a summary: the gateway, the node count, and the owners. The owner picks which of their owners' files to receive and which of the owner's own files to send, then says yes. Nothing is added before that. The default is none. `--accept` and `--offer` take owner lists for scripts.
- Files flow for an owner only when the cloud that has them offers them and the other cloud accepts them. Both clouds run `link add` with the other's code, even for a one way link, because each side's nodes must know the other's.
- A linked node is a device that gets only the folders chosen, as Receive Only on the receiving side. It never gets the introducer feature, and it can never add devices.
- The gateway writes linked nodes into `peers.json` as `LINKNAME-NODE`, each with a `folders` list, and the linked gateways in `links`. Nodes then list the linked gateways' discovery and relay servers next to their own, so a node can find and reach linked nodes through either gateway. A peer without `folders` gets every folder, as before.
- Running `link add` again with the same name and a fresh code updates the link, for when the other side adds a node. With `--yes` it keeps the earlier choices.
- `link list` shows links. `link remove NAME` drops one, and the files already copied stay. Add, update, and remove are logged in `audit.log`, never with the token.
- A link is refused if an owner name repeats, if a node name would repeat once the link name is added, or if the cloud would pass 64 nodes in all.
- Rotating the relay token breaks every link until the other side adds a fresh code.

### When a gateway goes down

- Syncing between existing nodes continues through the other gateway's discovery and relay.
- New approvals and the dashboard for that cloud wait until its gateway is back.
- A copy on a linked node is a backup, not a failover. To recover, copy files off the linked node by hand.

### Costs

- Every mirrored folder uses disk on every linked node. The usual free space floor applies, and a partial node stores what fits.
- Status and alerts stay per cloud. Linked nodes do not appear on each other's dashboards.

### Build order

1. Per-owner folders. Built. The first agent run on an existing node removes the old `tinycloud-library` folder setting and creates the owner folders, and the files stay where they are.
2. Nodes accept extra discovery and relay servers.
3. The link commands.

Test with a second gateway and a test node standing in for a friend's cloud.

## Known limits

- A gateway owner can add a device that then gets the library. `PEERS_CONFIRM=manual` blocks that on a node.
- All sync goes through the Nanode relay, so its transfer cap and one CPU are the ceiling.
- Admins and anchors can read the data.
- Receive Only on a linked node protects against mistakes, not against a friend who modifies his own Syncthing. Link only people you trust.
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
- The weekly backup timer works on the real gateway: its service saved a private backup on its own.
- A missed heartbeat reaches Discord: with the aggregate timer stopped, healthchecks.io posted DOWN after the grace time, and UP when the timer came back.
- Swapping a node's SD card works: a new card on a new image joined as the same node after `tinycloud-gw remove` and `approve`, re-synced 4 GB, and Discord showed NEW while it was away and RESOLVED when it returned.
- The firewall works on a real board: from another host on the LAN only SSH answered, and the Syncthing, web and sync ports were dropped.
- Local discovery is off on a real node, and its peer traffic (4.4 GB from another node) ran only through the relay. Two nodes on the same network have not been tested together.
- The free space floor works on a real node: on a nearly full card Syncthing refused a new file with an insufficient space error and filled nothing, the low space alert reached Discord (NEW, then RESOLVED), and the file arrived once space was freed. This found a bug: updating a folder's devices reset the floor to Syncthing's default, so the agent now sends the floor and pull order with every update.
- No secret reaches a log or the support bundle: the gateway webhook, heartbeat address and relay token were searched for in the gateway journal, container logs and audit log, and a node's relay token in its logs and bundle. This found that `tinycloud logs` printed the relay token, and that a linked gateway's token was not hidden. Both are fixed.
- The gateway reboot alert works on the real gateway: with the wait set to zero, creating the reboot-required flag sent NEW and removing it sent RESOLVED. The flag was made by hand, not by a real update.
- Pull order works on a real node: five files queued at once arrived smallest first, not in name order.
- Gateway RAM is fine on 1 GB with 2 nodes: the three containers use about 58 MB and over half the memory is free. Not yet measured with many nodes.
- Per-owner folders work on real nodes: each owner's books sync between a Docker node on Unraid and an Orange Pi, and a delete on one node reaches the other.
- The optional SMB share works on an Orange Pi: a file copied from a Mac over SMB arrived on the other node, and only the TinyCloud share is listed.
- `tinycloud-gw remove` works against a real Syncthing.
- Linked clouds work between two real gateways: a file added on a node in one cloud reached both nodes in the other, the other cloud's own files stayed home because they were not accepted, a delete on a receive-only node did not travel back, and removing the link dropped the other cloud's folder from the nodes.

## Still to verify

- Alerts reach a real ntfy topic.
