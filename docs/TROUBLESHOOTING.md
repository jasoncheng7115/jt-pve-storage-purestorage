# Troubleshooting Guide

語言 / Language: [English](TROUBLESHOOTING.md) | [繁體中文](TROUBLESHOOTING_zh-TW.md)

## Read first: Multipath Safety Rules

Before doing anything with `multipath` on a Pure-using PVE node, remember:

1. **NEVER use `multipath -F`** (capital F). It flushes ALL unused
   multipath maps on the host, including non-Pure storage that happens
   to be idle. Always use lowercase `multipath -f /dev/mapper/<wwid>`
   for a specific device.
2. **Use `systemctl restart multipathd`, NOT `reload`.** Reload only
   re-reads the config file. Restart actually re-applies device-mapper
   state, which is what you want when changing per-device parameters.
3. If a stale multipath device cannot be flushed (because of
   `queue_if_no_path` queueing dead I/O), use this sequence — never
   `-F`:
   ```bash
   multipathd disablequeueing map <wwid>
   dmsetup message <wwid> 0 fail_if_no_path
   multipath -f /dev/mapper/<wwid>
   # If still stuck:
   dmsetup remove --force --retry <wwid>
   ```
4. The plugin (1.1.0+) handles cluster-wide cleanup automatically via
   the WWID tracking file at `/var/lib/pve-storage-purestorage/<storeid>-wwids.json`
   and the orphan-cleanup pass that runs in `pvesm status`. In most
   cases manual cleanup should not be necessary.

## Common Issues

### 1. Storage Not Appearing in PVE

**Symptoms:**
- Storage not visible in PVE Web UI
- `pvesm status` shows storage as unavailable
- `pvesm status` takes 30+ seconds to return

**Solutions:**

1. Check connectivity to Pure Storage management:
   ```bash
   curl -k https://<PURE_IP>/api/2.26/api_version
   ```

2. Verify API token is correct:
   ```bash
   curl -k -X POST https://<PURE_IP>/api/2.26/login \
       -H "api-token: YOUR_TOKEN" -i
   ```
   You should get HTTP 200 with an `x-auth-token` response header.

3. Check PVE logs:
   ```bash
   journalctl -u pvedaemon -f
   ```

4. If `pvesm status` returns slowly (10-35s), the API is unreachable.
   The plugin fails fast at 15s × 2 retries = ~34s worst case. Anything
   longer means the request layer is broken — check firewall, DNS, MTU.

### 2. Volume Creation Fails

**Symptoms:**
- Error when creating VM disk
- "Failed to create volume" message

**Solutions:**

1. Check Pure Storage capacity (Web UI > Storage > Array space).

2. Verify Pure host object exists (check Web UI > Storage > Hosts):
   - Per-node mode: should see `pve-<cluster>-<nodename>`
   - Shared mode: should see `pve-<cluster>-shared`

3. Check for naming conflicts in Pure UI under Storage > Volumes.

4. Concurrent allocations on the same VM may collide on disk-id; the
   plugin retries up to 5 times. If you hit a persistent collision,
   one of the workers may have left a partial volume — check Pure UI
   for orphaned `pve-*` volumes.

### 3. Device Not Appearing After Volume Creation

**Symptoms:**
- VM disk created on the array but device path not found locally
- VM fails to start with "cannot find device" error

**Solutions:**

1. Verify volume is connected to this node's host (Pure UI > Volumes >
   the volume > Connected Hosts).

2. Check iSCSI sessions (one session per Pure portal):
   ```bash
   iscsiadm -m session
   ```
   Pure controllers share one IQN across multiple LIFs, so you should
   see N sessions where N is the number of Pure iSCSI portals.

3. Force a rescan (the plugin does this automatically; only needed for
   manual debugging):
   ```bash
   iscsiadm -m session --rescan
   for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h"; done
   multipathd reconfigure
   udevadm trigger --subsystem-match=block
   udevadm settle --timeout=5
   ```

4. Check multipath status:
   ```bash
   multipathd show maps
   multipathd show paths
   multipath -ll | grep -A4 "PURE"
   ```

5. The plugin's `path()` retry loop runs up to `pure-device-timeout`
   seconds (default 30, configurable per-storage). If it still can't
   find the device, you'll see a clear error with `multipath -ll`
   debugging hints in the message.

### 4. `qm resize` fails with "Cannot grow device files"

**Symptom:** Pure shows the new volume size but PVE / QEMU reports
`Cannot grow device files`.

**Cause:** Was the resize bug fixed in 1.1.2 — the host scan after
`volume_resize` did not refresh the existing device's capacity. If
you're on 1.1.2 or later this should not happen.

**If it still happens after upgrading to 1.1.2+:**

