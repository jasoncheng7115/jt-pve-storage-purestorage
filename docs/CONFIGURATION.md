# Configuration Guide

語言 / Language: [English](CONFIGURATION.md) | [繁體中文](CONFIGURATION_zh-TW.md)

## Storage Model (Quick Recap)

This plugin uses **direct volume provisioning**: every VM disk is its
own dedicated Pure Storage volume, sized exactly to the requested
capacity. There is no pre-allocated "big LUN" or storage pool that
gets carved into smaller pieces on the host side.

```
Traditional pool-based SAN              This plugin
=========================               ===========

   1x big LUN on array                  Pure FlashArray
            |                              Volume   pve-...-100-d0
            v                              Volume   pve-...-100-d1
   LVM / LVM-thin on host                  Volume   pve-...-101-d0
   +------+ +------+ +-----+               Volume   pve-...-102-d0
   | LV   | | LV   | | ... |                    ...
   | -d0  | | -d1  | |     |
   +------+ +------+ +-----+
                                        one volume per VM disk;
   snapshots / clones at LVM            snapshots / clones / replication
   (array sees one LUN always           happen natively on the array
    "in use")
```

**Configuration implications:**
- No `vgcreate` / `lvcreate` step on hosts.
- `pure-host-mode` (below) controls how the plugin maps the per-disk
  volume to host connections — `per-node` connects every volume to
  every node's host (recommended for live migration); `shared` uses a
  single host object for the whole cluster.
- `pure-pod` (below) places the per-disk volume inside an
  ActiveCluster Pod, prefixing the volume name with `<pod>::`.

