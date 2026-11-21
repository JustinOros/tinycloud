# Gateway

One small Linode. Relay, discovery, and approvals. It never holds the library.

## Install

On a fresh Debian 12+ or Ubuntu 22.04+ server, as root:

```
curl -fsSL https://raw.githubusercontent.com/JustinOros/tinycloud/main/setup.sh -o setup.sh && sh setup.sh
```

It asks a few questions, installs what is missing, and prints five lines for each node's `tinycloud.conf`. Show them again any time with `tinycloud-gw config`. The relay token is secret.

Read `setup.sh` first if you like. It is short.

## Add a node

On the new node, run `tinycloud join`. It prints a line and a 6 character code. Send the person's line to the gateway owner, who runs it on the gateway:

```
tinycloud-gw approve NAME DEVICEID ROLE OWNER
```

Check that the code it shows matches the one on the node, then type `yes`.

## Other commands

| Command | Does |
|---|---|
| `tinycloud-gw remove NAME` | drops the node |
| `tinycloud-gw list` | nodes and who is online |
| `tinycloud-gw config` | the five lines every node needs |
| `tinycloud-gw aggregate` | rebuilds the status views (a timer runs it every 5 minutes) |
| `tinycloud-gw view` | prints the full status view as JSON |
| `tinycloud-gw backup` | saves the gateway identity to `/root/tinycloud-backup/` |
| `tinycloud-gw restore FILE` | puts a saved identity back |

Every approve, remove, backup, and restore is logged in `/opt/tinycloud-gateway/audit.log`.

## Dashboard

On your own computer, with SSH access to the gateway and a copy of this repo:

```
sh dashboard/tinycloud-dashboard root@gw.example.com
```

It opens a page with every node: online or offline, space, warnings. Run it again to refresh.

## If the gateway dies

1. Make a new Linode and run `setup.sh` with the same hostname.
2. Copy your backup file to it and run `tinycloud-gw restore FILE`.
3. Move the old IP and hostname to the new Linode.

Nodes need no changes. Take a backup after every approve or remove.
