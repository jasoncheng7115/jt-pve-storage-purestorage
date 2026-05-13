# Quick Start Guide

語言 / Language: [English](QUICKSTART.md) | [繁體中文](QUICKSTART_zh-TW.md)

## Prerequisites

1. Proxmox VE 9.1 or later installed
2. Pure Storage FlashArray with network connectivity
3. API Token from Pure Storage (recommended) or user credentials
4. Multipath tools installed: `apt install multipath-tools open-iscsi sg3-utils psmisc`

## Read first: Multipath Safety Rules

Before installing, read the **CRITICAL: Multipath Safety Rules** section
in `README.md`. The shortest summary:

- Never run `multipath -F` (capital F).
- Use `systemctl restart multipathd`, not `reload`.
- Make sure `/etc/multipath.conf` `defaults` does NOT have
  `no_path_retry queue` or `dev_loss_tmo infinity`. The plugin will warn
  on install if it sees them, but it will not auto-fix.

## Installation Steps

### Step 1: Install the plugin

```bash
dpkg -i jt-pve-storage-purestorage_1.1.17-1_all.deb
```

Read the postinst output. It will warn if your `/etc/multipath.conf` has
dangerous settings, or if there are pre-existing stale Pure multipath
devices on the node.

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

For Fibre Channel, add `--pure-protocol fc`.

### Step 5: Verify storage

```bash
pvesm status
```

You should see `pure1` in the list with capacity information, returned in
under 5 seconds. If it takes 30+ seconds, check API connectivity.

The first activation also creates `/etc/multipath/conf.d/pure-storage.conf`
with Pure-friendly settings (`no_path_retry 30`, `fast_io_fail_tmo 5`,
`dev_loss_tmo 60`) and the version marker. Verify with:

```bash
head -3 /etc/multipath/conf.d/pure-storage.conf
# Expected: a line `# pure-multipath-config-version: 2`
```

### Step 6: Create a test VM

1. Create a new VM in PVE Web UI
2. Select `pure1` as the storage for the disk
3. Complete VM creation
4. Start the VM, run a small `dd` inside the guest, stop, destroy
5. Verify `multipath -ll | grep <wwid>` is empty (no stale device)

## Next Steps

- See [CONFIGURATION.md](CONFIGURATION.md) for advanced options
- See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues
- See [TESTING.md](TESTING.md) for the full test plan to run before
  deploying to production. Section 16 (regression tests for the data-loss
  and ghost-LUN bug classes) is **mandatory** for any production deployment.
