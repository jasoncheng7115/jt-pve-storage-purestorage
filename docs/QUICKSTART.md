# Quick Start Guide

## Prerequisites

1. Proxmox VE 8.0 or later installed
2. Pure Storage FlashArray with network connectivity
3. API Token from Pure Storage (recommended) or user credentials

## Installation Steps

### Step 1: Install the plugin

```bash
dpkg -i jt-pve-storage-purestorage_1.0.0-1_all.deb
```

### Step 2: Verify dependencies

```bash
systemctl status iscsid
systemctl status multipathd
```

### Step 3: Get API Token from Pure Storage

1. Login to Pure Storage Web UI
2. Go to Settings > API Tokens
3. Create a new API token for PVE
4. Copy the token string

### Step 4: Add storage to PVE

```bash
pvesm add purestorage pure1 \
    --pure-portal <PURE_IP> \
    --pure-api-token <API_TOKEN> \
    --content images
```

### Step 5: Verify storage

```bash
pvesm status
```

You should see `pure1` in the list with capacity information.

### Step 6: Create a test VM

1. Create a new VM in PVE Web UI
2. Select `pure1` as the storage for the disk
3. Complete VM creation

## Next Steps

- See [CONFIGURATION.md](CONFIGURATION.md) for advanced options
- See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues
