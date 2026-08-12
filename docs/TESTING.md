# Pure Storage Plugin — Test Plan

語言 / Language: [English](TESTING.md) | [繁體中文](TESTING_zh-TW.md)

This test plan validates the jt-pve-storage-purestorage Proxmox VE plugin
against a real Pure Storage FlashArray. It is intended to be run before
each release and especially before deploying to production.

The plan is **Pure-Storage-specific**: every section calls out array
characteristics that distinguish Pure from other vendors and the failure
modes that are unique to Pure or to this plugin's design.

## Author
Jason Cheng (Jason Tools) — jason@jason.tools

---

## 0. Test Environment Requirements

Required:

- Proxmox VE 9.1+ cluster (3 nodes recommended; 2 minimum to validate
  cluster behavior; 1 node is enough for the basic lifecycle tests).
- Pure Storage FlashArray with REST API reachable (any 1.x or 2.x version
  the plugin supports — both code paths must be exercised separately).
- iSCSI **and/or** FC connectivity from every PVE node to the array. Tests
  with both protocols require running the plan twice.
- Pure host objects pre-cleaned: no leftover `pve-*` hosts from previous
  test runs (the plugin will create them, but stale state can mask bugs).
- Multipath service running, with the Pure-friendly settings recommended
  in postinst (`no_path_retry 30`, `dev_loss_tmo 60`, `fast_io_fail_tmo 5`).

Highly recommended:

- A non-Pure storage attached on the same nodes (e.g. a manually-created
  iSCSI LUN with LVM-thin, an NFS share, a ZFS pool). Several tests in
  Section 6 explicitly verify the plugin does NOT touch unrelated storage.
- An ActiveCluster pod test array, if testing pod-mode (Section 11).
- An admin account on the array with permission to disable/enable host
  ports — needed for the failure-injection tests in Section 8.

Test data conventions:

- `STOREID=pure1` (whatever you choose for `pvesm add`)
- `VMID=9001` for the primary test VM, increments for derivatives
- `WWID=3624a9370...` (Pure WWID prefix is `3624a9370`)

---

## 1. Basic Connectivity & Storage Activation

| # | Test | Expected | Pure-specific check |
|---|------|----------|---------------------|
| 1.1 | `pvesm add purestorage pure1 ...` with API token | Storage added | `pvesm status` shows pure1 active |
| 1.2 | `pvesm status pure1` returns within 5s on healthy array | Active, total/used/avail populated | Reads `arrays?space=true` (API 2.x) or `array?space=true` (1.x) |
| 1.3 | `pvesm status pure1` returns within 35s on **unreachable** array | Inactive (0,0,0,0), no PVE daemon hang | Section 4 timeout cap (15s × 2 retries = ~34s) is honored |
| 1.4 | iSCSI: `iscsiadm -m session` shows N sessions where N == number of Pure iSCSI portals | All portals logged in | Tests Section 2.1 per-portal login (Pure controllers share IQN) |
| 1.5 | iSCSI: re-running `pvesm status` does not re-discover already-logged-in portals | No new `iscsiadm -m discovery` calls | Verifies activate_storage skip-if-logged-in optimization |
| 1.6 | FC: `cat /sys/class/fc_host/host*/port_state` shows Online | All HBA ports Online | FC HBAs detected via `is_fc_available()` |
| 1.7 | Pure host object created on array with this node's IQN/WWPNs | Host visible in Pure UI as `pve-<cluster>-<node>` | Verifies `_ensure_host` create-if-missing |
| 1.8 | Concurrent `pvesm status` on 3 nodes during fresh activation | All succeed, no 409 Conflict failures | Tests host_get_or_create race handling (Section 2.5) |
| 1.9 | API token rotated externally → `pvesm status` next call | First call may warn 401, second succeeds (re-auth) | Tests Section 4.1 401 retry with re-auth |

**Critical Pure characteristic:** Pure controllers expose iSCSI on multiple
portal IPs but share a single IQN per array. A naive `is_target_logged_in()`
that checks only the IQN will skip every portal after the first one. Test
1.4 directly validates `is_portal_logged_in()`.

---

## 2. VM Disk Lifecycle (single node)

