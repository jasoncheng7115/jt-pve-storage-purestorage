# Pure Storage FlashArray Storage Plugin for Proxmox VE

**[English](README.md)** | **[繁體中文](README_zh-TW.md)** | **[Documentation Site](https://jasoncheng7115.github.io/jt-pve-storage-purestorage/?lang=en)**

This plugin enables Proxmox VE 9.1+ to use Pure Storage FlashArray for VM and Container disk storage via iSCSI or Fibre Channel protocol.

> **DISCLAIMER**
>
> This project is newly developed and has not been extensively tested in production environments.
>
> - **iSCSI**: Basic functionality tested, but not yet validated at scale
> - **Fibre Channel**: Basic functionality tested with FC fabric connectivity verification and diagnostic logging
>
> **USE AT YOUR OWN RISK.** The author assumes no responsibility for any data loss, system downtime, or other damages that may result from using this plugin. Always test thoroughly in a non-production environment before deploying to production systems. Ensure you have proper backups before use.

## CRITICAL: Multipath Safety Rules

These rules apply to **any** SAN storage on Linux, but missing them with
Pure Storage and a typical PVE multipath configuration has been observed
to put PVE daemons into uninterruptible sleep (D state) — only recoverable
by rebooting the node. Read these before installing the plugin.

1. **NEVER run `multipath -F`** (capital F). It flushes ALL unused
   multipath maps on the host, including any non-Pure storage that happens
   to be idle at that moment. Always use the lowercase
   `multipath -f /dev/mapper/<wwid>` form to flush a specific device.

2. **Use `systemctl restart multipathd`, NOT `systemctl reload`.** Reload
   only re-reads the config file. Restart actually re-applies device-mapper
   state. The plugin uses restart in its own helpers for the same reason.

3. **AVOID dangerous defaults.** The combination
   `no_path_retry queue` + a stale device that the plugin is trying to
   clean up will hang `multipath -f`, `sync`, `blockdev --flushbufs`, and
   any process that opens the device. Recommended Pure-friendly settings:

   ```
   defaults {
       polling_interval        10
       no_path_retry           30
       fast_io_fail_tmo        5
       dev_loss_tmo            60
   }
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
       }
   }
   ```

4. **The plugin (v1.1.0+) handles cluster-wide cleanup automatically.**
   Each node maintains a WWID tracking file
   (`/var/lib/pve-storage-purestorage/<storeid>-wwids.json`) and
   `pvesm status` runs an orphan-cleanup pass in a backgrounded grandchild
   so the periodic cleanup never blocks the storage daemon. See
   `docs/TESTING.md` Section 6 for the design rationale.

## Upgrade SOP

> **⚠️ READ FIRST — `/etc/multipath/conf.d/pure-storage.conf` upgrade behaviour**
>
> Starting in 1.1.1 the plugin writes a version marker
> (`# pure-multipath-config-version: N`) into the `pure-storage.conf` it
> generates, and `_ensure_multipath_config` rewrites that file when the
> marker version changes. **Files WITHOUT the marker are left untouched
> on purpose** — the plugin assumes they were created by an older plugin
> version that the operator subsequently customised, or by a third party.
>
> **What this means for upgrades from 1.0.x → 1.1.2:**
>
> | Your existing file | What 1.1.2 does | Your action |
> |---|---|---|
> | No `pure-storage.conf` exists | Plugin writes the new file with `no_path_retry 30` / `fast_io_fail_tmo 5` | Nothing — done |
> | `pure-storage.conf` exists, has the new marker (1.1.1+) | Plugin auto-upgrades to v2 on next `activate_storage` | Nothing — done |
> | `pure-storage.conf` exists, **NO** marker (1.0.x or hand-edited) | Plugin **leaves the file alone** | **You must manually align it** with the new device block — see below |
>
> **If your file falls into the last row, you MUST manually update it** —
> otherwise the new safety settings (`no_path_retry 30`,
> `fast_io_fail_tmo 5`) will not be in effect, and a stale device on a
> host with `no_path_retry queue` in `defaults` can still hang PVE.
>
> The recommended replacement device block:
>
> ```
> devices {
>     device {
>         vendor               "PURE"
>         product              "FlashArray"
>         path_selector        "queue-length 0"
>         path_grouping_policy group_by_prio
>         prio                 alua
>         hardware_handler     "1 alua"
>         failback             immediate
>         no_path_retry        30
>         fast_io_fail_tmo     5
>         dev_loss_tmo         60
>     }
> }
> ```
>
> After editing, run `systemctl restart multipathd` (NOT `reload`).
>
> **The simplest way to opt back in to plugin management** is:
> `rm /etc/multipath/conf.d/pure-storage.conf`. The next
> `pvesm status pure1` will recreate it with the correct settings and
> the marker, and from then on future upgrades will be automatic.

Follow this procedure when upgrading from any earlier version (1.0.x) to
1.1.0 or later. Do this **one node at a time**.

1. **Backup `/etc/multipath.conf`** AND `/etc/multipath/conf.d/pure-storage.conf`
   on every node.
2. **Stop or migrate** running VMs off the node being upgraded if
   possible (recommended; not strictly required).
3. **Install the new package**:
   ```
   dpkg -i jt-pve-storage-purestorage_1.1.9-1_all.deb
   ```
4. **Read the postinst output carefully**. It will warn about:
   - dangerous multipath.conf settings (Section above)
   - any pre-existing stale Pure devices on the node
   - the difference between `restart` and `reload` for multipathd
5. **If postinst warned about multipath.conf**, edit the file as
   instructed and then `systemctl restart multipathd`.
6. **If postinst warned about stale Pure devices**, follow the manual
   cleanup commands shown in the warning. Do NOT use `multipath -F`.
6a. **Check `pure-storage.conf` upgrade status**:
    ```
    head -3 /etc/multipath/conf.d/pure-storage.conf
    ```
    If the file exists but does NOT contain a line starting with
    `# pure-multipath-config-version:`, see the warning box above —
    you must either manually align the device block with the new
    template OR `rm` the file to let the plugin recreate it.
7. **Verify**:
   ```
   pvesm status pure1                                # < 5s, active
   cat /var/lib/pve-storage-purestorage/*-wwids.json # auto-imported
   multipath -ll | grep -c PURE                      # path count looks right
   ```
8. **Move to the next node** only after the current node passes step 7.

## Storage Model

This plugin uses **direct volume provisioning** — every VM disk is
allocated as its own dedicated Pure Storage volume, sized exactly to
the requested capacity. There is no pre-allocated "big LUN" or storage
pool that gets carved into smaller pieces on the host side.

When Proxmox VE asks for a 50 GiB disk, the plugin calls
`volume_create` on the array with size = 50 GiB. When Proxmox VE asks
for a snapshot, the plugin calls `snapshot_create` on that volume.
The semantics map 1:1 — Pure's data services (deduplication,
compression, snapshot, ActiveCluster, async replication) all apply at
the natural unit of one VM disk.

