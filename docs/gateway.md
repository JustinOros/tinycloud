# Gateway

One small Linode. Relay, discovery, and approvals. It never holds the library.

## Install

On a fresh Debian 12 or Ubuntu 22.04+ server, as root:

```
git clone https://github.com/JustinOros/tinycloud
cd tinycloud/gateway
sh gateway.sh --host gw.example.com
```

It prints five lines. Paste them into each node's `tinycloud.conf`. Keep a private copy. The relay token is secret.

## Add a node

The node's status page shows a join line. On the gateway:

```
tinycloud-gw approve NAME DEVICEID ROLE OWNER
```

Check the 6 character code matches the node's page, then type `yes`.

## Other commands

| Command | Does |
|---|---|
| `tinycloud-gw remove NAME` | drops the node |
| `tinycloud-gw list` | nodes and who is online |
| `tinycloud-gw backup` | saves the gateway identity to `/root/tinycloud-backup/` |
| `tinycloud-gw restore FILE` | puts a saved identity back |

Every approve, remove, backup, and restore is logged in `/opt/tinycloud-gateway/audit.log`.

## If the gateway dies

1. Make a new Linode and run `gateway.sh` with the same `--host`.
2. Copy your backup file to it and run `tinycloud-gw restore FILE`.
3. Move the old IP and hostname to the new Linode.

Nodes need no changes. Take a backup after every approve or remove.
