Consistency release for LXC containers. QEMU guests are not affected.

---

## HIGH — A running container's snapshot was quiesced by nothing at all

Proxmox VE takes a guest snapshot as freeze → snapshot → thaw. For LXC the freeze has two layers, and only one of them ran:

| Layer | Who decides | What we got |
|---|---|---|
| Processes (cgroup freeze) | Proxmox VE, unconditional | ran |
| **Filesystem (`FIFREEZE`)** | **the storage, via `volume_snapshot_needs_fsfreeze()`** | **did not run** |

This plugin did not implement `volume_snapshot_needs_fsfreeze()`, so it inherited the base `0`. Freezing the container's processes stops new writes, but it does not push out the dirty pages the host kernel is already holding — and a container's filesystem is mounted by the **host** kernel, so those pages are real. Our snapshot is then taken by the array over REST, entirely out of band from this host's block layer, and copies only what the array has actually received.

The plugin's own second line of defence did not run either. `volume_snapshot()` does a `sync` and a `blockdev --flushbufs`, but they were guarded by:

```perl
if ($device && -b $device && !is_device_in_use($device)) {   # before
```

so they were skipped **precisely when a container was running on the device** — the one case with dirty pages to flush.

Both mechanisms therefore failed in the same scenario. Running container snapshots — **including vzdump backups in snapshot mode**, which go through the same path — were crash-consistent rather than filesystem-consistent. On restore, the filesystem needs journal recovery and recently written application data can be missing.

`PVE::Storage::RBDPlugin` returns 1 from the same method for the same reason: a snapshot taken by a remote system cannot see this host's cache. Local-snapshot storages such as LVM-thin and ZFS correctly inherit 0, because there the same kernel owns both the filesystem and the snapshot.

**QEMU guests were never affected.** Their filesystem quiescing is done by the guest agent from `PVE::QemuConfig`, which never consults this method.

> **Existing snapshots and backups are not retroactively fixed.** Container snapshots taken before this release remain crash-consistent. They are still usable — a journalling filesystem recovers on mount — but if you have a container running a database and you keep long-lived snapshots as a recovery point, consider taking a fresh one after upgrading.

---

## Also

- `rename_snapshot()` and `volume_snapshot_info()` are now refused explicitly. The inherited implementations route through `filesystem_path()`, which this plugin cannot implement (Pure volume names are derived from the storage id, which Proxmox VE does not pass to that method), and the base `rename_snapshot()` would additionally have attempted a filesystem `rename()`. Neither is reachable today — every base call site is gated on `snapshot-as-volume-chain`, which this plugin does not offer, and the `QemuServer` sites need `do_snapshots_type()` to return `external`, which raw volumes never produce. The explicit refusal means a future caller gets a straight answer instead of an error naming a method it never called.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.30-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