```bash
# Manually do what the plugin should have done:
WWID=$(... look up the volume's WWID ...)
DEV=/dev/mapper/$WWID
SLAVES=$(ls /sys/block/$(basename $(readlink $DEV))/slaves/)
for s in $SLAVES; do echo 1 > /sys/block/$s/device/rescan; done
multipathd resize map $(basename $DEV)
blockdev --getsize64 $DEV   # should now show the new size
```

### 5. Snapshot rollback returns stale data

**Symptom:** After `qm rollback`, the VM reads pre-rollback data.

**Cause:** Was the rollback cache bug fixed in 1.1.2 — the kernel page
cache wasn't invalidated after the rollback. If you're on 1.1.2 or
later this should not happen.

**If it still happens after upgrade,** stop the VM and start it again
to flush qemu's own cache.

### 6. Stale multipath devices on cluster nodes

**Symptom:** `multipath -ll` on node B shows a Pure device that no
longer exists on the array (because node A deleted the volume).

**Solution:** This is exactly what the orphan-cleanup mechanism is
for. Run `pvesm status pure1` on node B; the cleanup pass runs in a
backgrounded grandchild and will clean the stale device within seconds.

If it doesn't (e.g. cleanup itself failed because of a hang), check
the WWID tracking file:

```bash
cat /var/lib/pve-storage-purestorage/<storeid>-wwids.json
```

If the stale WWID is in there but the device is still present, the
cleanup is failing. Check `journalctl -u pvedaemon` for error messages
from `_cleanup_orphaned_devices`. As a last resort, do the manual
cleanup sequence from the safety rules above.

If the stale WWID is NOT in the tracking file but `multipath -ll`
shows it, it's not Pure-managed — maybe a previous plugin version's
residue or a manually-created LUN. The plugin will print a Phase 3
warning about it but will not auto-clean.

### 7. iSCSI session count is wrong

**Symptom:** `iscsiadm -m session` shows fewer sessions than the
number of Pure iSCSI portals.

**Cause (was a 1.0.x bug):** The pre-1.1.0 `is_target_logged_in()`
checked only the IQN, but Pure controllers share one IQN across
multiple LIFs, so the second-and-later portal logins were silently
no-op.

**Fix in 1.1.0+:** Login uses `is_portal_logged_in($portal_addr, $target)`
which checks the (portal, target) pair correctly.

**If you're on 1.1.0+ and still see this:** verify the Pure portals
are reachable from this node (`ping`, `nc -vz <portal_ip> 3260`),
and check `/etc/iscsi/iscsid.conf` for `node.startup = automatic`.

### 8. Authentication errors

**Symptoms:**
- "401 Unauthorized" errors on every API call
- "Authentication failed" messages

**Solutions:**

1. The plugin auto-retries on 401 with re-auth (1.1.0+). If you see
   persistent 401s, the API token is genuinely invalid.
2. Regenerate API token on Pure Storage Web UI (Settings > API Tokens).
3. Update the storage config: `pvesm set pure1 --pure-api-token <NEW_TOKEN>`.
4. Verify user has permissions: Volumes/Hosts/Connections create+delete+read+update.

### 9. `pvesm status` is slow or hangs

**Symptom:** `pvesm status` takes more than 35 seconds, or hangs forever.

**Cause:** API or network issue, OR a wedged multipath device causing
a kernel D-state hang in the cleanup background fork.

**Solutions:**

1. Check `ps -eo state,pid,cmd | grep '^D'`. If you see processes in D
   state, you have a wedged device — see "Stale multipath devices" above.
