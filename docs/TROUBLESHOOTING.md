# Troubleshooting Guide

## Common Issues

### 1. Storage Not Appearing in PVE

**Symptoms:**
- Storage not visible in PVE Web UI
- `pvesm status` shows storage as unavailable

**Solutions:**

1. Check connectivity to Pure Storage:
   ```bash
   curl -k https://<PURE_IP>/api/1.19/array
   ```

2. Verify API token is correct:
   ```bash
   curl -k -H "api-token: YOUR_TOKEN" https://<PURE_IP>/api/1.19/array
   ```

3. Check PVE logs:
   ```bash
   journalctl -u pvedaemon -f
   ```

### 2. Volume Creation Fails

**Symptoms:**
- Error when creating VM disk
- "Failed to create volume" message

**Solutions:**

1. Check Pure Storage capacity:
   ```bash
   curl -k -H "api-token: TOKEN" https://<PURE_IP>/api/1.19/array?space=true
   ```

2. Verify host exists on Pure Storage:
   ```bash
   curl -k -H "api-token: TOKEN" https://<PURE_IP>/api/1.19/host
   ```

3. Check for naming conflicts:
   ```bash
   curl -k -H "api-token: TOKEN" "https://<PURE_IP>/api/1.19/volume?names=pve-*"
   ```

### 3. Device Not Appearing After Volume Connection

**Symptoms:**
- VM disk created but device path not found
- VM fails to start with "cannot find device" error

**Solutions:**

1. Rescan iSCSI sessions:
   ```bash
   iscsiadm -m session --rescan
   ```

2. Rescan SCSI hosts:
   ```bash
   for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done
   ```

3. Reload multipath:
   ```bash
   multipathd reconfigure
   multipath -v2
   ```

4. Check multipath status:
   ```bash
   multipathd show maps
   multipathd show paths
   ```

### 4. Snapshot Operations Fail

**Symptoms:**
- Snapshot creation fails
- Rollback fails with error

**Solutions:**

1. Verify volume exists:
   ```bash
   curl -k -H "api-token: TOKEN" "https://<PURE_IP>/api/1.19/volume/<volname>"
   ```

2. Check existing snapshots:
   ```bash
   curl -k -H "api-token: TOKEN" "https://<PURE_IP>/api/1.19/volume?snap=true&source=<volname>"
   ```

### 5. Clone Operation Fails

**Symptoms:**
- VM clone fails
- Template conversion fails

**Solutions:**

1. Verify source volume has base snapshot:
   ```bash
   curl -k -H "api-token: TOKEN" "https://<PURE_IP>/api/1.19/volume/<volname>.pve-base"
   ```

2. Check if target volume name already exists

### 6. Authentication Errors

**Symptoms:**
- "401 Unauthorized" errors
- "Authentication failed" messages

**Solutions:**

1. Regenerate API token on Pure Storage
2. Check token hasn't expired
3. Verify user has correct permissions

### 7. iSCSI Session Issues

**Symptoms:**
- iSCSI sessions dropping
- I/O errors in VM

**Solutions:**

1. Check iSCSI session status:
   ```bash
   iscsiadm -m session -P 3
   ```

2. Verify network connectivity to all iSCSI portals

3. Check for timeout issues in `/etc/iscsi/iscsid.conf`

### 8. Multipath Issues

**Symptoms:**
- Single path instead of multipath
- Path failures not being handled

**Solutions:**

1. Check multipath configuration:
   ```bash
   multipath -ll
   ```

2. Verify all paths are active:
   ```bash
   multipathd show paths
   ```

3. Check `/etc/multipath.conf` for Pure Storage settings

## Diagnostic Commands

### Check Plugin Status

```bash
# Verify plugin is loaded
pvesm pluginlist

# Check storage status
pvesm status

# List volumes
pvesm list <storage-id>
```

### Check Pure Storage Connectivity

```bash
# Test API access
curl -k -H "api-token: TOKEN" https://<PURE_IP>/api/1.19/array

# List volumes
curl -k -H "api-token: TOKEN" https://<PURE_IP>/api/1.19/volume

# List hosts
curl -k -H "api-token: TOKEN" https://<PURE_IP>/api/1.19/host
```

### Check Block Device Status

```bash
# List block devices
lsblk

# Check multipath
multipathd show maps
multipathd show paths

# Check iSCSI
iscsiadm -m session -P 3
```

### Check Logs

```bash
# PVE daemon logs
journalctl -u pvedaemon -f

# System messages
dmesg | tail -100

# iSCSI logs
journalctl -u iscsid -f
```

## Getting Help

If you continue to experience issues:

1. Check PVE forum for similar issues
2. Review Pure Storage support documentation
3. Open an issue on GitHub with:
   - PVE version
   - Pure Storage model and Purity version
   - Error messages
   - Relevant log output