### Direct Volume Provisioning vs Pool-Based SAN Models

```
Traditional pool-based SAN model
=================================

  +----------------------------+
  |  1x big LUN on array       |    admin pre-allocates one
  |  (e.g. 10 TB)              |    giant LUN
  +----------------------------+
                |
                v
  +----------------------------+
  |  LVM / LVM-thin on host    |
  |  +------+ +------+ +-----+ |
  |  | LV   | | LV   | | ... | |    each VM disk is an LV
  |  | vm   | | vm   | |     | |    inside the host's LVM
  |  | -100 | | -100 | |     | |
  |  | -d0  | | -d1  | |     | |
  |  +------+ +------+ +-----+ |
  +----------------------------+

  Snapshots / clones / replication happen at the LVM layer.
  Array sees ONE LUN that is always "in use".


This plugin (direct volume provisioning)
========================================

  +-----------------------------+
  | Pure FlashArray             |
  |                             |
  |   Volume   pve-...-100-d0   |    each VM disk is its own
  |   Volume   pve-...-100-d1   |    volume on the array, sized
  |   Volume   pve-...-101-d0   |    exactly to the request
  |   Volume   pve-...-102-d0   |
  |        ...                  |
  +-----------------------------+

  No host-side LVM. Every volume has its own WWID, snapshot chain,
  and host connections. Snapshots / clones / replication happen on
  the array, natively.
```

