# Pure Storage FlashArray Storage Plugin for Proxmox VE

**Language / 語言：** [English](README.md) | [繁體中文](README_zh-TW.md)

This plugin enables Proxmox VE 9.1+ to use Pure Storage FlashArray for VM and Container disk storage via iSCSI or Fibre Channel protocol.

> **⚠️ DISCLAIMER**
>
> This project is newly developed and has not been extensively tested in production environments.
>
> - **iSCSI**: Basic functionality tested, but not yet validated at scale
> - **Fibre Channel**: Not fully verified, may have undiscovered issues
>
> **USE AT YOUR OWN RISK.** The author assumes no responsibility for any data loss, system downtime, or other damages that may result from using this plugin. Always test thoroughly in a non-production environment before deploying to production systems. Ensure you have proper backups before use.

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
dpkg -i jt-pve-storage-purestorage_1.0.35-1_all.deb
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
| Storage config | `/etc/pve/storage.cfg` |
| Multipath config | `/etc/multipath/conf.d/pure-storage.conf` |

## License

MIT License

## Author

Jason Cheng (jasoncheng7115)

## Acknowledgements

Special thanks to:
- **Pure Storage** - For providing excellent storage technology and comprehensive REST API
- **MetaAge (邁達特)** - For providing test equipment and environment for development and testing

## Links

- [Pure Storage REST API Documentation](https://support.purestorage.com/Solutions/FlashArray/Products/FlashArray/REST_API)
- [Proxmox VE Storage Plugin Documentation](https://pve.proxmox.com/wiki/Storage)