2. Check API reachability with `curl` (see issue #1).
3. On the health path (`activate_storage` + foreground of `status`) the
   plugin uses a short-timeout, single-attempt client, so a healthy poll
   is bounded by `pure-status-timeout` (default 5s). If `pvesm status`
   takes much longer, something is hanging in the background fork that
   should not block the parent.

### 10. Plugin warns about "DANGEROUS MULTIPATH SETTINGS"

**Symptom:** During `dpkg -i ...purestorage...deb`, postinst prints a
red warning box about `no_path_retry queue` or `dev_loss_tmo infinity`
in `/etc/multipath.conf`.

**This is correct behaviour.** Those settings, combined with stale
Pure devices, can put PVE daemons into uninterruptible sleep requiring
a node reboot. The plugin will NOT auto-modify your config; you must
fix it manually.

Edit `/etc/multipath.conf`, change the `defaults` section:

```
defaults {
    polling_interval        10
    no_path_retry           30      # was: queue
    fast_io_fail_tmo        5
    dev_loss_tmo            60      # was: infinity
}
```

Then `systemctl restart multipathd` (NOT `reload`).

### 11. Plugin warns about "STALE PURE MULTIPATH DEVICES"

**Symptom:** Postinst prints a yellow warning listing Pure multipath
devices with all paths failed.

**This is residue from an older plugin version or a manually-attached
LUN.** The plugin will NOT auto-clean. Use the manual cleanup sequence
from the safety rules above for each listed device.

After cleanup, the next `pvesm status pure1` orphan-cleanup pass will
keep them gone automatically.

### 12. Storage flaps to `inactive` on a busy but healthy array

**Symptom:** A storage intermittently shows `inactive` in the Web UI and
recovers on the next poll, with no array outage. Often appears after a
firmware upgrade that makes the array's management gateway more
load-sensitive, or as the cluster grows.

**Cause:** The management REST endpoint is slow under the cluster's steady
polling load, so a health-path call exceeds `pure-status-timeout`. This is
load, not an outage — disabling the storage cluster-wide makes the array's
management REST get fast again (a backlog draining, e.g. `curl` time_total
falling 19s → 14s → ... → 0.4s).

**Solutions:**

1. Running VMs are unaffected — devices stay mapped; only the status poll
   failed. The storage recovers on the next poll.
2. If it is frequent, raise `pure-status-timeout` (e.g. to 10s) so a slow
   poll succeeds instead of failing — but first reduce the load: confirm
   you are on this version (HTTP keep-alive + no per-poll N+1 REST calls).
3. Count the steady-state REST calls per poll. A storage plugin's
   steady-state management-plane load should be a handful of calls per
   poll; tens of calls/second (objects × nodes × 1/10s) is a design bug.

### 13. New plugin code is not active after an upgrade

**Symptom:** You installed a new `.deb`, postinst reported success, but the
behaviour is unchanged — a fix appears to have no effect.

**Cause:** The package uses `systemctl reload` (SIGHUP) to avoid the
stop-phase hang on D-state children, but on many PVE versions reload does
NOT reload the plugin's Perl modules. `pvestatd` keeps running the OLD code
from memory even though the new files are on disk.

**Solution:** After any plugin upgrade, restart `pvestatd` on **every**
cluster node:

```
systemctl restart pvestatd
```

Verify the restart took effect — the MainPID must change:

```
systemctl show -p MainPID pvestatd     # run before and after; PID MUST change
```

`pvedaemon` and `pveproxy` similarly load plugin code; restart them too if a
Web UI / API path still shows stale behaviour.

## Diagnostic Commands

### Plugin Status

```bash
# Verify plugin is loaded
pvesm pluginlist

# Check storage status (must return < 5s on healthy array)
time pvesm status

# List volumes
pvesm list <storage-id>

# Show WWID tracking state
cat /var/lib/pve-storage-purestorage/<storeid>-wwids.json | python3 -m json.tool
```

### Pure Storage Connectivity

```bash
# API reachability
curl -k https://<PURE_IP>/api/api_version

# Auth
curl -k -X POST https://<PURE_IP>/api/2.26/login -H "api-token: TOKEN" -i

# List volumes (replace SESSION_TOKEN with the x-auth-token from login)
curl -k -H "x-auth-token: SESSION_TOKEN" https://<PURE_IP>/api/2.26/volumes
```

### Block Device Status

```bash
# Pure multipath devices on this node
multipath -ll | grep -A6 "PURE"

# Specific device
multipath -ll <wwid>

# Slave devices for a multipath device
ls /sys/block/$(basename $(readlink /dev/mapper/<wwid>))/slaves/

# Holders (LVM, dm-crypt, etc.) for a multipath device
ls /sys/block/$(basename $(readlink /dev/mapper/<wwid>))/holders/
```

### iSCSI

```bash
# All sessions (should be one per Pure portal)
iscsiadm -m session

# Detailed session view including LUNs
iscsiadm -m session -P 3

# Targets (after discovery)
iscsiadm -m node
```

### Fibre Channel

```bash
# HBA port states (all Online?)
cat /sys/class/fc_host/host*/port_state

# Pure target ports visible via fabric
cat /sys/class/fc_remote_ports/rport-*/port_state
```

### Logs

```bash
# PVE daemon (most plugin warn() output goes here)
journalctl -u pvedaemon -f

# Kernel multipath / SCSI messages
dmesg | grep -E "multipath|scsi|sd|dm-" | tail -50

# iSCSI daemon
journalctl -u iscsid -f

# Postinst warnings (next install)
dpkg -i jt-pve-storage-purestorage_*.deb 2>&1 | tee /tmp/postinst.log
```

## Getting Help

If you continue to experience issues:

1. Run the smoke test from `docs/TESTING.md` Section 16 — those four
   regression tests directly exercise the most-likely-to-bite bug
   classes.
2. Collect the diagnostic output from this guide.
3. Check the project README troubleshooting section.
4. Open an issue on GitHub with:
   - Plugin version (`dpkg -l jt-pve-storage-purestorage`)
   - PVE version (`pveversion`)
   - Pure model and Purity//FA version
   - Error messages and relevant log output
   - Output of `multipath -ll` and `iscsiadm -m session`
   - Contents of `/var/lib/pve-storage-purestorage/<storeid>-wwids.json`