The pool-based model puts an LVM (or LVM-thin) layer between the
array and Proxmox VE. Snapshots, clones, and replication then happen
at LVM — the array sees a single giant LUN that is permanently "in
use", and its data services cannot reason about individual VM disks.
This plugin removes that intermediate layer entirely.

### Layer Stack

How a single Proxmox VE volname becomes a usable block device on the
host:

```
Proxmox VE level                vm-100-disk-0            (PVE volname)
        |
        v
Plugin encoding                 pve-pure1-100-disk0      (Naming.pm)
        |
        v
Pure FlashArray volume          50 GiB, WWID 624a9370... (REST API)
        |
        v
Host connections                connected to every       (per-node mode)
                                "pve-<cluster>-*" host
        |
        v
SCSI / FC transport             iSCSI sessions OR        (multiple paths
                                FC fabric                  per host)
        |
        v
Linux SCSI paths                /dev/sdc /dev/sdd ...    (one per portal /
                                                          fabric link)
        |
        v
multipath aggregation           /dev/mapper/3624a9370... (DM-multipath,
                                = /dev/dm-N                ALUA, queue-length 0)
        |
        v
QEMU block device               passed to qemu           (raw, no FS layer
                                                          between)
```

### Implications

- **Snapshots are array-native** — `volume_snapshot` calls
  `snapshot_create` on Pure; rollback uses `volume_overwrite`. No LVM
  copy-on-write cost.
- **Linked clones use array clone** — instant; the new volume shares
  blocks with the source until written. Proxmox VE's "Full Clone" is a
  Proxmox VE design choice (block-by-block copy via `qemu-img`), not a
  plugin limit.
- **Online resize is one API call** — `volume_resize` on the array,
  then per-path SCSI rescan + `multipath_resize_map` on the host. No
  filesystem-level resize on a parent pool.
- **Live migration is implicit** — every volume is connected to every
  node's host (per-node mode), so the same multipath device exists on
  every cluster node simultaneously. Proxmox VE just changes which
  node has the device open; no storage migration step is needed.
- **Per-VM array data services** — dedup ratio, replication policy,
  snapshot retention, QoS, and ActiveCluster Pod membership can all
  be configured per VM disk, because each disk is its own object on
  the array.

## Features

### Storage Operations
- Direct volume provisioning (no LUN indirection like traditional SAN)
- Online volume resize (no VM restart required)
- Automatic multipath configuration for Pure Storage devices

### Snapshot & Clone
- Instant snapshot create/delete/rollback via Pure Storage native snapshots
- Linked Clone from templates (instant, uses Pure Storage snapshot clone)
- RAM snapshot support (Include RAM option)
- Clone dependency protection (Pure Storage prevents deleting snapshots with clones)
- **Automatic VM config backup** - saves VM configuration to Pure Storage with each snapshot

### High Availability
- Cluster-aware for live migration (volumes connected to all nodes)
- ActiveCluster Pod support for synchronous replication
- Automatic host registration on Pure Storage

### Protocol Support
- iSCSI with automatic target discovery and login
- Fibre Channel with WWN auto-detection
- Multipath I/O with automatic configuration

### Content Types
- VM disk images (`images`)
- Container root filesystem (`rootdir`)

## Requirements

- Proxmox VE 9.1 or later
- Pure Storage FlashArray with Purity//FA 2.26 or later (REST API 2.x)
- API Token or user credentials for Pure Storage API
- Network connectivity to Pure Storage management interface

