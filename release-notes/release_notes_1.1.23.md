Data-safety release. Every finding here is one variant of the same design mistake: a safety check that, when it could not complete, answered "safe to proceed" instead of "I do not know". Nothing in this release changes behaviour on a healthy node — it changes what happens on an unhealthy one.

**Recommended for everyone, and particularly urgent if you are on 1.1.22 or use Fibre Channel.**

---

## Why upgrade urgently

- **From 1.1.22**: that release fixed a millisecond/second timestamp bug which, as a side effect, started a background reaper that had never actually run before — and that reaper performed **unrecoverable** volume eradications. 1.1.23 makes every automated deletion recoverable.
- **Fibre Channel users**: up to and including 1.1.22 the plugin issued a **LIP (link reset)** from loops running every 2–3 seconds. See below.

---

## CRITICAL — The in-use guard now fails closed

`is_device_in_use()` collapsed "I could not determine the answer" into "not in use". A `/proc/mounts` read that timed out, a `fuser` call killed by its own 5-second watchdog, or a device path that would not resolve all fell through to `return 0`.

For a raw Pure LUN attached to a running VM there is no mount point and no real holder — the kpartx partitions are deliberately ignored since v1.1.7 — so **`fuser` is the only positive signal that a guest has the device open**. A timed-out `fuser` therefore turned "a VM is using this disk" into "nothing is using this disk", precisely when the node was unhealthy enough for that watchdog to fire, and `free_image()` would go on to disconnect the volume from every host and destroy it.

New `device_usage_state()` returns `in-use` / `idle` / `unknown` with a human-readable reason. `is_device_in_use()` now treats `unknown` as in use, and callers report the reason so an operator sees *why* the plugin refused.

`free_image()`, `volume_snapshot_rollback()` and `create_base()` each did:

```perl
my $wwid = eval { $api->volume_get_wwid($pure_volname); };
if ($wwid) { ... the entire in-use check ... }
... destroy / overwrite anyway ...
```

so a single transient REST error skipped the check and ran the destructive operation unprotected. **Rollback was the worst case**: `volume_overwrite()` replaces the volume's contents outright and, unlike a destroy, has no eradication-delay recovery window. All three now retry once and then refuse with an actionable message.

## HIGH — No automated path eradicates any more

The orphaned temp-clone reaper and the per-session temp-clone cleanup called `volume_delete()` without `skip_eradicate` — permanent deletion, no recovery window, from a background process. Both now soft-destroy, so **all 15 delete call sites in the plugin are recoverable** within the array's eradication delay.

The reaper additionally re-matches every candidate against the exact name `path()` generates (`pve-<storage>-...-temp-snap-access-<unix-ts>-<pid>`) rather than trusting the unanchored array-side glob, and requires **two independent age sources** to agree — the array's `created` timestamp and the unix timestamp baked into the name — before deleting.

## HIGH — Fibre Channel: no more LIP on every rescan

A Loop Initialization Primitive is a **link reset**, not a lookup. It forces every device behind that HBA port to re-login, **including LUNs belonging to other storage on the same HBA**. It contributes nothing to discovering a newly mapped LUN — the SCSI host scan does that via `REPORT_LUNS` on the existing session.

`rescan_fc_hosts()` issued one unconditionally, and it is called from `path()`'s retry loop (every 2s), `alloc_image()`'s wait loop (every 3s), `wait_for_multipath_device()`'s FC callback (every round) and — before v1.1.22 — `activate_storage()` on every pvestatd poll. LIP is now opt-in and unused by default. `FC.pm` also reads sysfs with a bounded timeout instead of a bare `open()`.

## HIGH — The temp-clone reaper respects ownership

A temp clone is connected only to the node that created it, but **every** node runs the reaper. Node A's own reaper is stopped by `is_device_in_use()`; node B has no local device, sails past that check, disconnects the clone from all hosts and destroys it. A snapshot-source operation running longer than an hour on node A — a `qemu-img convert` of a large disk routinely is — had its device pulled out from under it. The reaper now skips any temp clone still connected to another node.

## HIGH — `alloc_image()` checks before replacing a state/cloudinit volume

This was the only destructive path in the plugin with no in-use check at all: on finding an existing `vm-<id>-state-<snap>` or `vm-<id>-cloudinit` volume it disconnected and destroyed it, with a `warn()` as the only trace. A volume holding a live suspended guest's RAM image would be discarded.

## HIGH — Two mirrored `volume_list()` calls that cancelled each other out

`volume_list()` takes one positional argument, but two call sites passed named arguments, so the pattern bound to the literal string `"pattern"`. `_cleanup_vm_config_volumes()` therefore never deleted anything, and `free_image()`'s "is this the VM's last disk?" test was always true. Together they presented merely as "config backup volumes leak". **Fixing either side alone would have started destroying config backups on the first disk deletion of a multi-disk VM**, while snapshots of the remaining disks still referenced them — so both are fixed together.

## HIGH — `pve-pure-config-get` cannot hang any more

The disaster-recovery tool used bare `system('mount', ...)` / `system('umount', ...)` with no timeout. A mount against a multipath device whose paths are gone enters uninterruptible sleep and never returns — and this tool only ever runs when storage is already in trouble, so that is the expected state, not an edge case. Ctrl-C does not help.

It also now picks the **newest** destroyed generation when a disk has been deleted and recreated several times (lexical sort picked the oldest, and the newer generations then aborted the restore on a name conflict), uses `PVE::INotify::nodename()` so it connects to the host object the plugin actually registered, and cannot abort a restore whose config has already been written.

## MEDIUM — Other hardening

- `remove_scsi_device()` verifies the device still carries the expected WWID before deleting it. The kernel reuses `/dev/sdX` names, so a concurrent rescan could hand the same name to an unrelated LUN whose path would then be removed.
- `volume_get_connections()` distinguishes "no connections" from "the query failed". Returning an empty list for both made `free_image()` skip the disconnect and destroy anyway, leaving orphaned host connections — the ghost LUNs behind the v1.1.3/v1.1.4 incident. `free_image()` now refuses to delete when connections cannot be listed.
- The last unbounded waits are gone; `_run_cmd()` and `sysfs_read_with_timeout()` preserve any alarm the caller had armed instead of clearing it with a bare `alarm(0)`.
- `postinst` adds `fuser` to its required-binary check.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.23-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node. The package uses `systemctl reload` to avoid the stop-phase hang on D-state children, but reload does not reload Perl modules on many Proxmox VE versions, so pvestatd would keep running the old plugin code from memory:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

## Behaviour change to be aware of

Destructive operations now **refuse** rather than proceed when the plugin cannot establish that a device is idle. On a node with a wedged device or an unreachable array you may see a disk deletion, snapshot rollback or template conversion fail with a message explaining exactly what could not be determined. That is intentional: retry once the underlying condition is resolved. Normal operation on a healthy node is unchanged.

---

## Compatibility

Verified against Proxmox VE 9.0 / 9.1 / 9.2. Note that `APIVER` / `APIAGE` live in `libpve-storage-perl`, which versions independently of `pve-manager`: 9.1.2 reports 13/4 and 9.1.6 reports 15/6. The plugin continues to declare `APIVERSION 13` deliberately — it is the only value loadable on both, since a node whose `APIVER` is 13 **refuses** any plugin claiming a higher number.

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)

Reported by @pulipulichen (#13, #10)
