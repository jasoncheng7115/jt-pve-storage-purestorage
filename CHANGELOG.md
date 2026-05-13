# Changelog

All notable changes to **jt-pve-storage-purestorage** are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to a `MAJOR.MINOR.PATCH-DEBIAN` versioning scheme.

語言 / Language: [English](CHANGELOG.md) | [繁體中文](CHANGELOG_zh-TW.md)

---

## [1.1.17] - 2026-05-13

### MEDIUM — Pod capacity `used` now reflects provisioned capacity (matches Pure quota enforcement)

`get_managed_capacity()` for pod-backed storage now reports `used`
based on `space.total_provisioned` (sum of all volume sizes within
the pod) instead of `space.virtual` (host-written bytes).

#### Why this metric
Pure pod quota is enforced against `total_provisioned` at allocation
time — it is the metric that matches what the array will actually
refuse. The headline "Size" indicator on the Pure UI pod detail
page is also driven by this figure, so the reported value lines up
with what operators see on the array side.

The `virtual` metric (host-written bytes) reflects what the guest
has actually written to disk, which is a useful number but does not
indicate the remaining allocation room. A pod with a 2 TB quota and
a 2 TB thin volume that has had no writes will still refuse a new
allocation; `used = total_provisioned` is the reading that surfaces
this truth.

#### Fallback chain (unchanged in shape)
`total_provisioned` → `virtual` → `total_physical` → `total_used`.
Order changed so total_provisioned wins; older Purity that may omit
total_provisioned still falls through to the same secondary
indicators as before.

#### Operator-visible difference on upgrade
Pod storage's `used` reading may jump up to reflect provisioned
capacity rather than written capacity. PVE's capacity bar will now
match what the Pure UI displays as the pod's "Size" usage, and what
the array will allow at the next allocate.

Per-volume size reporting in `list_images` / `volume_size_info` is
unchanged — it has always used the volume's own `provisioned`
field (Pure-side volume size), which is correct for per-disk
display in the PVE GUI.

[#7]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/7

---

## [1.1.16] - 2026-05-13

### HIGH — `pve-pure-config-get` restore mode wasn't tombstone-aware after v1.1.15

Discovered in code review immediately after v1.1.15 shipped.
Plugin v1.1.15 changed `volume_delete` to pre-rename volumes to
`<orig>-pve-tomb-<unix-ts>-<pid>` before destroy. The disaster-
recovery tool `pve-pure-config-get` queries Pure's destroyed-volumes
list in restore mode to recover both config-backup volumes and the
VM's disk volumes. After v1.1.15, the destroyed volumes the tool
finds all carry the tombstone suffix, which broke two things:

#### What broke
1. **Display (cosmetic but confusing).** `decode_config_volume_name`'s
   greedy `(.+)$` snapname capture pulled the
   `-pve-tomb-<ts>-<pid>` trailer into the displayed snapname.
   The restore picker showed `snap1-pve-tomb-1747000000-12345`
   instead of just `snap1`, making it hard to identify which
   snapshot was which.

2. **Functional (serious).** Recovered disk volumes lived on Pure
   under their tombstone names (e.g.,
   `pve-pure1-100-disk0-pve-tomb-1747000000-12345`), but the VM
   config the tool wrote to `/etc/pve/qemu-server/<vmid>.conf`
   referenced disks under their PVE volid (`vm-100-disk-0`), which
   the plugin's `pve_volname_to_pure` maps to the original
   non-tombstone name (`pve-pure1-100-disk0`). On VM start, PVE
   looked up the disk by its expected name, didn't find it (it
   sat under the tombstone name), and the restored VM failed to
   start with "volume does not exist."

#### Fixed
- **`pve-pure-config-get` strips the `-pve-tomb-<ts>-<pid>` suffix
  from volume names before passing them to
  `decode_config_volume_name`** for display. Snapname listing
  is clean again.
- **After `volume_recover`, each tombstoned volume is renamed back
  to its original name** so it lives on Pure under the name the
  restored VM config expects. Applied to both the config-backup
  volume and every recovered disk volume.
- **Rename-back conflict handling.** If the original name is
  already taken by another live volume (rare — happens only when
  the operator already recreated the VM in question and is now
  trying to recover the older deleted instance), the tool aborts
  the restore with a clear error listing the conflicting tombstone
  names and offering two recovery paths (manual rename + clean up
  the conflicting volume, OR restore to a different VMID).