### For iSCSI
- `open-iscsi` package
- `multipath-tools` package
- Network connectivity to iSCSI data interfaces

### For Fibre Channel
- FC HBA with driver installed
- `multipath-tools` package
- FC zoning configured between host and Pure Storage

## Installation

### From .deb package (Recommended)

```bash
dpkg -i jt-pve-storage-purestorage_1.1.9-1_all.deb
apt-get install -f  # Install dependencies if needed
```

### From source

```bash
cd /root/jt-pve-storage-purestorage
make install
```

## Configuration

### Basic Setup with API Token (Recommended)

```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    --pure-protocol iscsi \
    --content images,rootdir
```

### Setup with Username/Password

```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-username pureuser \
    --pure-password secretpassword \
    --pure-protocol iscsi \
    --content images,rootdir
```

### Setup with ActiveCluster Pod

```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    --pure-protocol iscsi \
    --pure-pod prod-pod \
    --content images,rootdir
```

### Configuration Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `pure-portal` | Yes | - | Pure Storage array management IP or hostname |
| `pure-api-token` | No* | - | API token for authentication |
| `pure-username` | No* | - | Username for API authentication |
| `pure-password` | No* | - | Password for API authentication |
| `pure-ssl-verify` | No | 0 | Verify SSL certificate (0=no, 1=yes) |
| `pure-protocol` | No | iscsi | SAN protocol: `iscsi` or `fc` |
| `pure-host-mode` | No | per-node | Host mode: `per-node` or `shared` |
| `pure-cluster-name` | No | pve | Cluster name for host naming |
| `pure-device-timeout` | No | 60 | Device discovery timeout in seconds |
| `pure-pod` | No | - | ActiveCluster Pod name for synchronous replication |
| `content` | Yes | - | Content types: `images`, `rootdir` |

\* Either `pure-api-token` or both `pure-username` and `pure-password` are required.

### Example storage.cfg Entry

```ini
purestorage: pure1
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-protocol iscsi
    pure-host-mode per-node
    pure-cluster-name mycluster
    content images,rootdir
    shared 1
```

## Usage

### VM Disk Operations

```bash
# Create a disk
pvesm alloc pure1 100 vm-100-disk-0 10G

# List disks
pvesm list pure1

# Check disk size
pvesm volume-size pure1:vm-100-disk-0

# Resize disk (online supported)
qm resize 100 scsi0 +10G

# Delete disk
pvesm free pure1:vm-100-disk-0
```

### VM Operations

```bash
# Create VM with Pure Storage disk
qm create 100 --name myvm --memory 2048 --cores 2 \
    --scsi0 pure1:20,iothread=1 --scsihw virtio-scsi-single

# Start VM
qm start 100

# Stop VM
qm stop 100
```

### Snapshot Operations

```bash
# Create snapshot
qm snapshot 100 snap1

# Create snapshot with RAM (Include RAM)
qm snapshot 100 snap1 --vmstate

# List snapshots
qm listsnapshot 100

# Rollback to snapshot
qm rollback 100 snap1

# Delete snapshot
qm delsnapshot 100 snap1
```

### Template & Clone Operations

```bash
# Convert VM to template
qm template 100

# Linked Clone (Recommended - instant)
qm clone 100 200 --name cloned-vm --full 0

# Full Clone (slower - uses data copy due to PVE limitation)
qm clone 100 200 --name cloned-vm --full 1
```

### Container Operations

```bash
# Create container with Pure Storage
pct create 300 local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
    --rootfs pure1:10 --hostname myct --memory 512

# Start container
pct start 300
```

### Live Migration

```bash
# Migrate VM to another node (online)
qm migrate 100 pve2 --online
```

## Naming Conventions