For the full storage model (including layer stack and per-VM data
service implications), see [README.md → Storage Model](../README.md#storage-model).

## Storage Configuration Options

### Required Options

| Option | Description |
|--------|-------------|
| `pure-portal` | IP address or hostname of Pure Storage management interface |

### Authentication (choose one)

| Option | Description |
|--------|-------------|
| `pure-api-token` | API token for authentication (recommended) |
| `pure-username` + `pure-password` | Username and password for API authentication |

### Optional Options

| Option | Default | Description |
|--------|---------|-------------|
| `pure-ssl-verify` | 0 | Verify SSL certificate (0=no, 1=yes) |
| `pure-protocol` | iscsi | SAN protocol: `iscsi` or `fc` |
| `pure-host-mode` | per-node | Host mode: `per-node` or `shared` |
| `pure-cluster-name` | pve | Cluster name for host naming |
| `pure-device-timeout` | 60 | Timeout in seconds for device discovery |
| `pure-pod` | (none) | ActiveCluster pod name. When set, all volumes are created with `<pod>::` prefix |

### Host modes

- **per-node** (default, recommended for security): one Pure host object
  per PVE node, named `pve-<cluster-name>-<nodename>`. Each volume is
  connected to every node's host so live migration works.
- **shared**: one Pure host object containing all nodes' WWPNs/IQNs,
  named `pve-<cluster-name>-shared`. Simpler mapping but less isolation.

In per-node mode, when `_connect_to_all_hosts` enumerates the cluster
hosts, it queries the array for `pve-<cluster-name>-*` host objects. If
your cluster name has special characters, sanitise them out (the plugin
sanitises automatically, but it's good to verify with `pvesm status`).

## Example Configurations

### Basic iSCSI Configuration

```ini
purestorage: pure1
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    content images
    shared 1
```

### Fibre Channel Configuration

```ini
purestorage: pure-fc
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-protocol fc
    content images
    shared 1
```

### Shared Host Mode

```ini
purestorage: pure-shared
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-host-mode shared
    pure-cluster-name production
    content images
    shared 1
```

### With SSL Verification

```ini
purestorage: pure-secure
    pure-portal pure.example.com
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-ssl-verify 1
    content images
    shared 1
```

### ActiveCluster Pod

```ini
purestorage: pure-pod1
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-pod testpod
    content images
    shared 1
```

All volumes for this storage will be created as `testpod::pve-...`. The
plugin transparently strips the prefix when listing volumes through PVE.

## Pure Storage API User Setup

### Creating API User

1. Login to Pure Storage Web UI
2. Navigate to Settings > Users
3. Create a new user for PVE integration
4. Assign appropriate role (Storage Admin or custom)

### Creating API Token

1. Login as the API user
2. Go to Settings > API Tokens
3. Click "Create API Token"
4. Copy and securely store the token

### Required Permissions

Minimum permissions for the API user:
- Volumes: Create, Delete, Read, Update
- Hosts: Create, Delete, Read, Update
- Connections: Create, Delete, Read
- Snapshots: Create, Delete, Read

## Multipath Configuration

The plugin auto-creates `/etc/multipath/conf.d/pure-storage.conf` on the
first `activate_storage` call. The auto-generated file is marked with a
version line (`# pure-multipath-config-version: 2`); subsequent plugin
upgrades will rewrite it when the marker version changes. **Files without
the marker line are left untouched** so customer-edited configs are not
overwritten.

If you prefer to manage multipath.conf yourself, place the following
device block in `/etc/multipath/conf.d/` or in `/etc/multipath.conf`:

```
devices {
    device {
        vendor               "PURE"
        product              "FlashArray"
        path_selector        "queue-length 0"
        path_grouping_policy group_by_prio
        prio                 alua
        hardware_handler     "1 alua"
        failback             immediate
        no_path_retry        30
        fast_io_fail_tmo     5
        dev_loss_tmo         60
    }
}
```

After modifying, **restart** multipathd (NOT `reload`):

```bash
systemctl restart multipathd
```

`reload` only re-reads the config file. `restart` actually re-applies
device-mapper state, which is what you want when changing per-device
parameters.

### Why these specific settings?

| Setting | Bad value | Good value | Why |
|---------|-----------|------------|-----|
| `no_path_retry` | `queue` | `30` | `queue` = infinite queue → I/O hangs forever on stale devices, taking PVE daemons into D state |
| `dev_loss_tmo` | `infinity` | `60` | `infinity` = stale SCSI devices never removed |
| `fast_io_fail_tmo` | not set | `5` | Speeds up path failure detection |
| `failback` | `manual` | `immediate` | Pure controllers are active/active; auto-rebalance |
| `path_selector` | `round-robin` | `queue-length 0` | Better with Pure's parallel architecture |

The plugin's auto-generated file always sets these explicitly so it
overrides any dangerous default in the `defaults` section of
`/etc/multipath.conf`.

## iSCSI Configuration

### Verify iSCSI Initiator Name

```bash
cat /etc/iscsi/initiatorname.iscsi
```

The plugin sets `node.session.timeo.replacement_timeout` to 120 on every
login (overriding `iscsid.conf` if necessary) so Pure controller failover
recovers cleanly.

### Manual iSCSI Discovery (for troubleshooting only)

The plugin handles discovery and login automatically. Manual operations
should only be needed when debugging:

```bash
iscsiadm -m discovery -t sendtargets -p <PURE_IP>
iscsiadm -m session
```

## Fibre Channel Configuration

### Verify FC HBA

```bash
cat /sys/class/fc_host/host*/port_name
cat /sys/class/fc_host/host*/port_state
```

All ports should be `Online`.

### Verify FC zoning to Pure

```bash
cat /sys/class/fc_remote_ports/rport-*/port_state
```

You should see `Online` entries for the Pure target ports. If not,
check FC switch zoning between this host and the Pure array.

The plugin's `activate_storage` performs FC rescan automatically; manual
LIP/scan is rarely needed.

## State and Lock Directories

The plugin creates and uses two directories (mode 0700, root-owned):

| Path | Purpose |
|------|---------|
| `/var/lib/pve-storage-purestorage/` | Persistent WWID tracking JSON files (one per storage) |
| `/var/run/pve-storage-purestorage/` | Lock files (tmpfs, cleared on reboot) |

The state file `<storeid>-wwids.json` is what the cluster orphan-cleanup
mechanism uses to find stale multipath devices on nodes that didn't
perform a delete. **Do not edit it manually.** If you need to reset it,
stop the storage and delete the file; the next `activate_storage` will
auto-import the current array WWIDs.