- **Tool now also uses the v1.1.14 `storeid_to_pure_prefix` helper**
  instead of duplicating the sanitize+underscore inline. Catches
  the dotted-storage-ID issue (#6) end-to-end through the restore
  workflow.

#### Build/CI

- **`make test` now syntax-checks `bin/pve-pure-config-get`** as
  well as the library modules. A Perl typo in the tool now fails
  the build (and the new
  [GitHub Actions deb-build workflow](.github/workflows/build-deb.yml)
  from v1.1.13) instead of being discovered only when an operator
  runs the tool during a real disaster.

#### Operator-visible difference
Pre-1.1.16 disaster recovery from a v1.1.15-or-later destroy would
silently leave the VM unbootable until manually fixed on Pure side.
Post-1.1.16 it just works the same as recovering pre-1.1.15 disks.

---

## [1.1.15] - 2026-05-13

### MEDIUM — Pure-side name reservation on destroy blocks same-name recreation for 24h; fix by pre-rename tombstone

Reported by **@pulipulichen** ([#8]).

When a PVE VM disk was deleted, the underlying Pure volume went into
Pure's standard "destroyed-pending" state, which **reserves the
volume's name for the array's eradication delay (default 24h)**.
During that window, creating a new volume with the same name fails.
For PVE workflows that delete-and-recreate the same disk (e.g.,
rebuilding a VM with the same id, snapshot/restore loops), this
manifested as "cannot create" errors that could only be resolved by
waiting 24h or manually eradicating from Pure UI.

**Note**: this is by-design Pure behaviour — the destroyed-pending
window exists so admins can `purevol recover` from an accidental
delete. It is not a Pure bug. The plugin's responsibility is to use
the array's API in a way that avoids holding the name longer than
needed.

#### Fixed
- **[MEDIUM] `volume_delete()` now pre-renames the volume to
  `<orig-name>-pve-tomb-<unix-ts>-<pid>` before issuing the
  destroy.** The original name is freed as soon as the rename
  succeeds; the tombstoned volume still goes into destroyed-pending
  under the suffixed name and eradicates per the array's normal
  schedule. Operators can identify these in Pure's Destroyed Volumes
  list by the `-pve-tomb-` marker.

#### Edge cases handled in the tombstone path
- **Pod-prefixed volumes** (`pod::vol`) keep the `pod::` prefix on
  rename — Pure does not allow cross-pod renames. The 63-char limit
  is checked against the post-`::` portion only.
- **Name too long**: if the suffix would push the volume name past
  Pure's 63-char limit, we skip the rename and destroy under the
  original name (accept the 24h reservation rather than risk a
  truncated-name collision). A warning is logged so the operator
  can see why this one volume's name is held.
- **Already tombstoned**: if a volume's name already carries the
  `-pve-tomb-<digits>` marker (e.g., re-destroying a tombstone left
  alive by a previous failed destroy), we skip the rename to avoid
  recursive double-tombstoning like `-pve-tomb-X-pve-tomb-Y`.
- **Concurrent destroys from multiple PVE nodes**: the PID suffix
  guarantees different processes produce different tombstone names
  in the same wall-clock second, even if both nodes' wall clocks
  agree to the second.
- **WWID preservation**: Pure preserves a volume's WWID across
  rename, and the plugin's WWID tracking JSON keys on WWID rather
  than name, so no tracking update is required.
- **Caller opt-out**: `volume_delete($name, tombstone => 0)`
  bypasses the rename entirely. (Most callers should not need this;
  the regex check above already prevents accidental double-
  tombstoning.)

#### Rollback on destroy failure
If the rename succeeds but the subsequent destroy fails (e.g.,
volume has unexpected protection group attachment, pod in degraded
state, transient API error), `volume_delete()` now tries to rename
the volume **back** to its original name before propagating the
destroy error. This restores pre-call state so the operator's PVE
retry runs naturally.

Without the rollback, a destroy failure after a successful rename
would leave the volume tombstoned-but-alive, the next PVE
`free_image` attempt would look up the original name, fail with
"not found" (volume now lives under the tombstone name), and
require manual array-side cleanup.

Rollback is **best-effort**: if it also fails (rare — implies
array-wide issue), we log the tombstone name so the operator can
clean up manually from Pure UI.

#### Not affected by this change
**PVE snapshot rollback** (revert to snapshot) uses
`volume_overwrite()` which mutates an existing volume's contents
in-place via `POST /volumes?names=X&overwrite=true` — no volume is
destroyed, so the tombstone path is not entered.

[#8]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/8

---

## [1.1.14] - 2026-05-13

### HIGH — VM snapshot WITH memory could wedge the entire PVE management plane on a degraded-multipath host

Reported by **@pulipulichen** ([#5]) with a critical diagnostic
observation: CT snapshot and VM snapshot WITHOUT memory worked fine on
the same node; only VM snapshot **WITH memory** triggered the wedge,
and only when multipath was already degraded (4 portals, 2 paths
broken). After one snapshot, pvedaemon / pvestatd progressively
became unresponsive and the entire web UI eventually showed `?` for
every storage; recovery required a forced reboot.

**Root cause:** VM-with-memory snapshot creates a VMSTATE volume on
the array, which then has to be host-side activated (iSCSI rescan +
multipath wait for the new device). `rescan_sessions()` called
`iscsiadm -m session --rescan`, which **rescans every active session
in a single iscsiadm invocation**, including the dead ones. The dead
sessions queue SCSI commands waiting for kernel-level timeouts
(typically 30 s+ per dead path); the iscsiadm parent process gets
killed at our 60 s wrapper timeout, leaving **D-state children
behind** (immortal — see CLAUDE.md lesson #3). Every subsequent
`pvestatd` poll (10 s) re-fired the same rescan and stacked more
D-state children until the management plane died.

CT snapshot and VM-without-memory snapshot do not reproduce because
they don't create a new volume that needs host-side activation —
they're pure storage-side operations.

#### Fixed
- **[HIGH] `rescan_sessions()` rewritten** to:
  1. Enumerate sessions via `/sys/class/iscsi_session/`
     (kernel-maintained sysfs, immune to iscsiadm hangs), with a
     bounded readdir.
  2. Read each session's `state` attribute via a bounded sysfs
     read; skip sessions whose state is not `LOGGED_IN`
     (FREE, REOPEN, FAILED, etc.).
  3. Issue per-session rescan
     (`iscsiadm -m session -r <sid> --rescan`) only on `LOGGED_IN`
     sessions, each bounded by a 10 s timeout (vs. the previous
     monolithic 60 s for all sessions in one shot).
- Worst-case orphan child count drops from "one per dead session
  per poll forever" to "one per stuck-LOGGED_IN session per call,
  bounded by per-session timeout."
- Warning is emitted when non-LOGGED_IN sessions are skipped, with
  state labels (e.g. `session1=FREE, session2=REOPEN`) so the
  operator can see the underlying iSCSI fabric problem instead of
  just observing a wedge symptom.

#### Field expected behaviour on the same reproducer post-fix
4-LIF Pure, 2 paths broken, VM snapshot with memory:
- rescan_sessions only rescans the 2 LOGGED_IN sessions, each
  finishing in <1 s
- VMSTATE volume appears on the 2 healthy paths, multipath sees it,
  snapshot completes
- pvestatd polls don't accumulate D-state children
- web UI stays responsive

---

### MEDIUM — PVE Web UI disk list silently empty when storage ID contains `.`

Reported by **@pulipulichen** ([#6]).

Adding a storage with ID `pure-plugin-5.111-pvepod2` produced an empty
disk list in the PVE web UI even though VMs on the storage were
running and Pure-side volumes existed. Renaming the storage to
`pure-plugin-5-pvepod2` (dot removed) resolved it.

**Root cause:** asymmetric sanitisation.

- `encode_volume_name()` (the write path) called
  `sanitize_for_pure($storage)` which strips `.` (and other
  non-`[a-zA-Z0-9_-]` chars), then `s/-/_/g`. So storage ID
  `pure-plugin-5.111-pvepod2` became volume prefix
  `pure_plugin_5111_pvepod2` (dot removed), and the volume on the
  array is `pve-pure_plugin_5111_pvepod2-<vmid>-disk<N>`.
- `list_images()` (the read path) and **six sibling pattern-building
  sites** in `PureStoragePlugin.pm` did only
  `$san_storage = $storeid; $san_storage =~ s/-/_/g;` — leaving the
  dot in. The filter pattern became
  `pve-pure_plugin_5.111_pvepod2-*`, which never matched the
  actually-stored volume names. `list_images` returned empty.

#### Fixed
- **[MEDIUM] New helper `Naming::storeid_to_pure_prefix($storeid)`**
  that performs the full transform (sanitize_for_pure + `s/-/_/g`)
  used by `encode_volume_name`. Exported from `Naming.pm` so all
  pattern-building callers share a single canonical implementation.
- All 7 inline duplications in `PureStoragePlugin.pm` replaced with
  calls to the new helper.
- The 3 remaining inline duplications inside `Naming.pm` itself
  (encode_config_volume_name, pve_volname_to_pure cloudinit branch,
  pve_volname_to_pure state branch) also collapsed onto the helper
  to keep the transform single-source — if storage-name encoding
  rules ever change again, only one site needs editing.

[#5]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/5
[#6]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/6

---

## [1.1.13] - 2026-05-11

### HIGH — Snapshot rollback silently no-op'd on REST API 2.x

Reported independently by **@tgdfama1** ([#1]) and **@pulipulichen**
([#2]). After taking a snapshot, modifying the volume, and rolling
back from the PVE UI, the rollback task appeared to complete but the
volume contents were not restored — post-snapshot data was still
visible to the guest.

**Root cause:** `volume_overwrite()` used `PATCH /api/2.x/volumes`
with a `source` body field. Per the FA 2.x OpenAPI spec, `PATCH
/volumes` is the **rename / destroy / modify** endpoint and does
**not** accept `source` in its body — Pure responded with
`No attribute specified.` while still returning HTTP 200 with an
empty body, so the PVE task layer reported success even though the
volume was never copied over.

#### Fixed
- **[HIGH] `volume_overwrite()` switched from `PATCH` to
  `POST /volumes?names=<target>&overwrite=true`** with `source` in
  the body — the same POST endpoint `volume_clone()` already uses,
  with the spec-defined `overwrite=true` query parameter for the
  "object copy" case. `add_to_protection_group_names` and
  `with_default_protection` are deliberately omitted on this path
  because the spec forbids them when `overwrite=true`.

#### Reproducer
1. Create a VM disk on a Pure-backed storage.
2. Take a snapshot of the VM in PVE.
3. Boot the VM, write a file, shut down.
4. Right-click → Revert / Rollback the snapshot in PVE UI.
5. **Before this fix:** the task says "OK", but booting the VM
   shows the post-snapshot file still present.
6. **After this fix:** the post-snapshot file is gone, the volume
   correctly reflects the snapshot's state.

---

### MEDIUM — Pod storage reported 100% used immediately after thin volume create

Reported by **@pulipulichen** ([#3]).

After v1.1.12 fixed pod quota reporting to read `Pod.quota_limit`,
the next surface was wrong: a thin volume of the quota's size (e.g.
2 TB volume in a 2 TB pod) made PVE report the storage as 100% used
the moment the volume was created, even with zero host writes. The
Pure GUI on the same pod correctly showed it as nearly empty.

**Root cause:** `get_managed_capacity()` preferred
`space.total_provisioned` (sum of all volume sizes) over
`space.virtual` (host-visible logical writes) in the `//` fallback
chain. The original reasoning was that pod quotas enforce against
provisioned capacity, so reporting provisioned-as-used would
correctly stop PVE from over-allocating. The enforcement theory is
correct but the operator-visible mismatch against Pure's own UI was
worse than the imagined over-allocation risk — if the array genuinely
runs into the quota at allocate time it returns a clear quota error
that `translate_pure_error()` already surfaces. `status()` does not
need to pre-pessimise the cap.

#### Fixed
- **[MEDIUM] `get_managed_capacity()` fallback chain reordered** to
  prefer `virtual` (matching Pure UI's pod usage display), with
  fallbacks through `total_physical` → `total_used` →
  `total_provisioned`. PVE's used-bar now tracks the Pure GUI's
  view of the pod.

---

### CI: manual `.deb` build workflow

Contributed by **@pulipulichen** ([#4]).

- **New file: `.github/workflows/build-deb.yml`** — runs `make test`
  + `dpkg-buildpackage -us -uc -b` on an `ubuntu-24.04` runner and
  uploads the resulting `.deb` as a 30-day GitHub Actions artifact.
- Triggered manually via `workflow_dispatch` only (no auto-push, no
  side effects on `releases/`).
- Useful for contributors who want to verify a build without
  setting up a Debian dev environment, and for release engineers
  who want a quick artifact off any branch.

[#1]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/1
[#2]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/2
[#3]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/3
[#4]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/4

---

## [1.1.12] - 2026-05-08

### MEDIUM — Stop reading file-services quota policies as if they were pod block quotas

Field follow-up to v1.1.10 / v1.1.11. The same field engagement
that surfaced the v1.1.10 pod-quota reporting bug also revealed
that **the entire `Storage > Policies` panel in the Pure GUI is
FlashArray Files / managed-directory only**, even when the GUI
lets you scope a quota policy to a Pod when creating it. Pure
recognises five policy types and ALL of them are file-services:
`autodir`, `nfs`, `smb`, `quota`, `snapshot`. Attaching any of
them to a Pod marks the Pod as "has file-services policies
attached," which makes Pure reject every subsequent block volume
create with the misleading error:

```
Pure Storage API: Pod contains file systems or policies. (context: <podname>)
```

#### Two consequences this release addresses

1. **v1.1.10's `pod_get_quota_limit` walked
   `/policies/quota` + `/policies/quota/rules` to surface that
   policy's `quota_limit` as if it were the Pod's block quota.**
   That value never enforced against block volumes — it only
   enforces against managed-directory file usage. PVE was being
   shown a cap that did not exist for the resource it cares about.
   v1.1.12 strips that walk: `pod_get_quota_limit` now reads ONLY
   `Pod.quota_limit`, which is the genuine block-level pod quota
   field.

2. **v1.1.11's `with_default_protection=false` on
   `volume_create`/`volume_clone` did NOT cure the field-reported
   "Pod contains file systems or policies." rejection.** The
   rejection sits at a higher layer than container-default-
   protection application; opting out of default protection
   does not change Pure's mind. The right fix is on the Pure side:
   destroy the file-services policy and set `Pod.quota_limit`
   instead. v1.1.11's parameter is kept (it is a correct defensive
   change — the plugin manages its own snapshot policy and never
   relied on Pure's default protection — and removing it would be
   gratuitous churn) but it is no longer claimed as the cure here.

#### Fixed
- **[MEDIUM] `pod_get_quota_limit()` now reads only
  `Pod.quota_limit`.** The 80+ lines of policies/quota walk added
  in v1.1.10 are gone. Simpler, faster (one fewer API call per
  poll, two fewer in the multi-policy case), and no longer
  reports misleading caps.
- **README + README_zh-TW Option A "Pod with quota" sections now
  spell out the three correct paths** for setting Pod block
  quota — CLI (`purepod --quota-limit`), REST API (`PATCH /pods`
  with `quota_limit` in body), GUI (6.6+ Edit Pod) — and warn
  explicitly that `Storage > Policies` must NOT be used for pod
  block quota. The exact "Pod contains file systems or policies."
  error string and the destroy + re-set recipe are included so
  operators can self-recover without contacting support.

#### Field-side recovery (no plugin change needed)
For any operator that previously created a quota policy via the
Pure GUI and now sees `Pod contains file systems or policies.` on
volume create:

```
# CLI on Pure
purepolicy quota destroy <policy-name>
purepod setattr <pod-name> --quota-limit 2T

# OR REST (PVE Web UI Shell, uses storage's stored API token)
DELETE /api/2.x/policies/quota?names=<policy-name>
PATCH  /api/2.x/pods?names=<pod-name>  body  {"quota_limit": <bytes>}
```

#### Files changed
- `lib/PVE/Storage/Custom/PureStorage/API.pm`:
  - `pod_get_quota_limit()` rewritten to read only Pod.quota_limit
- `README.md`, `README_zh-TW.md`:
  - "Option A — Pod with quota" updated with explicit warning and
    three correct setting paths

---

## [1.1.11] - 2026-05-08

### HIGH — Volume create/clone failed in a pod with any policy attached

Direct follow-up to v1.1.10 in the same pod-quota field engagement: as
soon as the operator added a quota policy to the pod (via Storage >
Policies in the GUI) so that v1.1.10 could read the cap, every VM disk
creation against that storage failed with:

```
Pure Storage API: Pod contains file systems or policies. (context: pvepod2)
```

at `PureStoragePlugin.pm:1660` inside `alloc_image`'s `volume_create`
call. The error is misleading — the pod did not contain file systems,
only the quota policy that the operator had just attached.

Root cause, traced against the FA 2.26 OpenAPI spec for
`POST /api/2.x/volumes`:

- The `with_default_protection` query parameter defaults to `true`.
- With the default, Pure applies the **container default protection**
  to the newly created volume. The container is the pod (or the array
  for non-pod volumes).
- When the pod has any policy attached, Pure rejects the "apply
  default protection" step on the new volume and surfaces the
  generic "Pod contains file systems or policies." error.

The plugin does not rely on Pure's default-protection mechanism — it
manages PVE snapshots through `volume_snapshot` /
`volume_overwrite` — so the right fix is to opt out:

#### Fixed
- **[HIGH] `volume_create` and `volume_clone` now pass
  `with_default_protection=false` when the target volume name carries
  a `pod::` prefix.** Implemented in
  `lib/PVE/Storage/Custom/PureStorage/API.pm`:
  - `volume_create()` — appends `&with_default_protection=false` to
    the `POST /volumes?names=…` query string when the name matches
    `/::/`
  - `volume_clone()` — same treatment for clones into a pod
- Non-pod volumes are deliberately left alone so that any
  user-configured array-level `default_protections` continues to apply.
- The `volume_overwrite` (rollback) and snapshot-create paths use
  different endpoints that do not accept `with_default_protection`,
  so no change is needed there.

#### Field reproducer
Purity//FA 6.5.9, pod `pvepod2` with a 2 TB quota policy
`pvepodquota2` attached. `qm create 107 ... -scsi0 pure-storage:32`
failed at the API layer; `dpkg -i 1.1.11-1` and re-running the same
command succeeds.

---

## [1.1.10] - 2026-05-08

### MEDIUM — Pod quota was ignored, full-array capacity reported instead

When a Pure storage was created with `--pure-pod <name>`, PVE's storage
status panel showed the **entire FlashArray capacity** rather than the
pod's quota. A 2 TB pod quota on a 50 TB array displayed 50 TB free,
hiding the real allocation ceiling and giving operators no warning
before the array rejected an over-quota volume create.

Pure FlashArray exposes pod quotas through TWO mechanisms in API 2.x,
and the old code missed both common variants:

- **(a)** The Pod object itself carries a `quota_limit` field, set
  via the `purepod create --quota-limit` /
  `purepod setattr --quota-limit` CLI path (Purity 6.4.4+). The old
  code read this correctly **but** the field stays at `0` when the
  cap is set by the policy mechanism (b) below — which is the path
  the GUI uses.
- **(b)** Newer Purity also lets the operator create a Policy of
  `policy_type='quota'` that references the pod via the policy's
  `pod` field, with one or more Rules in `/policies/quota/rules`
  carrying the actual `quota_limit`. The Storage > Policies UI
  builds quotas this way. **Crucially, the policy mechanism does
  NOT propagate the cap back into the Pod's own `quota_limit`
  field** — so reading the Pod object alone always saw `0`.

Old code therefore always saw `quota = 0`, fell through the
`if (quota > 0)` guard, and returned the array-wide capacity from
`array_space()`.

> ⚠ Earlier drafts of this fix attempted to use
> `/policies/quota/members` with a `member.resource_type='pods'`
> filter. That endpoint is **wrong for pods** — per the Pure API
> 2.26 spec, the members table binds quota policies to **managed
> directories** only. Pod-attached quota policies are discovered by
> reading the policy's own `pod` field instead.

Field reproducer: Purity//FA 6.5.9, pod `pvepod` with a single
quota policy `pvepodquota` (2 TB rule, enabled, enforced=false),
one 2 T volume already provisioned. PVE reported the full multi-TB
array capacity with 0% used.

#### Fixed
- **[MEDIUM] `get_managed_capacity()` now resolves pod quotas via
  both code paths.** New helper `API::pod_get_quota_limit($podname)`:
  1. Read `quota_limit` directly off the Pod object (path a)
  2. `GET /policies/quota?filter=pod.name='X'` — list quota policies
     whose `pod` field references this pod (path b)
  3. `GET /policies/quota/rules?policy_names=Y,Z` — gather rules for
     those policies (uses the dedicated `policy_names` array query
     parameter documented in the FA 2.26 spec, not an `or`-joined
     filter)
  4. Take the **smallest positive `quota_limit`** across (a) and all
     rules from (b) — most-restrictive cap matches what the array
     itself enforces on allocation
- Edge cases handled:
  - Multiple rules per policy / multiple policies per pod → take min
  - Policies with `enabled=false` or `destroyed=true` → ignored
  - Rules with `enforced=false` (soft / notification-only) → still
    counted, because the user explicitly created the quota and PVE
    allocation should respect that intent
  - Filter parameter unsupported on older Purity for these endpoints
    → fall back to no-filter list + Perl-side match
  - Endpoint 404 (missing on older Purity), 403 (permission-restricted
    token), 400 (filter-syntax mismatch) → warn + fall through to
    array capacity (status polling never croaks)
  - Pod name with `'` or `\` (would break the filter literal) →
    skipped with warning
  - API 1.x → skipped (pods quotas are an API 2.x feature)
- **Pod `used` capacity now derived from `total_provisioned`** (the
  metric Pure quotas actually count against, per the API 2.26 Pod
  space schema) instead of `total_used` (post-data-reduction physical
  bytes). Falls back to `virtual` / `total_used` / `total_physical`
  for older Purity that may omit `total_provisioned`. Without this
  change, a freshly-provisioned 2 T volume in a 2 T pod showed 0%
  used in PVE even though the pod was already 100% full from the
  array's perspective — the next allocate would have been rejected.

#### Files changed
- `lib/PVE/Storage/Custom/PureStorage/API.pm`:
  - `pod_get_quota_limit()` — new helper, reads pod's own
    `quota_limit` AND walks `policies/quota` + `policies/quota/rules`
    with eval-wrapped error handling at every API call and a
    no-filter fallback
  - `get_managed_capacity()` — call new helper; switch `used`
    source to `total_provisioned`

---

## [1.1.9] - 2026-05-05

### CRITICAL — unreachable iSCSI portals stalled activate_storage() and wedged the web UI

When a Pure FlashArray exposes more iSCSI LIFs than this PVE host can
reach (asymmetric cabling, controller ports on a different network
segment, partial fabric outage), `activate_storage()` enumerated every
LIF returned by `iscsi_get_ports()` and called `iscsiadm -m discovery`
+ login on each one. Each unreachable LIF stalled for the full
iscsiadm timeout — 30s for discovery, up to 60s for login — even
though the eval kept the loop alive. With four LIFs and two
unreachable, `pvesm add purestorage` blocked for 60s+ before
returning, and every subsequent `pvestatd` poll repeated the same
walk, leaving the web UI Status panel stuck on "Loading..." and
starving every other storage on the node.

Field reproducer: 4-LIF Pure (two LIFs per controller, two subnets)
plus a 2-node PVE where only one controller's subnet was cabled.
`pvesm add` returned with two `Failed to connect to portal ...:
Command timed out after 30s` errors at
`PureStoragePlugin.pm:1352 (discover_targets)`. Removing the storage
was the only way to recover.

#### Fixed
- **[HIGH] `activate_storage()` now TCP-probes every iSCSI portal
  before iscsiadm.** A new helper `ISCSI::probe_portal($ip, $port,
  timeout => $t)` does a bounded `IO::Socket::INET` connect; if it
  does not succeed within `pure-portal-probe-timeout` seconds the
  portal is skipped with a single warning instead of stalling
  iscsiadm. The same probe is applied to the secondary login site in
  `alloc_image()` that re-establishes sessions for state/cloudinit
  volumes.
- **`activate_storage()` fails fast when zero portals are reachable.**
  Instead of returning success and letting `status()` poll forever
  against a storage with no usable paths, it now `die`s with an
  actionable message pointing at network/zoning checks and the
  `--nodes` option for binding the storage only to nodes that can
  reach the array.

#### Added
- **New storage option `pure-portal-probe-timeout`** (integer, 0..30,
  default 2). Set to 0 to disable the pre-check and restore 1.1.8
  behaviour; raise on storage networks where TCP setup latency
  legitimately exceeds the default. Tunable per-storage via
  `pvesm set <storeid> --pure-portal-probe-timeout <n>`.

#### Architectural note
This is sibling-pattern audit territory: every other place in the
plugin that talks to a path that could hang under network failure
already has bounded protection (`_run_cmd` timeouts,
`sysfs_read_with_timeout`, the v1.1.8 alarm-wrapped glob). The portal
enumeration was the last unbounded path in `activate_storage()`; the
plugin had been assuming that "every LIF the array reports is
reachable from this host", which is true in lab and CI but not in
production cabling reality.

---

## [1.1.8] - 2026-04-26

### Sibling-pattern audit from author's related NetApp plugin v0.2.9

The author's sibling jt-pve-storage-netapp plugin shipped v0.2.9 fixes
for two issues that called for a sibling-pattern audit on this codebase. Two of those issues had real
counterparts here; three did not (Pure uses volume names directly as
identifiers so it is not exposed to the lookup-after-create eventual
consistency window; `alloc_image` was already a bounded retry loop;
`multipath -F` is already a forbidden pattern).

#### Fixed
- **[MEDIUM] `_cleanup_orphaned_devices()` now untracks WWIDs only after
  verifying the local multipath device is gone.** Previously, the function
  would `_untrack_wwid()` unconditionally after `cleanup_lun_devices()`,
  even if cleanup failed. With the volume already deleted from the array,
  Phase 1 cannot re-import the WWID on the next pass, so a single
  transient cleanup failure (kpartx holder, multipathd glitch, dmsetup
  busy) silently leaked a stale device that no future status() poll
  could find. The fix mirrors the conditional-untrack pattern already
  used in `free_image()` (1.1.x): if `get_multipath_device($wwid)` still
  returns a path after cleanup, keep the WWID tracked so the next pass
  retries; only untrack when verifiably gone.

- **[LOW] `glob("/dev/disk/by-id/...")` calls now wrapped in a 5-second
  alarm timeout in `Multipath::get_device_by_wwid()`,
  `ISCSI::wait_for_device()`, and `ISCSI::get_device_by_serial()`.** The
  `-b` stat that follows the glob in `get_device_by_wwid()` resolves the
  symlink to `/dev/sd*` or `/dev/dm-*`; on a multipath device with all
  paths down and `queue_if_no_path` still active, this stat hits the same
  kernel block-layer wait that blocks `vgs` and `lvs`. Pattern matches
  the existing `_run_cmd` and `sysfs_read_with_timeout` style.

---

## [1.1.7] - 2026-04-11

### CRITICAL — kpartx partition holders blocked ALL volume deletions

Every VM disk with an OS installed has a GPT/MBR partition table. The
Linux kernel automatically scans multipath LUNs and creates partition
dm devices via kpartx. These partition devices appear as "holders" in
`/sys/block/<dm-N>/holders/`. The `is_device_in_use()` fix from 1.1.2
treated ALL holders as "device in use" and blocked deletion -- correct
for LVM holders (data loss prevention) but wrong for bare kpartx
partitions (passive kernel artifacts with nothing using them). This
made it impossible to delete any VM disk on Pure storage when the host
kernel had auto-scanned the LUN content. **Not an edge case -- this is
the normal case for every production VM.**

#### Fixed
- **[CRITICAL] `is_device_in_use()` now distinguishes bare kpartx
  partitions from real holders.** For each holder:
  - Check if dm-name matches a known kpartx pattern (`*-part1`, `*p1`,
    `*1`, `sd*1`) or has the kernel `/sys/block/<h>/partition` flag
  - If it IS a partition: check for sub-holders (LVM/dm-crypt on top),
    check if mounted (`/proc/mounts`, both `/dev/dm-N` and
    `/dev/mapper/<name>` paths), check if swapped (`/proc/swaps`)
  - If ALL holders are bare partitions with no sub-holders and not
    mounted/swapped: safe to ignore, allow deletion
  - If ANY holder is not a partition, or any partition has
    sub-holders/mount/swap: block (data-loss protection preserved)
- **[HIGH] `cleanup_lun_devices()` now runs `kpartx -d <device>` before
  attempting to remove the multipath map.** Without this, partition
  holder devices prevent `multipathd remove map` and `multipath -f`
  from succeeding.
- **[MEDIUM] `get_device_usage_details()` no longer misparses kpartx
  partition dm-names as LVM VG names.** The dm-name
  `3624a9370...-part1` was being parsed as VG `3624a9370...` LV
  `part1`. Partition patterns are now checked first and excluded from
  VG name parsing.
- **[LOW] Orphan warning cooldown.** Phase 3 untracked-device warnings
  in `_cleanup_orphaned_devices` now use a per-WWID flag file in
  `/var/run/pve-storage-purestorage/` to limit warnings to once per
  hour per WWID. Previously, pvestatd's 10-second `status()` polling
  would fire the same warning every 10 seconds.

---

## [1.1.6] - 2026-04-10

### postinst must reload ALL PVE services + LVM global_filter detection

Two more issues from the related project jt-pve-storage-netapp's
Incident 9 (pvestatd not reloaded) and Incident 10 (host LVM
auto-activation on upgraded PVE nodes).

#### Fixed
- **[CRITICAL] postinst now reloads pvedaemon, pvestatd, AND pveproxy
  after installation.** Previous versions did not reload any PVE service,
  meaning old bug-containing code stayed in memory indefinitely. In
  particular, pvestatd polls `status()` every 10 seconds — if the old
  code triggers D-state children (e.g. the pre-1.1.5 SCSI host scan bug
  on HPE hardware), D-state processes accumulate without limit until the
  node's hardware watchdog or manual reboot intervenes.

  Changed from `systemctl restart` to `systemctl reload` (SIGHUP). If
  the old code already created D-state children, `restart`'s stop phase
  hangs waiting for unkillable processes. `reload` sends SIGHUP, which
  makes `PVE::Daemon` `re-exec()` itself with new code, bypassing the
  stop phase entirely.
- **[HIGH] postinst now checks `/etc/lvm/lvm.conf` for `global_filter`
  and warns if absent.** On PVE nodes upgraded from 7/8 to 9, the old
  `lvm.conf` lacks the filter that excludes device-mapper and multipath
  devices from LVM scanning. The host LVM auto-activates VGs found
  inside guest VM disks (which are raw LUNs visible as multipath
  devices), creating holder `dm` devices on top of the multipath device.
  These holders make `is_device_in_use()` correctly block
  `free_image()` from deleting the volume, but the old error message
  was not actionable.
- **[HIGH] `free_image()` now provides detailed usage information when
  `is_device_in_use()` blocks deletion.** New `get_device_usage_details()`
  helper in `Multipath.pm` enumerates holder device names, dm-names,
  detects LVM VG names from dm-name conventions, and explains the root
  cause (host LVM auto-activation on upgraded PVE nodes) with exact
  remediation: `vgchange -an <vg>` to deactivate immediately,
  `global_filter` setting in `lvm.conf` for long-term fix.

---

## [1.1.5] - 2026-04-10

### CRITICAL — `rescan_scsi_hosts()` could hang on HPE / Dell / Lenovo HBAs

A latent bug present since 1.0.0 that would have surfaced on the first
customer to deploy on HPE ProLiant, Dell PERC, Lenovo ThinkSystem, or
any server with a SAS HBA / hardware RAID controller alongside the
iSCSI cards. **All earlier versions are vulnerable. Strongly recommended
upgrade.**

#### Fixed
- **[CRITICAL] `rescan_scsi_hosts()` iterated every entry in
  `/sys/class/scsi_host/`, including non-iSCSI hosts.** Writing
  `"- - -"` to the scan file of an HPE Smart Array controller (smartpqi
  driver), Dell PERC (megaraid_sas), or LSI HBA (mpt3sas) triggers a
  driver-side full target rescan that enters D-state for **600+ seconds**
  inside the kernel. `sysfs_write_with_timeout()` protects the parent
  process from blocking, but **D-state children cannot be reaped by
  SIGKILL** and they hold kernel scan locks until the driver finishes,
  causing cascading config-lock timeouts on every subsequent VM
  operation, plus `pvedaemon` restart hangs requiring force-reboot.

  Fixed by sourcing the host list from `/sys/class/iscsi_host/` instead
  of `/sys/class/scsi_host/`. The `scsi_transport_iscsi` layer
  registers every iSCSI host there via `iscsi_host_alloc()`, regardless
  of underlying driver (`iscsi_tcp`, `iser`, `bnx2i`, `qla4xxx`, `qedi`,
  `be2iscsi`, `cxgb3i`, `cxgb4i`, ...). Non-iSCSI drivers categorically
  never register there, so iterating that class is both exhaustive and
  safe.

  Verified on a real host with mixed `scsi_host` (host0-3 non-iSCSI +
  host4-7 iSCSI): `strace` confirms writes only happen on host4-7 after
  the fix. Pre-fix the function would have written to every one of the
  8 hosts.

  **Lesson:** timeout protection covers the parent process, not the
  kernel. For sysfs writes that hold kernel locks, the correct fix is
  to NOT issue the operation in the first place, not to timeout it.
- **[HIGH] `FC.pm rescan_fc_hosts()` used bare `open()`** to write
  `/sys/class/fc_host/<host>/issue_lip` and
  `/sys/class/scsi_host/<host>/scan`. The SCSI scan loop already
  filtered to FC hosts only (via `get_fc_hosts()` — no Bug 1 risk
  there), but the bare `open()` means the parent worker stalls if the
  HBA is wedged. Fixed by routing both writes through
  `sysfs_write_with_timeout()`, matching the protection already in
  `Multipath.pm`.

#### Added
- **`translate_pure_error()` helper in `API.pm`** that converts Pure
  FlashArray's raw API errors into operator-friendly messages.
  Pre-1.1.5, an operator hitting the array's volume cap would see
  `Maximum number of volumes is reached` with no guidance. Post-1.1.5,
  they see a one-paragraph explanation: which limit was hit, why
  destroyed-but-not-eradicated volumes count against it, and how to
  recover. Pattern-matches Pure's known limit errors for: per-array
  volume count, per-volume snapshot count, host connection count,
  protection group count, capacity exhaustion, and API rate limit.
  Unknown errors pass through unchanged.

  Applied at the most user-visible die sites: `alloc_image()`,
  `clone_image()`, `volume_snapshot()`.

---

## [1.1.4] - 2026-04-09

### Six more bugs found by an internal deep audit after 1.1.3

Applied the "sibling pattern" audit rule (every bug fix triggers a
codebase-wide search for the same anti-pattern) to every cleanup path,
`/sys/block` access, and API version-divergence point in the codebase.
**Recommended over 1.1.3** — the API 1.x normalisation issue is HIGH
severity for any user on Pure REST API 1.x.

#### Fixed
- **[HIGH] `volume_get_connections()` did not normalise the API 1.x
  response shape.** Pure REST 1.x returns
  `[{ host => "h1", lun => 1, name => "myvol" }, ...]` where the
  `name` field is the **volume** name, not the host name. The 2.x
  branch was already normalised to `{ name => "<host>" }`. Every
  caller (`free_image`, `_disconnect_from_all_hosts`,
  `_backup_vm_config`, `_cleanup_orphaned_temp_clones`,
  `_cleanup_temp_snap_clone`, `alloc_image` orphan-cleanup) iterated
  `$conn->{name}`, which on 1.x returned the **volume** name. The
  subsequent `volume_disconnect_host($vol, $conn->{name})` therefore
  passed the volume name as the host argument, which silently fails
  inside an `eval`. **Result on API 1.x: every disconnect call was a
  no-op, leaving orphaned host connections forever, and every
  `volume_delete` cleanup hit the Bug E ghost-LUN failure mode.**
  Fixed by normalising the API 1.x branch in
  `volume_get_connections()` to the same `[{ name => "<host>" }]`
  shape, with fallback to `host_name` and `name` fields.
- **[HIGH] `path()` temp clone connect-failure had two bugs in one
  sequence**: (a) Bug E pattern — `volume_delete($temp)` called
  without disconnect first, (b) `$@` clobber — the inner cleanup
  `eval` reset `$@` so the subsequent `die "...$@"` showed the
  cleanup error instead of the original connect error. Fixed both:
  save `$connect_err = $@` first, then call
  `_disconnect_from_all_hosts` before `volume_delete`, then `die`
  with the saved error.
- **[HIGH] `_backup_vm_config()` connect-failure had the same Bug E
  pattern**: `volume_connect_host` fails → `volume_delete` without
  disconnect → orphaned host connection on the array. Fixed by
  calling `_disconnect_from_all_hosts` before `volume_delete` in
  both the connect-fail branch and the "Cannot get WWID" branch.
- **[MEDIUM] `clone_image()` was missing disk-id collision retry**
  — same TOCTOU window that `alloc_image` had before 1.1.0. Two
  concurrent `qm clone` invocations on the same source VM could
  both pick the same disk id from `_find_free_diskid` and one would
  fail with "already exists". Fixed with a 5-attempt retry loop
  around the `volume_clone` call.
- **[LOW] `rescan_scsi_device()` used `basename()` instead of
  `_resolve_block_device_name()`.** Current callers always pass
  `/dev/sdX` so the bug is latent, but as an exported helper a future
  caller passing `/dev/mapper/<wwid>` would silently fail. Fixed
  defensively for consistency with the rest of the Multipath module.
- **[LOW] `_backup_vm_config()` used bare `system()` for `mkfs.ext4`
  / `mount` / `umount`.** The 1MB volume is freshly allocated so the
  device is healthy in normal operation, but a wedged multipath
  device would cause `mount` to enter D state. Replaced all four with
  `PVE::Tools::run_command(..., timeout => 30)` and added an
  explicit `sync` before `umount`.

---

## [1.1.3] - 2026-04-09

### Three more bugs from a proactive sibling-pattern audit

After the four bugs in 1.1.2, the related project jt-pve-storage-netapp's maintainer ran
a proactive audit looking for other places that exhibited the same bug
patterns. Three more issues turned up. The Pure plugin had every one of
them. **Recommended over 1.1.2** — Bug E specifically can cause node
hangs through `clone_image` (or `alloc_image`) failure paths even
without the resize / rollback code paths from 1.1.2.

#### Fixed
- **[HIGH] Bug E — `alloc_image()` and `clone_image()` cleanup-on-failure
  paths called `volume_delete()` without first disconnecting the volume
  from the cluster hosts.** `_connect_to_all_hosts()` iterates every
  cluster host in per-node mode; if it succeeds on hosts 1..K and fails
  on K+1, the volume is still mapped to K hosts when the cleanup runs.
  Pure (unlike ONTAP) physically destroys a still-connected volume, but
  the orphaned host connection records cause iSCSI rescan on other
  cluster nodes to discover ghost LUNs that become stale multipath
  devices. Combined with `no_path_retry queue` in `defaults` — same
  root cause as the production hang incident that drove 1.1.0. Fixed
  by adding a `_disconnect_from_all_hosts()` helper that queries the
  array for the current connection list and disconnects each, and
  calling it BEFORE `volume_delete` in every cleanup path. Four sites
  fixed: `alloc_image()` main connect-fail cleanup, `alloc_image()`
  state/cloudinit "Cannot get WWID" cleanup, `alloc_image()` state/
  cloudinit "device did not appear" cleanup, and `clone_image()`
  connect-fail cleanup.
- **[LOW] Bug F — `volume_snapshot()` now flushes host-side dirty
  buffers before calling `snapshot_create` on the array**, mirroring
  what `volume_snapshot_rollback()` already did. For running VMs the
  qemu freeze handles consistency at the FS layer, but for offline
  volumes or external script callers (e.g. backup tools writing
  directly to a stopped-VM volume) the dirty page cache could be
  missing from the snapshot, producing a filesystem-inconsistent
  capture. Guarded by `is_device_in_use()` so we don't block on a busy
  live migration.

#### Removed
- **[LOW] Bug G + dead-export audit — four unused exported functions
  from `Multipath.pm`:** `multipath_add`, `multipath_remove`,
  `get_multipath_wwid`, `get_scsi_devices_by_serial`.
  `get_multipath_wwid` had a latent `/dev/mapper` symlink bug similar
  to the one fixed in `is_device_in_use` in 1.1.2; rather than fix
  dead code (and risk a future contributor seeing it in `@EXPORT_OK`
  and calling it), the function is removed entirely. The other three
  were also unused.

---

## [1.1.2] - 2026-04-09

### CRITICAL — four post-release forensic fixes ported from related project jt-pve-storage-netapp

A customer resize incident on the NetApp plugin uncovered four bugs that
the Pure plugin **also had**. One is a silent data-loss class bug. **All
production users on 1.0.x / 1.1.0 / 1.1.1 should upgrade immediately.**

#### Fixed
- **[CRITICAL — DATA LOSS] `is_device_in_use()` always returned 0 for
  `/dev/mapper/<wwid>` paths.** It used `basename($device)` to build the
  `/sys/block/<name>/holders` path, but for a multipath device that
  resolves to `/sys/block/<wwid>/holders`, which **does not exist** —
  the holders directory lives under `/sys/block/dm-N/`. The check
  therefore reported "not in use" for any multipath device regardless of
  whether an LVM volume group, dm-crypt container, dm-raid, or any
  other holder sat on top of it. `free_image()` then proceeded to
  delete the volume — taking the customer's LVM data with it. Any
  production environment that used LVM (or dm-crypt / dm-raid / bcache /
  ...) on top of Pure-managed volumes was at risk. Fixed by adding a
  `_resolve_block_device_name()` helper that resolves
  `/dev/mapper/<wwid>` symlinks to the underlying `dm-N` name before any
  `/sys/block/` access.
- **[HIGH] `get_multipath_slaves()`** had the same broken pattern. It
  always returned an empty list for `/dev/mapper/<wwid>` paths, which
  meant `free_image()`'s post-cleanup SCSI slave removal silently
  skipped every device, leaking SCSI residue across operations.
- **[HIGH] `volume_resize()`** called `rescan_scsi_hosts()` (host scan,
  used to discover **NEW** devices) instead of per-device rescan (used
  to re-read attributes of **EXISTING** devices). After a Pure-side
  resize the array showed the new size, but the multipath device kept
  reporting the old size, and QEMU's `block_resize` then failed with
  `Cannot grow device files` on a running VM. Fixed to do per-slave
  `echo 1 > /sys/block/sdX/device/rescan` followed by
  `multipathd resize map <name>` (a new helper) to refresh the size of
  the device-mapper layer above.
- **[HIGH] `volume_snapshot_rollback()`** had the same wrong rescan as
  the resize bug, plus a second issue: even after the underlying SCSI
  paths were refreshed, the kernel buffer cache could still hold pages
  from the post-snapshot content. Subsequent reads from the rolled-back
  volume could return stale data. Fixed to (1) per-slave rescan, (2)
  `multipath_resize_map`, AND (3) `blockdev --flushbufs <device>` to
  invalidate the kernel buffer cache.

#### Added
- `_resolve_block_device_name()` helper in `Multipath.pm`. Use this
  before any `/sys/block/<name>/` access on a path that could be
  `/dev/mapper/<wwid>`. Handles `/dev/sdX`, `/dev/dm-N`, and
  `/dev/mapper/<name>` (resolves the symlink).
- `multipath_resize_map()` helper in `Multipath.pm`, exported.

---

## [1.1.1] - 2026-04-09

### Multipath / anti-hang follow-ups

Discovered while reviewing v1.1.0 against the PVE storage plugin
development guide. **Recommended over 1.1.0** — 1.1.0 had the cluster
cleanup architecture but the multipath device template was still missing
`no_path_retry`, which meant a stale device on a host with
`no_path_retry queue` in `defaults` would still hang. This release closes
that gap.

#### Fixed
- **Pure multipath device template now sets `no_path_retry 30` and
  `fast_io_fail_tmo 5` explicitly.** Without these the per-device block
  inherited the `defaults` section value, which on many sites is `queue`
  (the historical NetApp HA recommendation). Combined with a stale Pure
  device this caused `sync` / `blockdev` / `multipath -f` to enter
  uninterruptible sleep — exactly what 1.1.0 was trying to prevent.
- **`_ensure_multipath_config` now version-marks the file it generates**
  (`# pure-multipath-config-version: 2`) and rewrites plugin-managed
  files when the marker version changes. Files **without** the marker are
  still left untouched (operator-edited or third-party). This means a
  1.0.x → 1.1.x upgrade actually picks up the new safety settings instead
  of silently keeping the old file forever.
  > **⚠️ Upgrade gotcha:** if your existing
  > `/etc/multipath/conf.d/pure-storage.conf` was created by an earlier
  > plugin version (1.0.x), it has NO marker line, so 1.1.x will leave
  > it alone. You must either manually align it with the new device
  > block (see README "Upgrade SOP" → callout box) or `rm` the file to
  > let the plugin recreate it. Otherwise the new `no_path_retry 30`
  > / `fast_io_fail_tmo 5` safety settings will not be in effect.
- Replace bare `system('fuser', ...)` in `is_device_in_use` with a
  timeout-bounded `_run_cmd` (5s). `fuser` opens the device path; on a
  wedged multipath device with `queue_if_no_path` it can itself enter D
  state and never return.
- Replace bare `system('sync')` and `system('blockdev', ...)` in
  `volume_resize` with `PVE::Tools::run_command(..., timeout => 10)`.
- Add `_udev_refresh()` helper that calls `udevadm trigger` and
  `udevadm settle` via `PVE::Tools::run_command` with a 10s timeout, and
  replace all 13 bare `system('udevadm ...')` calls in the plugin and
  the Multipath module with the helper.

---

## [1.1.0] - 2026-04-09

### Major reliability release — port the v0.2.x lessons-learned fixes from the related project jt-pve-storage-netapp

Validated by a real production incident where stale multipath devices
combined with `queue_if_no_path` put PVE daemons into uninterruptible
sleep requiring a node reboot.

#### Anti-hang protections (Section 1)
- Add `sysfs_write_with_timeout` / `sysfs_read_with_timeout` helpers in
  `Multipath.pm`. All direct writes to `/sys/class/scsi_host/*/scan`,
  `/sys/class/block/*/device/{delete,rescan}` and reads from
  `/proc/mounts` and `/sys/.../wwid` now go through forked
  timeout-bounded children so an unresponsive HBA cannot put the parent
  process into D state.
- Replace bare `system('sync')` / `system('blockdev')` in cleanup paths
  with timeout-bounded `_run_cmd` calls.
- `cleanup_lun_devices` now disables `queue_if_no_path` with `multipathd`
  and issues `dmsetup message ... fail_if_no_path` BEFORE attempting
  `sync` / `blockdev` / `multipath -f`. Otherwise queueing causes those
  operations to hang forever on a dead device.
- `multipath_flush` now refuses to run without a device argument (it
  used to fall through to `multipath -F` which flushes ALL maps
  system-wide and can disconnect customer-managed non-Pure storage).
- `multipath_flush` has a built-in `dmsetup --force` fallback if
  `multipath -f <wwid>` fails or times out.

#### Cluster safety (Section 2)
- Add `is_portal_logged_in()` in `ISCSI.pm` and use it from
  `login_target` and `activate_storage`. Pure controllers share one IQN
  across multiple LIFs; checking by target only made the second-and-later
  portal logins silently no-op, leaving the host with one path instead
  of N.
- `login_target` now sets `node.session.timeo.replacement_timeout` to
  120 so transient outages and Pure controller failovers recover
  cleanly regardless of `iscsid.conf` state.
- `activate_storage` skips `iscsiadm discovery+login` for
  already-connected portals (saves up to 30s discovery latency on every
  status poll).

#### `free_image` operation order (Section 3)
- Capture multipath slave device list **before** unmap (after unmap the
  `/sys/block/.../slaves` directory disappears).
- Disconnect from ALL hosts FIRST, then clean local devices, then delete
  the volume on the array. The previous order allowed an in-flight
  iSCSI rescan from another node to re-import the LUN and recreate the
  multipath device behind us.
- After `cleanup_lun_devices`, also remove residual SCSI slave devices
  using the captured list and reload `multipathd` to settle state.

#### API resilience (Section 4)
- Default UA timeout reduced from 30s to 15s and retry count from 3 to
  2 (worst case ~34s instead of ~102s).
- `_request` now accepts a per-call `timeout` option that overrides the
  UA timeout for that single call and is restored on every exit path.
- `volume_delete` uses a 60s per-call timeout because Pure volume
  destroy can be slow when the volume has many snapshots.
- 401 retry now also re-applies any per-call timeout override after
  `_create_session` may have rebuilt the LWP::UserAgent.
- `status()` now fail-fasts on API errors (returns inactive zeros)
  instead of letting the polling thread block.
- `status()` now runs orphan / temp-clone cleanup in a double-forked
  grandchild that gets reparented to init, so cleanup never blocks the
  storage daemon.

#### Cluster residual / orphan cleanup (Section 5)
- Add WWID tracking infrastructure: per-storage state file at
  `/var/lib/pve-storage-purestorage/<storeid>-wwids.json` with
  file-locking via
  `/var/run/pve-storage-purestorage/<storeid>-wwids.lock`. Lock
  acquisition uses non-blocking `flock` with bounded retries (10s
  deadline) to avoid blocking forever on a stuck worker.
- `path()` tracks the WWID after successfully resolving a real device.
- `free_image` conditionally untracks the WWID only after confirming
  the local multipath device is gone — if cleanup left a stale device,
  the WWID stays tracked so the next orphan cleanup pass can retry.
- `_cleanup_orphaned_devices` runs in three phases:
  1. **Auto-import**: every current Pure-managed LUN WWID from the array
     is added to local tracking (so all cluster nodes converge on the
     same alive set).
  2. **Cleanup**: for each tracked WWID not on the array, clean its
     local stale device if any.
  3. **Warn**: list Pure multipath devices not in tracking and not on
     the array (do **not** auto-clean — could be customer-managed).

#### postinst (Section 6)
- Print a "CRITICAL Multipath Safety Rules" banner explaining
  `multipath -F` vs `multipath -f`, restart vs reload, and the
  recommended Pure-friendly multipath.conf settings.
- Detect dangerous `/etc/multipath.conf` settings (`no_path_retry queue`,
  `queue_if_no_path`, `dev_loss_tmo infinity`) and warn without
  auto-modifying the customer's config.
- Detect existing stale Pure multipath devices on upgrade and list the
  exact manual cleanup commands.
- Pre-create `/var/lib/pve-storage-purestorage` and
  `/var/run/pve-storage-purestorage` with mode 0700.

#### Code quality (Section 7)
- `alloc_image` now retries on disk-id collision (TOCTOU between
  `_find_free_diskid` and `volume_create` when two workers race).
- `path()` now has a proper retry loop bounded by `pure-device-timeout`
  (default 30s) instead of a one-shot rescan.
- `list_images` template-detection fallback now has a 10s wall-clock
  deadline so a slow array does not cascade timeouts across hundreds of
  volumes.

#### Documentation (Section 8)
- README.md and README_zh-TW.md gain prominent **CRITICAL: Multipath
  Safety Rules** and **Upgrade SOP** sections near the top.
- New `docs/TESTING.md` and `docs/TESTING_zh-TW.md`: Pure-Storage-specific
  test plan covering basic connectivity, VM lifecycle, hot-plug,
  snapshot/clone, cluster orphan cleanup, mixed-environment safety,
  failure injection (controller failover, blocked LIFs, blocked API,
  `queue_if_no_path` + stale device hang), API 1.x and 2.x coverage,
  naming edge cases, pod (ActiveCluster) mode, per-node vs shared host
  mode, performance/sanity, and upgrade path.

---

## [1.0.49] - 2026-02-27

### Second-round audit fixes for reliability and correctness

- Fix `volume_snapshot_list` double-encoding `pve-snap-` prefix, which
  caused `snapshot_delete` to fail on re-encoded names.
- Fix `list_images` passing pod-prefixed name to `pure_to_pve_volname`,
  causing decode failure for cloudinit / state volumes in pod setups.
- Fix `parse_volname` returning undef instead of die (violates PVE
  storage plugin API contract, causes silent failures).
- Fix `pve-pure-config-get` LXC detection operator precedence that
  misidentified QEMU VMs with an `arch:` line as LXC containers.
- Fix `pve-pure-config-get` `umount` calls to use list-form `system()`
  to prevent shell injection.
- Fix `_backup_vm_config` missing `cleanup_lun_devices` on error paths,
  leaving stale SCSI devices after failed backup.
- Fix API cache fork-safety with PID check to prevent stale session
  tokens in forked PVE daemon workers.
- Fix `deactivate_storage` to check `is_device_in_use` before
  disconnect, preventing cleanup of volumes still in use by other VMs.
- Fix `alloc_image` orphan cleanup missing `skip_eradicate`, which
  could permanently eradicate volumes on allocation retry.
- Replace ad-hoc `multipathd reconfigure` shell calls with
  `multipath_reload()` for consistency.
- Fix `SG_INVERT` typo to `SG_INQ` in `Multipath.pm`.
- Fix config volume name length check in `encode_config_volume_name`
  to truncate `snapname` when total exceeds 63 chars.
- Move `IO::Select` imports to file-level in `ISCSI.pm` and
  `Multipath.pm`.
- Fix `pve-pure-config-get` restore mode cleanup on config write error
  (`umount` and `disconnect` now always run).
- Remove dead code in `pve-pure-config-get` restore mode.

## [1.0.48] - 2026-02-12

### Security and reliability audit fixes across all modules

- Fix `path()` returning `/dev/null` or synthetic path on API failure,
  now properly dies to prevent silent data corruption (CRITICAL).
- Fix `get_multipath_device` using substring WWID match that could
  return wrong device, now uses exact match only (HIGH).
- Fix `get_device_by_wwid` glob patterns to use exact suffix match
  instead of substring to prevent device collision (HIGH).
- Fix ISCSI `_find_multipath_device` and `wait_for_device` to use exact
  serial suffix matching instead of substring (HIGH).
- Fix `_cleanup_orphaned_temp_clones` ISO 8601 timestamp parsing for
  API 2.x (was comparing string to epoch, never cleaning up).
- Fix `clone_image` disk ID allocation race by using `_find_free_diskid`
  instead of manual `max+1` logic.
- Fix `_find_free_diskid` to strip pod prefix before
  `decode_volume_name`.
- Fix `pve-pure-config-get` restore mode boolean logic that always
  errored in restore mode.
- Fix `pve-pure-config-get` `san_storage` to use `sanitize_for_pure`.
- Fix shell injection in `is_device_in_use` `fuser` call and
  `_backup_vm_config` system calls (use list form).
- Fix `_backup_vm_config` mount cleanup on error path.
- Add in-use guard to `cleanup_lun_devices` to prevent cleaning devices
  that are still mounted or held open.
- Fix `_run_cmd` in `ISCSI.pm` and `Multipath.pm` to use `IO::Select`
  for simultaneous stdout / stderr reading (prevents deadlock).
- Fix `_run_cmd` timeout to kill child process (prevents orphans).

---

## [1.0.0] – [1.0.47]

Earlier development history. See `debian/changelog` for the full
per-release detail. Highlights:

- **1.0.0** — initial release, basic iSCSI Pure Storage support.
- **1.0.x** — incremental additions: FC support, API 1.x and 2.x dual
  client, snapshot / clone / template / linked-clone, cloudinit and
  state and TPM volumes, LXC support, ActiveCluster pod support, VM
  config backup volumes, `pve-pure-config-get` CLI, multipath helper
  module, naming module, host get-or-create with race handling, batch
  snapshot query for `list_images`.

Anything before 1.0.48 should be considered superseded — for production
use, install 1.1.1 or later.

---

## Author

Jason Cheng (Jason Tools) — jason@jason.tools — MIT License