| PVE Object | Pure Storage Object | Pattern |
|------------|---------------------|---------|
| VM disk | Volume | `pve-{storage}-{vmid}-disk{diskid}` |
| Container rootfs | Volume | `pve-{storage}-{vmid}-disk{diskid}` |
| Cloud-init | Volume | `pve-{storage}-{vmid}-cloudinit` |
| RAM state | Volume | `pve-{storage}-{vmid}-state-{snapname}` |
| VM config backup | Volume | `pve-{storage}-{vmid}-vmconf-{snapname}` |
| Snapshot | Volume Snapshot | `{volume}.pve-snap-{snapname}` |
| Template marker | Volume Snapshot | `{volume}.pve-base` |
| PVE Node | Host | `pve-{cluster}-{node}` |
| Shared Host | Host | `pve-{cluster}-shared` |

### Linked Clone Volume Format

Linked clones use a special naming format to track the parent relationship:
```
base-{basevmid}-disk-{n}/vm-{vmid}-disk-{n}
```

Example: `base-100-disk-0/vm-200-disk-0` indicates VM 200's disk is cloned from VM 100's template.

## Host Mode

### per-node (Default)

Creates a separate host object on Pure Storage for each PVE node.

```
pve-mycluster-pve1
pve-mycluster-pve2
pve-mycluster-pve3
```

Best for:
- Multi-node clusters
- Per-node visibility in Pure Storage
- Granular access control

### shared

Uses a single shared host object for all PVE nodes.

```
pve-mycluster-shared
```

Best for:
- Small clusters (2-3 nodes)
- Simplified management
- All nodes share the same initiators

## Pod Support (ActiveCluster)

When `pure-pod` is configured, all volumes are created within the specified Pod for synchronous replication between two FlashArrays.

```
Volume without pod: pve-pure1-100-disk0
Volume with pod:    prod-pod::pve-pure1-100-disk0
```

Features:
- RPO = 0 (synchronous replication)
- Active-active access from both arrays
- Automatic failover
- Pod quota shown as storage capacity

## VM Config Backup

When creating a snapshot, the plugin automatically backs up the VM configuration file to Pure Storage. This allows you to recover not just the disk data, but also the VM settings at that point in time.

### How It Works

- **Automatic**: Config is saved automatically when creating any snapshot
- **Per-snapshot**: Each snapshot gets its own independent config backup
- **Format**: 1MB ext4 volume containing `{vmid}.conf` and `metadata.txt`
- **Hidden**: Config volumes don't appear in PVE disk listings

### Automatic Cleanup

Config backup volumes are automatically cleaned up:
- When a snapshot is deleted, its corresponding config volume is also deleted
- When a VM is deleted (last disk removed), all its config volumes are deleted

### Retrieving Config Backup

Use the `pve-pure-config-get` command-line tool to easily retrieve config backups.

**Usage:**
```
pve-pure-config-get -s <storage> -v <vmid> [-n <snap>] [-o <output_dir>] [-l] [-r]
```

**Options:**

| Option | Description |
|--------|-------------|
| `-s, --storage <name>` | Pure Storage storage ID (required) |
| `-v, --vmid <id>` | VM ID to retrieve config for (required) |
| `-n, --snap <name>` | Snapshot name to retrieve (skip interactive selection) |
| `-o, --output <dir>` | Output directory (default: `/tmp`) |
| `-l, --list` | List available snapshots only, don't retrieve |
| `-r, --restore` | Disaster recovery mode (see below) |
| `-h, --help` | Show help message |

**Output files:**
```
/tmp/vm-{vmid}-{snapname}-{vmid}.conf      # VM configuration
/tmp/vm-{vmid}-{snapname}-metadata.txt     # Backup metadata (timestamp, source info)
```

**Examples:**

```bash
# List available config backups for VM 100
pve-pure-config-get -s pure1 -v 100 -l

# Retrieve config interactively (will prompt for selection)
pve-pure-config-get -s pure1 -v 100

# Retrieve specific snapshot's config directly
pve-pure-config-get -s pure1 -v 100 -n snap1

# Retrieve to a specific directory
pve-pure-config-get -s pure1 -v 100 -n snap1 -o /root/configs
```