| # | Test | Expected |
|---|------|----------|
| 2.1 | Create VM with one 10G disk on pure1 | Disk created, volume `pve-pure1-9001-disk0` visible on Pure |
| 2.2 | `qm start 9001`, then `dd if=/dev/zero of=/dev/sdX bs=1M count=100` inside the guest | I/O succeeds, Pure UI shows 100MB used |
| 2.3 | `qm shutdown 9001` → `qm destroy 9001` | Volume marked **destroyed** on Pure (NOT eradicated) |
| 2.4 | After destroy: `multipath -ll \| grep <wwid>` | No stale entry for the deleted volume |
| 2.5 | After destroy: `cat /var/lib/pve-storage-purestorage/pure1-wwids.json` | WWID entry removed |
| 2.6 | After destroy: open Pure UI → Destroyed Volumes | Volume listed there, recoverable for 24h |
| 2.7 | Manual recovery via Pure UI within 24h | Volume restored, `list_images` sees it again |

**Pure characteristic — soft delete:** Pure does not actually destroy a
volume on `volume_delete`; it moves it to "destroyed" state with a
configurable eradication delay (default 24h). Test 2.6/2.7 confirms the
plugin uses `skip_eradicate => 1` so admins can recover from accidental
deletions.

---

## 3. VM Operations: Snapshot, Resize, Move, Clone

| # | Test | Expected | Pure-specific |
|---|------|----------|---------------|
| 3.1 | `qm snapshot 9001 snap1` | Snapshot `<vol>.pve-snap-snap1` created on Pure | Suffix uses Pure-allowed chars only (alphanumeric + hyphen) |
| 3.2 | Snapshot with name containing underscore (`my_snap`) | Encoded suffix (e.g. `my-snap` or `pve-snap-my-snap`), no API error | Tests `encode_snapshot_name` |
| 3.3 | Snapshot with very long name (> 30 chars) | Encoded name + suffix together stay under Pure's 63-char volume name limit | Tests config-volume name truncation in `encode_config_volume_name` |
| 3.4 | `qm rollback 9001 snap1` | Volume rolled back, VM boots from snapshot state | Pure copy-on-write is instant; verify rollback completes in <5s |
| 3.5 | `qm delsnapshot 9001 snap1` | Snapshot removed (skip_eradicate) | Snapshot in "destroyed" state on Pure |
| 3.6 | `qm resize 9001 scsi0 +5G` while VM stopped | Volume resized on Pure | Pure supports online resize, but PVE does offline path here |
| 3.7 | `qm resize 9001 scsi0 +5G` while VM running | Online resize, guest sees new size after rescan | Tests rescan in volume_resize |
| 3.8 | `qm resize 9001 scsi0 -1G` (shrink) | **Refused** with clear error | Pure does not allow shrinking |
| 3.9 | `qm move-disk 9001 scsi0 local-zfs` (Pure → other) | Disk moved, Pure volume freed, no stale device | Validates free_image cleanup at end of move |
| 3.10 | `qm move-disk 9001 scsi0 pure1` (other → Pure) | Disk moved to Pure, qemu-img completes | Allocates via alloc_image, then writes via path()-returned device |
| 3.11 | Full clone (`qm clone 9001 9002`) of running VM | New VM created, qemu-img copies content via PVE | Pure full clone goes through PVE — slower than linked clone |
| 3.12 | Mark VM as template (`qm template 9001`) | `pve-base` snapshot created on the volume | Verifies clone_image's template path |
| 3.13 | Linked clone from template (`qm clone 9001 9003`) | Instant clone via Pure volume_clone | Should complete in <2s — Pure is copy-on-write |
| 3.14 | Linked clone format check | Returned volname is `base-9001-disk-0/vm-9003-disk-0` | Verifies linked clone naming |
| 3.15 | Cloud-init disk attach (`qm set 9001 --ide2 pure1:cloudinit`) | 4MB cloudinit volume created | Special-case path in alloc_image |
| 3.16 | EFI disk on Pure (`qm set 9001 --efidisk0 pure1:1`) | 4MB EFI vars volume created | Same special-case |
| 3.17 | TPM state on Pure (`qm set 9001 --tpmstate0 pure1:4`) | 4MB TPM volume created | Same |
| 3.18 | LXC container disk on Pure (`pct create 9100 ... --rootfs pure1:8`) | rootfs allocated, container starts | Plugin reports rootdir + images content |

---

## 4. Add/Remove Disks on Existing VM (hot-plug stress)

These are the operations most likely to leave residual state on the wrong
node and were the original trigger for the cluster cleanup architecture.

