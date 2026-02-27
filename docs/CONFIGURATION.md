# Configuration Guide

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
- Protection Groups: Read (for snapshots)

## Multipath Configuration

The plugin works with default multipath settings. For optimal performance, you may want to customize `/etc/multipath.conf`:

```ini
devices {
    device {
        vendor "PURE"
        product "FlashArray"
        path_grouping_policy group_by_prio
        path_selector "queue-length 0"
        path_checker tur
        features "0"
        hardware_handler "1 alua"
        prio alua
        failback immediate
        fast_io_fail_tmo 10
        dev_loss_tmo 60
    }
}
```

After modifying, reload multipath:
```bash
multipathd reconfigure
```

## iSCSI Configuration

### Verify iSCSI Initiator Name

```bash
cat /etc/iscsi/initiatorname.iscsi
```

### Manual iSCSI Discovery (for troubleshooting)

```bash
iscsiadm -m discovery -t sendtargets -p <PURE_IP>
iscsiadm -m node -L all
```

## Fibre Channel Configuration

### Verify FC HBA

```bash
cat /sys/class/fc_host/host*/port_name
```

### Rescan FC

```bash
for host in /sys/class/fc_host/host*/issue_lip; do echo 1 > $host; done
for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done
```