**Example session:**
```
$ pve-pure-config-get -s pure1 -v 100

Searching for config backups for VM 100...

Available config backups:
-----------------------------------------------------------
  No.  Snapshot Name  Volume
-----------------------------------------------------------
     1  backup1        pve1::pve-pure1-100-vmconf-backup1
     2  daily-0126     pve1::pve-pure1-100-vmconf-daily-0126
-----------------------------------------------------------

Enter number to retrieve (1-2), or 'q' to quit: 1

Retrieving config from: pve1::pve-pure1-100-vmconf-backup1
Connecting volume to host 'pve-mycluster-pve1'...
Volume WWID: 624a9370...
Scanning for device...
Found device: /dev/mapper/3624a9370...
Mounting to /tmp/...
Saved: /tmp/vm-100-backup1-100.conf
Saved: /tmp/vm-100-backup1-metadata.txt
Cleaning up...

Done! Config file saved to: /tmp/vm-100-backup1-100.conf
To restore: cp /tmp/vm-100-backup1-100.conf /etc/pve/qemu-server/100.conf
```

### Disaster Recovery (-r / --restore)

The restore mode enables full VM recovery from destroyed volumes on Pure Storage. This is useful when a VM has been accidentally deleted but the volumes are still in Pure Storage's "Destroyed Volumes" (not yet eradicated).

**Features:**
- Searches both active and destroyed volumes
- Displays volume status (`[active]` or `[DESTROYED]`)
- Automatically recovers destroyed config and disk volumes
- Places config file in correct PVE location (`/etc/pve/qemu-server/` or `/etc/pve/lxc/`)
- Connects disk volumes to host
- Safety check: refuses to overwrite existing VM config

**Usage:**

```bash
# List available backups including destroyed volumes
pve-pure-config-get -s pure1 -v 100 -r -l

# Full VM restore from destroyed volumes
pve-pure-config-get -s pure1 -v 100 -n snap1 -r
```

**Example restore session:**
```
$ pve-pure-config-get -s pure1 -v 100 -n snap1 -r

Restore mode: Will recover destroyed volumes and place config in PVE

Searching for config backups for VM 100...

Available config backups:
-------------------------------------------------------------------------
  No.  Snapshot Name  Volume                                  Status
-------------------------------------------------------------------------
     1  snap1          pve1::pve-pure1-100-vmconf-snap1        [DESTROYED]
-------------------------------------------------------------------------

Retrieving config from: pve1::pve-pure1-100-vmconf-snap1
Recovering destroyed config volume...
Config volume recovered.
Connecting volume to host 'pve-mycluster-pve1'...
...

=== Starting VM Restore ===
Found 1 disk volume(s) in config
Recovering destroyed volume: pve1::pve-pure1-100-disk0 ... OK

Connecting disk volumes to host 'pve-mycluster-pve1'...
Rescanning for devices...

Placing config in /etc/pve/qemu-server/100.conf...
Cleaning up config volume...

============================================================
VM 100 restored successfully!
============================================================
Config file: /etc/pve/qemu-server/100.conf
Recovered volumes: 1

You can now start the VM from PVE web UI or CLI:
  qm start 100
```

**Important notes:**
- Works even if VM is completely deleted from PVE
- Volumes must not be eradicated from Pure Storage (still in "Destroyed Volumes")
- If VM config already exists in PVE, restore will be refused (delete it first)

## Known Limitations

### Full Clone Limitation

PVE's Full Clone is designed to use data copy (`alloc_image` + `qemu-img`) rather than calling the storage plugin's `clone_image`. This is a PVE architectural decision, not a plugin limitation.

**Workaround**: Use Linked Clone instead. Pure Storage performs instant cloning via snapshots. If you need a fully independent volume without snapshot dependency, delete the source snapshot after cloning.

### Snapshot Naming Restrictions

Pure Storage snapshot suffixes only allow alphanumeric characters and hyphens (`-`). Underscores and dots in PVE snapshot names are automatically converted to hyphens.