| # | Test | Expected |
|---|------|----------|
| 4.1 | `qm set 9001 --scsi1 pure1:8` (cold add) | New volume created, mapped to all nodes |
| 4.2 | `qm set --delete scsi1 9001` (cold remove) | Volume destroyed, no stale device on ANY node |
| 4.3 | While VM running: `qm set 9001 --scsi1 pure1:8` (hot-plug) | Disk visible inside guest, no node hangs |
| 4.4 | While VM running: `qm set --delete scsi1 9001` (hot-unplug) | Disk removed from guest, no stale device |
| 4.5 | After 4.4: `multipath -ll` on **every** node | No leftover entries for that WWID anywhere |
| 4.6 | After 4.4: WWID JSON file on **every** node | Entry removed |
| 4.7 | `qm unlink 9001 --idlist scsi1 --force` | Volume unlinked from VM config, then freed |

---

## 5. Snapshot Access (temporary clone path)

Pure snapshots cannot be mounted directly — the plugin creates a temporary
volume clone for snapshot read access. This is a Pure-unique characteristic.

| # | Test | Expected |
|---|------|----------|
| 5.1 | `pvesm extractconfig pure1:vm-9001-disk-0/snap1` | Reads from a temp clone, returns config |
| 5.2 | After 5.1: temp clone visible on Pure | Named `<vol>-temp-snap-access-<ts>-<pid>` |
| 5.3 | After 5.1 + 30s + `pvesm status` | Background cleanup leaves the temp clone alone (under 1h) |
| 5.4 | After 5.1 + manual `_cleanup_orphaned_temp_clones` after 1h+ | Temp clone destroyed |
| 5.5 | Backup VM (`vzdump 9001 --storage pure1` or local) | Reads via snapshot path, completes successfully |
| 5.6 | Restore VM from vzdump backup to Pure | New volume allocated, content restored |
| 5.7 | Backup with `snapshot` mode | Plugin creates Pure snapshot, reads via temp clone, cleans up |
| 5.8 | Backup with `stop` mode | No snapshot path needed |
| 5.9 | VM config backup volume (`pve-pure1-9001-vmconf-snap1`) created on Pure snapshot | 1MB ext4 volume with VM config + metadata |
| 5.10 | `pve-pure-config-get pure1 9001 snap1` | CLI tool retrieves the config via the backup volume |
| 5.11 | `pve-pure-config-get --restore pure1 9001 snap1` | Restores the VM config to /etc/pve/qemu-server/9001.conf |

---

## 6. Cluster Residual / Orphan Cleanup (the architecture this plugin
exists for)

This is the **most important section**. The reason the plugin maintains a
WWID tracking file and runs orphan cleanup in `status()` is precisely
because Pure volumes get auto-discovered by iSCSI rescan on every cluster
node, and a delete on one node leaves stale devices on the others.

### 6.1 Auto-import on cluster activation

| # | Test | Expected |
|---|------|----------|
| 6.1.1 | Fresh node added to cluster: `pvesm status pure1` | After ~one minute, `<storeid>-wwids.json` contains all current Pure volume WWIDs the node can see |
| 6.1.2 | The WWID file matches the array's `pve_*` LUN list | All array LUNs auto-imported |
| 6.1.3 | A volume created on node A → after `pvesm status` on node B | Node B's WWID file has the new entry (from auto-import) |

### 6.2 Cluster orphan cleanup

| # | Test | Expected |
|---|------|----------|
| 6.2.1 | Create VM 9001 disk on **node A** | volume + multipath device on all nodes |
| 6.2.2 | Verify `multipath -ll \| grep <wwid>` on nodes A/B/C | All three see the device |
| 6.2.3 | Verify WWID file on nodes A/B/C contains the wwid | Yes (A from path(), B/C from auto-import) |
| 6.2.4 | Destroy VM on node A | Volume gone from array, A's local device cleaned, A's WWID untracked |
| 6.2.5 | Immediately on B: `multipath -ll \| grep <wwid>` | Stale entry **still present** (no event has triggered cleanup yet) |
| 6.2.6 | On B: `pvesm status pure1` (which fires the double-fork cleanup) | Within ~5s the orphan-cleanup pass cleans the stale device |
| 6.2.7 | After 6.2.6: `multipath -ll` on B and C | No stale entry anywhere |
| 6.2.8 | After 6.2.6: WWID file on B and C | Entry removed |
| 6.2.9 | Repeat 6.2.4 with cleanup blocked (mock failure) | WWID stays tracked, next `pvesm status` retries cleanup |

### 6.3 Mixed environment safety (the `multipath -F` lesson)

