Host-side stability release. Removes a standing SAN-rescan load that Proxmox VE triggered on every status poll, fixes a hang inside the command timeout handler, reworks device discovery, and corrects Pure REST 2.x timestamp handling.

---

## Highlights

### 1. No more full SAN rescan on every pvestatd poll (CRITICAL)

Proxmox VE calls `activate_storage()` from `PVE::Storage::storage_info()` on every pvestatd poll (~10s), sequentially for every configured storage. `activate_storage()` unconditionally performed an iSCSI session rescan, a SCSI host scan, a host-wide `multipathd reconfigure`, and `udevadm trigger --subsystem-match=block` + `udevadm settle` on each of those calls — a full multipath rebuild and a re-trigger of every block device on the node, six times a minute, on every node.

Beyond the standing cost, it competed directly with device discovery: a VM start or backup waiting for a newly mapped LUN was racing a reconfigure that repeatedly tore the map table down and rebuilt it.

Rescans now run immediately when the node logs in to a new iSCSI portal, and otherwise at most once per `pure-rescan-interval` (default 300s). `multipathd reconfigure` is throttled process-wide to once per 30s on all discovery paths. Discovery of new LUNs is unaffected — `activate_volume()`, `path()` and `alloc_image()` each run their own targeted rescan and wait.

### 2. Hang inside the command timeout handler (HIGH)

The `_run_cmd` timeout handler in `Multipath.pm` and `ISCSI.pm` ran `kill('TERM', $pid)` followed by a **blocking** `waitpid($pid, 0)`. A child in uninterruptible sleep — precisely the case these timeouts exist to survive — cannot be killed by `TERM` or `KILL`, so the blocking `waitpid` never returned, and the alarm that would have broken us out had already fired and been cleared. The timeout handler itself became the hang.

It now escalates `TERM` to `KILL` and reaps only with `WNOHANG` on a bounded poll, leaving an unreapable child to init rather than joining it in D state.

### 3. Device discovery wait loop reworked (HIGH, #13)

`wait_for_multipath_device()` probed for the device only at the **end** of a loop body that could consume the entire timeout budget on a degraded fabric. With a 60s budget and a 45s pass, the caller got a single look at the device — taken at the worst possible moment, immediately after a host-wide reconfigure churned the map table. A LUN that surfaced two seconds later was reported missing. It also never probed *before* rescanning, so the common case (the device is already present) paid the full cost anyway.

The loop is now an escalation ladder: probe first, then transport rescan, then SCSI host scan, then udev, and only from the second round a throttled reconfigure — with a cheap probe after every step and a ~1s poll between steps, deadline-aware at every stage.

The failure message now reports the host state **captured at failure time**: what `multipathd` currently sees (map count, Pure map count, whether a map exists for the WWID, whether its `/dev/mapper` node was created), other Pure WWIDs multipathd does see when ours is absent, matching `/dev/disk/by-id` links, and per-session iSCSI state read from sysfs — with an explicit note when sessions are not `LOGGED_IN`, since LUN rescan is only issued on `LOGGED_IN` sessions.

### 4. Pod capacity reporting (MEDIUM, #10)

Pure volumes are thin, so a pod holding one 32 GiB volume reports 32 GiB provisioned with almost nothing written. A 3 GiB quota set afterwards therefore reads as 100% full immediately — while writing into the existing volume keeps working. Both halves are correct: the array **will** refuse the next volume create or grow in the pod, and it will **not** refuse writes to volumes that already exist. Nothing in the numbers said so.

`used` is now clamped to the quota so Proxmox VE is never handed `used > total`, and a pod at or over its quota logs an explanation once per hour including the raw `space` figures the array returned. New option `pure-pod-usage-metric` selects `provisioned` (default) / `virtual` / `physical`.

---

## Also fixed

- **Pure REST 2.x timestamps are milliseconds** (1.x is ISO 8601, and the code assumed the opposite). Snapshot dates rendered ~53000 years out in the Web UI, and the orphaned temp-clone reaper's "older than one hour" test could never be true on a 2.x array, so orphaned temporary snapshot clones were never cleaned up — each holding a volume slot, a host connection on every node, and a stale multipath device.
- **Orphaned temp-clone cleanup removed from `activate_storage`.** It disconnects and destroys volumes on the array; that belongs in the background reaper `status()` already forks, not on a path polled every ~10s with the short-timeout health client.
- **API 2.x host lookup.** `names` does not accept wildcards, so `host_list("pve-<cluster>-*")` always returned empty and new volumes were pre-connected to the local node only. Wildcards now use the `filter` parameter.
- **N+1 REST lookup removed from `deactivate_storage`** — the WWID is derived from the serial the volume list already returned.
- **API client cache key** no longer collapses to the portal address, which made two storages on one array share a single client.
- **`filesystem_path()`** fails with an actionable message instead of a bare "storage is required"; it passed `$scfg->{storage}`, which Proxmox VE never sets.
- **`activate_volume()` tracks the volume WWID**, closing a gap where a volume activated without `path()` was invisible to cluster residual-device cleanup.
- **postinst** no longer reports another vendor's `device`-scoped multipath settings as a Pure hazard; the check is now scope-aware.

---

## New storage options

| Option | Default | Purpose |
|---|---|---|
| `pure-rescan-interval` | `300` | Minimum seconds between the periodic SAN rescans in `activate_storage`. Set to `0` for pre-1.1.22 behaviour. |
| `pure-pod-usage-metric` | `provisioned` | Which pod space figure is reported as `used`: `provisioned` / `virtual` / `physical`. |

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.22-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node — the package uses `systemctl reload` to avoid the stop-phase hang on D-state children, but reload does not reload Perl modules on many Proxmox VE versions, so pvestatd would keep running the old plugin code from memory:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

## Compatibility

Verified against Proxmox VE 9.0 / 9.1 / 9.2 (`pve-manager 9.2.5`, `libpve-storage-perl 9.1.2`, kernel 7.0). Plugin `APIVERSION` 13 matches the storage `APIVER` exactly; no bump required.

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)

Reported by @pulipulichen (#13, #10)