### Destroyed Volume Visibility

Volumes that are destroyed but not yet eradicated on Pure Storage are automatically filtered out from PVE listings.

## Troubleshooting

### Device Not Appearing After Volume Creation

1. Check iSCSI sessions:
   ```bash
   iscsiadm -m session
   ```

2. Rescan for new devices:
   ```bash
   iscsiadm -m session --rescan
   ```

3. Trigger udev refresh:
   ```bash
   udevadm trigger
   ```

4. Check multipath:
   ```bash
   multipathd show maps
   multipath -ll
   ```

5. Reload multipath:
   ```bash
   multipathd reconfigure
   ```

### FC Device Not Appearing

1. Check FC HBA ports are online:
   ```bash
   cat /sys/class/fc_host/host*/port_state
   ```

2. Check FC target ports are visible:
   ```bash
   ls /sys/class/fc_remote_ports/
   ```

3. Verify FC zoning - ensure host WWPNs can see Pure Storage target WWPNs:
   ```bash
   cat /sys/class/fc_host/host*/port_name
   cat /sys/class/fc_remote_ports/rport-*/port_name
   ```

4. Issue LIP (Loop Initialization Primitive) to rescan fabric:
   ```bash
   echo 1 > /sys/class/fc_host/host0/issue_lip
   ```

5. Rescan SCSI hosts for new LUNs:
   ```bash
   echo "- - -" > /sys/class/scsi_host/host0/scan
   ```

6. Check multipath:
   ```bash
   multipathd show maps
   multipath -ll
   ```

### Authentication Failures

1. Verify API token is correct and not expired
2. Check user has required permissions on Pure Storage
3. Test API connectivity:
   ```bash
   curl -k -H "api-token: YOUR_TOKEN" https://PURE_IP/api/2.x/arrays
   ```

### Volume Not Found

1. Verify volume exists on Pure Storage
2. Check volume naming (should start with `pve-`)
3. If using Pod, verify Pod name is correct
4. Check if volume is destroyed but not eradicated

### Slow Listing Performance

1. Ensure using latest plugin version (optimized API queries)
2. For Pod configurations, the plugin uses `pod.name` filter for efficiency
3. Check network latency to Pure Storage management interface

### Linked Clone Not Showing Parent

If VM config shows `vm-X-disk-Y` instead of `base-X-disk-Y/vm-Z-disk-W`:
- The clone was created with an older plugin version
- Recreate the clone with the latest plugin version

## Pure Storage API Requirements

The API user needs the following minimum permissions:

| Object | Permissions |
|--------|-------------|
| Volume | create, delete, list, modify |
| Host | create, delete, list, modify |
| Host Group | create, delete, list, modify (if using shared mode) |
| Snapshot | create, delete, list |
| Pod | list (if using ActiveCluster) |

## Building from Source

```bash
cd /root/jt-pve-storage-purestorage

# Run syntax checks
make test

# Build .deb package
make deb

# Install locally
make install
```

## File Locations

| File | Path |
|------|------|
| Plugin module | `/usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm` |
| API module | `/usr/share/perl5/PVE/Storage/Custom/PureStorage/API.pm` |
| Config retrieval tool | `/usr/bin/pve-pure-config-get` |
| Storage config | `/etc/pve/storage.cfg` |
| Multipath config | `/etc/multipath/conf.d/pure-storage.conf` |

## License

MIT License

## Author

Jason Cheng (Jason Tools)

## Acknowledgements

Special thanks to:
- **Pure Storage** - For providing excellent storage technology and comprehensive REST API
- **MetaAge (邁達特)** - For providing test equipment and environment for development and testing

## Links

- [Pure Storage REST API Documentation](https://support.purestorage.com/Solutions/FlashArray/Products/FlashArray/REST_API)
- [Proxmox VE Storage Plugin Documentation](https://pve.proxmox.com/wiki/Storage)