| # | Test | Expected |
|---|------|----------|
| 6.3.1 | Attach a manual non-Pure iSCSI LUN with no I/O | Multipath sees a non-`PURE` device |
| 6.3.2 | Run several `pvesm status pure1` cycles | The non-Pure device is **never** touched, listed, or warned about |
| 6.3.3 | Attach a manual Pure LUN (outside this plugin) → Pure shows it | Plugin's orphan cleanup logs a Phase 3 warning but does **not** auto-clean |
| 6.3.4 | Grep code/postinst for `multipath -F` | Only appears in safety warnings; never as an executable command |
| 6.3.5 | Call `multipath_flush()` with no argument from a one-liner | Croaks with safety message |

---

## 7. PVE Workflow Operations

| # | Test | Expected |
|---|------|----------|
| 7.1 | `qm start/stop` cycle 10x on the same VM | No file leak, no session leak, no stale device |
| 7.2 | `qm reboot` | Volume stays connected |
| 7.3 | `qm migrate 9001 nodeB` (online migration) | Volume already mapped to nodeB, migration succeeds without LUN re-add |
| 7.4 | `qm migrate 9001 nodeB --online --with-local-disks` (storage migration to Pure on B) | New volume on Pure, content moved, source volume freed |
| 7.5 | `vzdump 9001 --storage local --mode snapshot` | Reads via Pure snapshot temp clone, no leftover temp clone |
| 7.6 | `qmrestore <backup> 9050 -storage pure1` | Disks restored on Pure |
| 7.7 | Multi-disk VM (4× Pure disks): create, snapshot, rollback, destroy | All disks handled, no orphans, single config-volume backup shared |
| 7.8 | VM with vmstate (`qm snapshot --vmstate`) | State volume `vm-9001-state-snap1` allocated on Pure, written, cleaned up on delsnapshot |

---

## 8. Failure Injection (Pure-specific)

These tests require coordination with the array admin to disable/enable
ports, or use the iptables alternative.

### 8.1 Single iSCSI LIF blocked

```
# Block one Pure controller iSCSI port via iptables on the PVE host:
iptables -I OUTPUT -d <pure_ct0_iscsi_ip> -j DROP
```

| # | Test | Expected |
|---|------|----------|
| 8.1.1 | While running `dd` inside the guest | I/O continues over remaining paths |
| 8.1.2 | `multipath -ll` shows path failed | Other paths still active |
| 8.1.3 | `pvesm status pure1` | Still returns in <35s, no D-state |
| 8.1.4 | Remove iptables rule, wait `replacement_timeout` | Path automatically restored |

### 8.2 All iSCSI portals blocked

```
iptables -I OUTPUT -d <pure_mgmt_ip> -j DROP
iptables -I OUTPUT -d <pure_ct0_iscsi_ip> -j DROP
iptables -I OUTPUT -d <pure_ct1_iscsi_ip> -j DROP
```

| # | Test | Expected |
|---|------|----------|
| 8.2.1 | `pvesm status pure1` | Returns inactive within ~35s |
| 8.2.2 | No PVE daemon hang, `pveproxy` web UI still responsive | Yes |
| 8.2.3 | Any process in D state? `ps -eo state,pid,cmd \| grep '^D'` | None |
| 8.2.4 | After unblocking, `pvesm status pure1` | Recovers to active |

### 8.3 API unreachable

```
iptables -I OUTPUT -d <pure_mgmt_ip> -p tcp --dport 443 -j DROP
```

| # | Test | Expected |
|---|------|----------|
| 8.3.1 | `pvesm status pure1` | Returns (0,0,0,0) within ~35s |
| 8.3.2 | Operations on existing VMs (start/stop) still work | Yes — only API-dependent ops fail fast |
| 8.3.3 | Web UI shows storage as inactive but doesn't freeze | Yes |

### 8.4 Pure controller failover

| # | Test | Expected |
|---|------|----------|
| 8.4.1 | While running `dd` in the guest, ask Pure admin to fail over CT0 → CT1 | I/O pauses briefly (replacement_timeout window), then resumes |
| 8.4.2 | `multipath -ll` shows the formerly-active paths failed | Yes |
| 8.4.3 | After failback: `multipath -ll` shows all paths active | Yes |

### 8.5 The "queue_if_no_path" + stale device hang scenario

This is the bug class that drove the entire residual cleanup design. It
must be reproducible **before** the fix and not after.

