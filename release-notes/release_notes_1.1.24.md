Correctness release. Three of these are silent: the plugin and Proxmox VE disagreed about something, and nothing in either reported an error.

---

## CRITICAL — Linked clones could gain a phantom "unused" disk pointing at the live volume

`clone_image()` returns `base-102-disk-0/vm-104-disk-0` for a linked clone, and that is what the guest config stores. `list_images()` reported the bare `vm-104-disk-0`.

`PVE::QemuServer::update_disk_config` — the code `qm rescan` drives — marks a volume referenced using the volid from the config, then checks that set against the volids the plugin reports. With the two forms disagreeing, the volume looked unreferenced and Proxmox VE called `add_unused_volume()`. The guest ended up with an `unusedN` entry pointing at **the same Pure volume its `scsi0` was running on**, and removing that "unused disk" in the GUI destroys the live disk.

`list_images()` now derives the base from Pure's `source` field and emits the `base/clone` form. Only a `.pve-base` snapshot source is accepted, so full clones and clones taken from user snapshots keep their bare name — matching on anything else would invent a dependency that does not exist and produce the mirror image of this bug. When the array does not report `source` the behaviour is unchanged. `RBDPlugin::list_images` does the equivalent from the rbd parent snapshot.

> **If you have linked clones**, run `qm rescan --vmid <id> --dryrun` after upgrading and confirm it no longer proposes an `unusedN` entry. If a phantom entry was already added by an earlier `qm rescan`, remove it from the guest config with `qm set <id> --delete unusedN` — do **not** use the GUI's "Remove" button on it, which would destroy the volume.

---

## HIGH — Container backups leaked a Pure volume per mountpoint, indefinitely

`PVE::VZDump::LXC` calls `activate_volumes($cfg, $volids, 'vzdump')`, which lands in our `path()` and creates a snapshot-access clone on the array, connects it to the host and waits for its multipath device. It then mounts, rsyncs, umounts and deletes the `vzdump` snapshot — and never calls `deactivate_volume` at all (`grep -c deactivate_volume VZDump/LXC.pm` returns zero), so the plugin's own cleanup was never invoked.

That is one leaked Pure volume, one host connection and one local multipath device per container mountpoint per backup run. The one-hour orphan reaper was the only backstop, and per the millisecond-timestamp bug fixed in v1.1.22 it never ran at all on an API 2.x array — so sites with scheduled container backups have been accumulating these since the plugin was installed.

Cleanup is now triggered from `volume_snapshot_delete()`, which Proxmox VE does reliably call, with the same ownership, age and in-use gates as the background reaper.

**Check for a backlog after upgrading:**

```bash
journalctl -t pvestatd | grep temp-clone
```

or look for volumes matching `pve-<storage>-*-temp-snap-access-*` in the Pure UI. The reaper releases them (soft-destroy, recoverable within the array's eradication delay) on its own schedule.

---

## HIGH — Resizing a disk did not reach the local device

The local refresh in `volume_resize()` was gated on `$running`. Resize a stopped VM's disk and the local multipath map keeps the old size; start the guest and qemu presents the old capacity to it, with no error anywhere. The same applied to resizing on one node and starting the guest on another, which no amount of gating could have covered.

**This also fixes container resize, which had never worked on this plugin.** `PVE::API2::LXC` always calls `volume_resize(..., $running = 0)` — its own comment says the parameter only makes sense for QEMU — so the gated refresh never ran for a container at all. Proxmox VE then maps the volume and runs `resize2fs` against a device still reporting the old capacity, and the failure surfaces only as a `warn`. The array volume grew, the CT config recorded the new size, and the filesystem did not change.

The refresh now runs unconditionally — it is a no-op when this node has no local device for the volume — and `activate_volume()` reconciles the array size it has already fetched against `blockdev --getsize64`, rescanning only when they disagree. The whole refresh is best-effort: the array-side resize has already succeeded by then, so a local failure must not be reported as a failed resize.

> **If you previously resized a container** and it did not gain space, re-running `pct resize <id> rootfs +0G` will not help (Proxmox VE rejects a zero/shrinking change). Resize it again by any positive amount after upgrading, or run `resize2fs` manually against the mapped device.

---

## MEDIUM — `$vollist` was matched by prefix

`$vollist` holds complete volids and the base plugin compares them exactly. A prefix match returned `vm-10-disk-10` and `vm-10-disk-11` when asked for `vm-10-disk-1`. No current Proxmox VE caller passes a vollist, but returning volumes the caller did not ask for is how "the migration moved a disk I did not select" happens.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.24-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