| # | Test | Expected |
|---|------|----------|
| 8.5.1 | Set `no_path_retry queue` in /etc/multipath.conf, restart multipathd | Setting active |
| 8.5.2 | Allocate a Pure volume on this node, get its multipath device | Device exists |
| 8.5.3 | On the array (Pure UI / API), **manually delete** the volume without going through the plugin | Volume gone from array |
| 8.5.4 | `pvesm status pure1` → triggers orphan cleanup pass | Stale device cleaned **without** any process going into D state |
| 8.5.5 | `ps -eo state \| grep '^D'` after the test | No D-state processes |
| 8.5.6 | Compare with a previous plugin version (1.0.x): repeat 8.5.3 then `vgs` | The old version hangs `vgs` in D state — proves the regression test |

### 8.6 Concurrent free_image race

| # | Test | Expected |
|---|------|----------|
| 8.6.1 | Two nodes simultaneously delete the same VM | Both succeed (one wins on volume_delete; the other gets "not found" → no-op) |
| 8.6.2 | Concurrent disk add to the same VM from two PVE workers | One succeeds, the other catches collision and bumps disk-id (Section 7.1 retry loop) |

---

## 9. API Version Coverage

The plugin supports both Pure REST API 1.x and 2.x. Both code paths must
be tested.

| # | Test | Expected |
|---|------|----------|
| 9.1 | Force API 1.x: `--api-version 1.19` in storage config | All sections 1–8 pass against the same array via 1.x |
| 9.2 | Force API 2.x: `--api-version 2.26` | All sections 1–8 pass against the same array via 2.x |
| 9.3 | Auto-detect: omit api-version | Plugin picks 2.x, logged at activate |
| 9.4 | API 2.x PATCH host with WWNs from a second node | Verify the host's wwns array contains BOTH nodes' WWPNs (test the fetch-merge-patch fix) |
| 9.5 | API 2.x volume name with `pod::` prefix in query string | Plugin URL-encodes `::` correctly, no 400 |

---

## 10. Naming Edge Cases

| # | Test | Expected |
|---|------|----------|
| 10.1 | Snapshot name `my-snap` (already valid) | Used as-is |
| 10.2 | Snapshot name `my_snap` (underscore) | Encoded — verify decode round-trip |
| 10.3 | Snapshot name with mixed case | Encoded as-is, decoded correctly |
| 10.4 | Storage name with hyphen (`pure-prod`) | Volume names use underscore (`pve_pure_prod_*`) |
| 10.5 | VM ID > 9999 | Volume name still under Pure's 63-char limit |
| 10.6 | Long snapshot name forcing truncation in config volume | `_backup_vm_config` truncates the snapname so total stays ≤ 63 chars |
| 10.7 | Cluster name with dots | Host name `pve-<cluster>-<node>` is sanitized |

---

## 11. Pod (ActiveCluster) Mode — only if pod is configured

| # | Test | Expected |
|---|------|----------|
| 11.1 | `pvesm add purestorage pure-pod1 --pure-pod testpod ...` | Storage active, all volumes get `testpod::` prefix |
| 11.2 | Create VM disk → volume name `testpod::pve-...` on array | Yes |
| 11.3 | `list_images` strips `testpod::` for PVE display | Yes |
| 11.4 | `parse_volname` handles state/cloudinit volumes inside pod | Tests the 1.0.49 fix where pod prefix wasn't being stripped before decode |
| 11.5 | Pod failover (admin action) → I/O continues on stretched cluster | Yes |
| 11.6 | Pod-to-array migration: change pod config, restart storage | Volumes still listed correctly |

---

## 12. Per-Node vs Shared Host Mode

| # | Test | Expected |
|---|------|----------|
| 12.1 | `pure-host-mode per-node` (default): each node has its own Pure host | One host per node, host name `pve-<cluster>-<nodename>` |
| 12.2 | `pure-host-mode shared`: single shared host with all WWPNs | One host `pve-<cluster>-shared` containing all nodes' WWPNs |
| 12.3 | Shared mode + `_connect_to_all_hosts` | Connects only the single shared host (no iteration) |
| 12.4 | per-node + `_connect_to_all_hosts` | Connects to every `pve-<cluster>-*` host returned by `host_list` |

---

## 13. Performance / Sanity

| # | Test | Acceptable |
|---|------|------------|
| 13.1 | `pvesm status pure1` p50 latency | < 1s |
| 13.2 | `pvesm status pure1` p99 latency | < 5s |
| 13.3 | `pvesm status pure1` worst case on unhealthy array | < 35s |
| 13.4 | `qm clone` linked clone wall time | < 5s |
| 13.5 | `qm clone` full clone of 10G volume wall time | bounded by qemu-img copy speed (PVE limitation) |
| 13.6 | `pvesm list pure1` for a storage with 200 volumes | < 10s (template detection deadline kicks in if needed) |
| 13.7 | 10 concurrent alloc_image in a loop | All succeed, no leaked volumes or devices |

---

## 14. Upgrade Path

| # | Test | Expected |
|---|------|------------|
| 14.1 | Install 1.0.49 → run sections 1-3 → upgrade to 1.1.0 → re-run sections 1-3 | All pass |
| 14.2 | After upgrade, postinst warns about pre-existing stale Pure devices (if any) | Yes (Section 6.2 of postinst) |
| 14.3 | After upgrade, postinst warns about dangerous multipath.conf settings (if any) | Yes |
| 14.4 | After upgrade, `<storeid>-wwids.json` is created on first `pvesm status` | Yes (auto-import) |
| 14.5 | Old running VMs continue to work without restart | Yes |

---

## 15. Test Result Recording

For each release, copy this template into `docs/RELEASE_NOTES.md` (or
attach to the release):

```
Plugin version: 1.x.y-1
Tested on: PVE 9.1.x, kernel 6.x.x
Pure FlashArray model: //X70R3 (or whichever)
Pure Purity//FA version: 6.x.x
API version tested: [1.19] [2.26]
Protocols tested: [iSCSI] [FC]
Cluster size: 3 nodes
Test runner: <name>
Test date: YYYY-MM-DD

Sections passed: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
Sections skipped: <list with reason>
Sections failed: <none expected>

Critical scenarios verified:
[ ] Section 8.5 (queue_if_no_path + stale device, no D-state hang)
[ ] Section 6.2 (cluster orphan cleanup E2E)
[ ] Section 4 (hot-plug/unplug stale prevention)
[ ] Section 1.4 (per-portal iSCSI login on Pure shared IQN)
```

---

## 16. Symlink Resolution Regression Tests (1.1.2)

These tests guard against the four bugs fixed in 1.1.2. Each test directly
exercises one of them. They MUST pass before any release that touches
`is_device_in_use`, `get_multipath_slaves`, `volume_resize`, or
`volume_snapshot_rollback`.

### 16.1 Resize on a running VM (Bug A regression)

```bash
qm create 8000 --name resize-test --memory 256 --cores 1 \
  --scsi0 pure1:1 --kvm 0
qm start 8000
sleep 5

# Should succeed without "Cannot grow device files"
qm resize 8000 scsi0 +1G

# Verify host actually sees the new size
DEV=$(pvesm path pure1:vm-8000-disk-0)
blockdev --getsize64 $DEV   # expected: 2147483648 (2 GB)

qm stop 8000
qm destroy 8000 --purge
```

**Pass criteria:** `qm resize` returns 0, no `Cannot grow device files`,
`blockdev --getsize64` shows the new size on the multipath device.

### 16.2 LVM-on-Pure data-loss prevention (Bug D regression — CRITICAL)

```bash
# Allocate a Pure-backed volume
pvesm alloc pure1 8000 vm-8000-disk-0 1G
DEV=$(pvesm path pure1:vm-8000-disk-0)

# Put LVM on top — simulates a customer using the Pure volume as a PV
pvcreate $DEV
vgcreate test_vg $DEV
lvcreate -L 100M -n test_lv test_vg
mkfs.ext4 /dev/test_vg/test_lv
mkdir -p /mnt/test
mount /dev/test_vg/test_lv /mnt/test

# is_device_in_use MUST return true now
perl -Ilib -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::PureStorage::Multipath qw(is_device_in_use);
my $r = is_device_in_use($ARGV[0]);
print "in_use=$r\n";
exit($r ? 0 : 1);
' "$DEV"

# Trying to free_image while in use MUST refuse, not silently delete
pvesm free pure1:vm-8000-disk-0 2>&1 | grep -i "in use"

# Cleanup
umount /mnt/test
lvremove -f test_vg/test_lv
vgremove test_vg
pvremove $DEV
pvesm free pure1:vm-8000-disk-0
```

**Pass criteria:**
- `is_device_in_use` returns 1
- `pvesm free` refuses with an in-use error message
- LVM data on the volume remains intact after the failed free attempt

**Fail mode (data loss bug):** if `is_device_in_use` returns 0, `pvesm
free` will silently destroy the volume and the customer's LVM data is
gone. This is the production scenario the 1.1.2 fix prevents.

### 16.3 get_multipath_slaves on /dev/mapper/<wwid> (Bug C regression)

```bash
DEV=$(pvesm path pure1:vm-8000-disk-0)   # /dev/mapper/3624a9370...
perl -Ilib -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::PureStorage::Multipath qw(get_multipath_slaves);
my $s = get_multipath_slaves($ARGV[0]);
print "slaves=", scalar(@$s), "\n";
print "  $_\n" for @$s;
exit(@$s > 0 ? 0 : 1);
' "$DEV"
```

**Pass criteria:** returns N slaves where N matches the number of active
paths shown by `multipath -ll`. Pre-fix this function returned 0 for
`/dev/mapper/<wwid>` paths.

### 16.4 Snapshot rollback cache invalidation (Bug B regression)

```bash
# Create a volume, write a known pattern
qm create 8000 --memory 256 --scsi0 pure1:1 --kvm 0
DEV=$(pvesm path pure1:vm-8000-disk-0)
dd if=/dev/zero of=$DEV bs=1M count=1 conv=fsync

# Snapshot
qm snapshot 8000 snap1

# Overwrite with a different pattern
dd if=/dev/urandom of=$DEV bs=1M count=1 conv=fsync

# Read first byte (should be the random pattern, not zero)
HEX_BEFORE=$(dd if=$DEV bs=1 count=4 2>/dev/null | xxd | head -1)

# Rollback
qm rollback 8000 snap1

# Read first byte again — MUST be zero (the snapshot pattern), not the
# stale random pattern from the page cache
HEX_AFTER=$(dd if=$DEV bs=1 count=4 iflag=direct 2>/dev/null | xxd | head -1)
echo "before rollback: $HEX_BEFORE"
echo "after  rollback: $HEX_AFTER"

qm destroy 8000 --purge
```

**Pass criteria:** reads after rollback return the snapshot content
(zeros), not the post-snapshot random pattern. Pre-fix the page cache
held the post-snapshot pages and reads silently returned stale data.

---

## 17. iSCSI Host Filter Regression Test (1.1.5)

This test guards against the Bug 1 regression: `rescan_scsi_hosts()`
must NEVER write to a non-iSCSI scsi_host. Required on any host that
has mixed scsi_host transports (almost any real server has at least
the on-board SATA controller as `host0`).

```bash
# Show the host inventory
echo "All scsi_host:"
ls /sys/class/scsi_host/
echo "iSCSI-only:"
ls /sys/class/iscsi_host/ 2>/dev/null || echo "(no iSCSI active)"

# Strace the rescan to see exactly which scan files get written
strace -f -e trace=openat 2>&1 \
  perl -I/usr/share/perl5 \
       -e 'use PVE::Storage::Custom::PureStorage::Multipath qw(rescan_scsi_hosts);
           rescan_scsi_hosts(delay => 0)' \
  | grep -oE "/sys/class/scsi_host/host[0-9]+/scan" \
  | sort -u
```

**Pass criteria:** the strace output must contain ONLY the host
numbers that appear in `/sys/class/iscsi_host/`. If you see any host
that is not in the iSCSI list (e.g. `host0/scan` when `host0` is the
SATA controller), the fix is broken and the bug is back.

**Why this matters:** writing to a non-iSCSI host's scan file on
HPE smartpqi / Dell PERC / LSI HBA causes a 600+ second D-state hang
inside the kernel. `sysfs_write_with_timeout` does not protect
against this — D-state children cannot be reaped by SIGKILL. The
ONLY safe protection is to never issue the operation in the first
place.

---

## Quick smoke test (5 minutes, single node)

If full test plan is too long, the absolute minimum smoke test is:

1. `pvesm status pure1` returns active in < 5s
2. Create a 1GB disk on a test VM, start it, write 100MB, stop, destroy
3. `multipath -ll | grep <wwid>` after destroy → empty
4. `cat /var/lib/pve-storage-purestorage/pure1-wwids.json` after destroy → entry removed
5. `pvesm status pure1` again → still returns in < 5s

If all five pass, the plugin is at least minimally functional. Run the
full plan before any production deployment or release.

---

## Before every release — the operational checklist

Adapted from the checklist the sibling `jt-pve-storage-synology` project uses.
Its opening point applies here unchanged, and was re-measured on this node:

**Drive it from the web interface.** `pvedaemon` and `pveproxy` run as
`#!/usr/bin/perl -T` **with no `PATH` at all** — `/proc/<pid>/environ` for
pvedaemon, pvestatd and pveproxy carries none — while `qm`, `pvesm` and `pvesh`
are plain `perl` with a shell's environment. `multipath`, `multipathd`,
`iscsiadm`, `dmsetup`, `blockdev` and `kpartx` all live in `/usr/sbin`, which is
not on the fallback `/bin:/usr/bin`. **A run from a shell is a regression
check, not a verification.**

Stages B through H need a reachable Pure FlashArray. No other vendor's array can
stand in: this plugin negotiates Pure's REST API, derives every WWID from the
Pure OUI prefix `3624a9370`, and scopes its multipath block on the SCSI inquiry
strings `vendor "PURE"` / `product "FlashArray"`. Pointed at anything else it
fails at the first call.

| | Operation | What it exercises |
|---|---|---|
| **A1–A4** | Add · update credentials · remove a storage | `on_add_hook`, `on_update_hook_full`, `on_delete_hook`, the credential store in `/etc/pve/priv/storage`. Not reachable from the GUI — PVE hardcodes its storage-type list |
| **B1** | Add a disk | `alloc_image`, host registration, first LUN map |
| **B2** | Resize, running and stopped | `volume_resize`, then the local refresh — the map must reach the new size, not just the array |
| **B3** | Move to another storage and back | the `qemu-img` path over `path()` |
| **B4** | Detach and remove | `free_image`: the in-use guard, disconnect, `kpartx -d`, flush, tombstone rename, destroy, untrack |
| **C1 · C2** | Snapshot, running and stopped | `volume_snapshot`, the host cache flush, the config-backup volume |
| **C3** | Roll back | `volume_snapshot_rollback`, the fail-closed idle guard, cache invalidation |
| **C4** | Delete a snapshot | the temp-clone sweep that runs from it |
| **C5** | `bin/pve-pure-config-get --list` and a restore | the disaster-recovery tool against a real config-backup volume |
| **D1** | Stop and start | `activate_volume`: session rescan, WWID confirmation, map creation, size reconciliation |
| **D2** | Migrate away and back, offline and online | that the source node is left clean |
| **D3 · D4 · D5** | Full clone · clone from a snapshot · template then linked clone | `clone_image`, `create_base`, and `list_images` reporting the `base/clone` form |
| **E1 · E2 · E3** | Backup in all three `vzdump` modes | the snapshot-access temp clone, and its release |
| **E4 · E5** | Restore to a new VM ID · overwrite the original | `alloc_image` and `free_image` back to back |
| **F1–F3** | Orphan reaping with a guest running on the storage | the in-use guard, the grace period and the absence hysteresis |
| **G1–G9** | The container path | `pct` drives `path()`, `activate_volume`, `volume_size_info` and resize directly, and runs under `-T` |
| **H1–H4** | Snapshot, resize, clone and migration killed part-way | what each leaves on the array and on the host — see the table in `TROUBLESHOOTING.md` |

### What has been run without an array

These stages need no hardware and were driven on a Proxmox VE 9 node
(`libpve-storage-perl` 9.1.6, `APIVER` 15):

| | Result |
|---|---|
| A1 · A2 — add a storage, update its credentials | pass. The token never reaches `storage.cfg`; `/etc/pve/priv/storage/<id>.pure-token` is created `0600` |
| A3 — a storage id that collides with an existing one | pass. Refused at `pvesm add`, with both ids and the shared prefix named |
| A4 — `--delete pure-api-token`, then remove the storage | pass, and it confirms the documented trap: the delete removes the secret file outright, leaving the storage with no credentials. Removing the storage clears both the secret and the config entry |
| Adding an **enabled** storage whose array is unreachable | refused at `pvesm add` with the portal, the URL and whether a token was sent — it does not create a storage that cannot work |
| The plugin driven under `perl -T` with `PATH` deleted | pass, 12 checks: the module loads, `udevadm` resolves, a command carrying a value that came off the array runs and its argument arrives intact, and an argument the plugin could not have produced is refused |
| `multipath -F` is never generated anywhere in the tree | pass, and enforced by a static check |
| Package install, state directories, service reloads | pass. `/var/lib/` and `/var/run/pve-storage-purestorage` are `0700 root:root` |

`/etc/multipath/conf.d/pure-storage.conf` is written by `_ensure_multipath_config()`
from `activate_storage`, so it appears only once a Pure storage is activated —
its absence on a node with no Pure storage is expected. It matters because
multipath-tools' own built-in `PURE`/`FlashArray` entry sets
`path_grouping_policy`, `prio` and `fast_io_fail_tmo 10` but **no
`no_path_retry` and no `dev_loss_tmo`**; the generated file supplies
`no_path_retry 30`, `fast_io_fail_tmo 5` and `dev_loss_tmo 60`.

