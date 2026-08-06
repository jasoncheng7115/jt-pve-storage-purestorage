# Changelog

All notable changes to **jt-pve-storage-purestorage** are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to a `MAJOR.MINOR.PATCH-DEBIAN` versioning scheme.

語言 / Language: [English](CHANGELOG.md) | [繁體中文](CHANGELOG_zh-TW.md)

---

## [1.1.32] - 2026-08-06

### Fixed
- A node could destroy a temp snapshot clone belonging to another node when
  `pure-host-mode = shared`. A temp clone is connected only to the node that
  created it, so both reapers establish ownership by asking whether the clone
  is connected to a host other than this node's. In shared mode every node
  reports the same Pure host name, so that question answers "it is mine" for a
  clone created anywhere in the cluster -- and the creating node's own in-use
  check protects only itself. A second node could therefore disconnect and
  destroy a clone the first was actively reading, which is exactly the
  incident the ownership check was added for. Where ownership cannot be
  established the reapers now wait out any plausible operation: 24 hours in
  shared mode, instead of 60 seconds for the fast sweep and 1 hour for the
  background reaper. `per-node` mode is unchanged, and a genuinely stale clone
  is still collected in shared mode.
- The host-name collision check added in 1.1.31 ran ahead of the
  host-verification cache, so it repeated on every pvestatd poll instead of
  once per cache interval. Negligible in measurement, but `activate_storage()`
  is a hot path and the cache exists precisely to keep it empty.

### Added
- A warning when a snapshot-access clone name exceeds the 63 characters Pure
  allows. The name is the volume name plus 36 characters, so a storage id
  longer than about 13 characters pushes it over even though the disk volume
  itself fits. If the array rejects it, snapshot access fails -- backing up
  from a snapshot, `qemu-img convert` out of one, a container backup -- with
  an error that never mentions the storage id.

## [1.1.31] - 2026-08-06

### Fixed
- Two storages whose ids differ only by `-`, `_` or `.` owned the same Pure
  volumes. Volume names are built from the storage id with characters Pure
  cannot use removed and `-` mapped to `_`, so `pure-prod`, `pure_prod` and
  `pure-p.rod` all produce `pve-pure_prod-<vmid>-disk<n>`. That prefix is the
  only thing that scopes ownership: `list_images()`, the orphan reaper, the
  temp-clone reaper and the config-volume cleanup all ask the array for
  `pve-<prefix>-*` and treat every answer as their own. Two colliding storages
  on one array therefore shared a namespace -- each listed the other's disks,
  and deleting through one could destroy a volume the other's guests were
  running on. Adding such a storage is now refused with a message naming the
  existing storage; updating one only warns, so an existing pair stays
  editable.

### Added
- A warning when another node in the cluster produces the same Pure host name.
  Node names are truncated to 20 characters, so `virtualization-node-01` and
  `virtualization-node-02` both become `pve-pve-virtualization-node-`: the
  first node creates the host, the second adds its initiator to it, and the
  array can no longer tell them apart. Every per-node ownership check is then
  wrong, including the temp-clone reaper's. The plugin reports this rather
  than renaming the host object, because the existing volume connections hang
  off the current name and the array would reject the initiator as already in
  use elsewhere. `pure-host-mode = shared` is excluded, where one shared host
  object is intended.

## [1.1.30] - 2026-08-06

### Fixed
- Running container snapshots were quiesced by nothing at all. Proxmox VE
  cgroup-freezes an LXC container's processes before calling
  `volume_snapshot()`, but freezes the filesystem only for storages that ask
  for it through `volume_snapshot_needs_fsfreeze()`, which this plugin did not
  implement. Freezing the processes stops new writes without pushing out the
  dirty pages the host kernel is already holding, and the array takes its
  snapshot over REST, out of band from this host's block layer. Running
  container snapshots -- including vzdump backups in snapshot mode -- were
  therefore crash-consistent rather than filesystem-consistent. `RBDPlugin`
  does the same for the same reason. QEMU guests were never affected: their
  filesystem quiescing runs through the guest agent and never consults this
  method.
- The pre-snapshot `sync` and `blockdev --flushbufs` were skipped when the
  device was in use, which is precisely when there are dirty pages to flush --
  a running container's filesystem is mounted by the host kernel. Both calls
  now run regardless, still bounded and still best-effort.
- `rename_snapshot()` and `volume_snapshot_info()` are refused explicitly.
  The inherited implementations route through `filesystem_path()`, which this
  plugin cannot implement, and base `rename_snapshot()` would have attempted a
  filesystem `rename()`. Neither is reachable today; the explicit refusal
  gives a future caller a straight answer.

## [1.1.29] - 2026-08-06

### Changed
- `api()` now negotiates the storage API version with the running Proxmox VE
  rather than claiming a fixed 13. `APIVER` lives in `libpve-storage-perl`,
  which versions independently of `pve-manager` and moved 13 -> 14 -> 15
  within the 9.1 point releases, so no fixed number is correct on every node.
  Claiming below the running `APIVER` made Proxmox VE print
  `Plugin ... is implementing an older storage API, an upgrade is recommended`
  on every `pvesm`, `qm` and `pct` call and on every daemon start; claiming
  above it would have made older libraries refuse to load the plugin, removing
  every purestorage storage from the node. The plugin now claims
  `min(APIVER, 15)`, floored at 9, and falls back to 13 when `PVE::Storage` is
  not loaded. No functional change: `api()` is only a load-time gate and
  nothing in Proxmox VE branches on the value afterwards.

### Fixed
- `volume_resize()` accepted the `$snapname` parameter added in API version 14
  and silently dropped it, which would have resized the parent volume when the
  caller meant a snapshot. It is now refused with an explanatory message.
  Not reachable in practice: Proxmox VE only passes a snapshot name when
  `snapshot-as-volume-chain` is set, which this plugin does not offer.

## [1.1.28] - 2026-08-06

Follow-up to the v1.1.25 credential change: a warning at the one point in the
migration where a mixed-version cluster can bite.

### Upgrading is safe; migrating before every node is upgraded is not

Installing the package needs no coordination. It does not touch storage
configuration, so `on_add_hook` / `on_update_hook_full` never run, no secret
file is written, and an un-migrated storage keeps authenticating from the
value still in `storage.cfg` — on old and new nodes alike.

The hazard is the migration command itself:

```bash
pvesm set <storeid> --pure-api-token <token>
```

`/etc/pve` is replicated, so the secret file reaches every node immediately.
But a node still running a plugin older than 1.1.25 does not know to read it,
and the cleartext copy it *was* reading has just been removed. That node's
storage stops authenticating until its package is upgraded.

The plugin now says so at the moment the operator takes that risk, rather than
at install time when the decision is not yet in front of them:

```
Storage 'pure1': moved 'pure-api-token' out of storage.cfg into
/etc/pve/priv/storage/pure1.pure-token (root-only).
  IMPORTANT: every node in this cluster must be running plugin version 1.1.25
  or later before this takes effect safely. Older nodes read the credential
  from storage.cfg, which no longer holds it, and will fail to authenticate
  against the array. Check with:
    pvesh get /nodes --output-format json | grep -o '"node":"[^"]*"'
    # then on each: dpkg -l jt-pve-storage-purestorage
```

Both READMEs gained the same ordering requirement, and state explicitly that
the package upgrade itself needs no coordination — so the warning is not read
more broadly than it should be.

**Recommended order:**

1. Upgrade every node and `systemctl restart pvestatd` on each.
2. Confirm with `dpkg -l jt-pve-storage-purestorage` that every node is on
   1.1.25 or later.
3. Everything works normally at this point; the token is still in
   `storage.cfg` and the plugin falls back to it.
4. Only then migrate, one storage at a time, verifying with
   `pvesm status <storeid>` before moving on.

There is no time pressure between steps 3 and 4 — an un-migrated storage works
indefinitely, the token is just still in cleartext.

---

## [1.1.27] - 2026-08-06

Documentation release: the management address the plugin is pointed at
determines whether a controller failover is transparent or takes the storage
offline.

### `pure-portal` must be the array's virtual management IP

A FlashArray is assigned three management addresses at setup: one per
controller (`ct0.eth0`, `ct1.eth0`), plus a virtual IP (`vir0`) bound to
whichever controller currently holds the management primary role.

Pointed at a controller's own address, the plugin loses the REST API the
moment that controller fails over: `activate_storage()` cannot reach the array
and the storage goes `inactive` after three consecutive failed polls (~30s).

What does **not** break is worth knowing: running guests keep running.
`status()` failing does not touch any device, so the multipath maps stay
mapped and I/O continues on the data path. What stops is everything that needs
the array's API — create, delete, resize, snapshot, clone, migrate — plus the
capacity figures in the UI.

This is the same requirement Pure places on its other integrations. Pure's
OpenStack Cinder driver documentation states that "the Management VIP address
is required to properly configure the FlashArray driver", and the FlashArray
vSphere Plugin refuses to install with a "No virtual IP configured" error.

Documented in both READMEs — including the remove-and-re-add procedure, since
`pure-portal` is a fixed property that cannot be changed with `pvesm set` — on
the documentation site, and in the `pure-portal` property description itself,
so it also appears in `pvesm set --help` and the storage API schema.

No behaviour change.

---

## [1.1.26] - 2026-07-27

Management-plane load release, continuing the work started in v1.1.21.

### MEDIUM — Roughly half the steady-state REST calls were avoidable

Counting what a single pvestatd poll costs — per node, per storage, every ~10
seconds — turned up four calls that did not need to be made:

- **The pod was fetched twice.** `get_managed_capacity()` fetched the pod
  object and then called `pod_get_quota_limit()`, which fetched the same pod
  object again. The already-fetched object is now passed in.
- **Every new client re-detected the REST version.** `_detect_api_version()`
  costs at least one unauthenticated `GET /api/api_version`, and up to nine
  more probes if that fails. It ran for every client object: the plugin's
  client cache expires after 300s, and the background reaper forks and so
  always builds a fresh one. An array does not change its REST version while
  pvedaemon is running, so the result is now cached per array for the life of
  the process. A fallback guess made because the array did not answer is
  deliberately **not** cached — the next client should detect properly rather
  than inherit the guess.
- **Every forked reaper pass logged in again.** A Pure `x-auth-token` is a
  bearer token, so a new client can be seeded with a session another client
  already established. What must not be shared across a fork is the
  keep-alive socket, and each client still builds its own UA. A stale token
  costs exactly one 401, after which the existing retry path re-logs in.
- **`activate_storage()` re-asked for things that do not change.** It fetched
  the iSCSI port list and re-verified the host object on every poll. Both are
  now cached per process for `API_CACHE_TTL` (300s). The host entry is
  recorded only *after* the check actually succeeds, so a transient failure
  cannot silence the check for a whole TTL; and if the host object is removed
  on the array mid-window, `volume_connect_host()` still fails with a clear
  error.

Measured in a harness with a counting API stub, over three consecutive polls
of `activate_storage()` + the foreground of `status()`: **15 calls before, 8
after.**

For a five-node cluster with two Pure storages that is a drop from roughly
nine REST calls per second at complete idle to under four.

### MEDIUM — A rename could be retried, stranding a volume forever

`volume_rename()` and `snapshot_rename()` are `PATCH` requests, and
`_request()` only excluded `POST` from its 5xx retry — while LWP reports a
read timeout as a synthetic 500. So a rename whose response was lost got
retried, the retry addressed a name that no longer existed, it came back 404,
and the caller concluded the rename had failed.

In `volume_delete()`'s tombstone path that meant: destroy under the
**original** name → 404 → report the delete as failed → leave a
renamed-but-alive volume on the array. The operator's retry then found nothing
under the original name, reported "may have been already deleted", and the
volume was stranded permanently — still consuming capacity and the array's
volume count, with nothing left that would ever find it again.

Both renames now use a new `no_retry` option, and on failure verify against
the array whether the rename actually took effect before believing the error.
Idempotent operations keep their retry resilience.

### MEDIUM — A `pure-pod` that does not exist is now a hard error

The capacity lookup fell back to the array total, so a typo in `pure-pod` made
the storage report the whole array as free while every volume create failed
because the pod was missing — two symptoms that contradict each other, with
only a generic warning in the pvestatd log to connect them.

### Documentation

Two storages sharing one Pod double-count capacity in Proxmox VE: each reports
the Pod's quota as its own total and the Pod's provisioned size as its own
used. Volume names stay correctly isolated, so nothing breaks, but "available"
is wrong on both. Documented in the Pod section of both READMEs.

---

## [1.1.25] - 2026-07-27

Credential-storage release. The array credentials no longer live in
`/etc/pve/storage.cfg`.

### MEDIUM — The API token was stored in cleartext and returned by the config API

PVE 9 lets a plugin declare which of its properties are sensitive, through
`plugindata()->{'sensitive-properties'}`. The storage-config API pulls those
keys out of the request before the config is written and hands them to
`on_add_hook` / `on_update_hook` instead, so the plugin can put them
somewhere protected.

We never declared it. The list therefore fell back to PVE's hardcoded
`encryption-key keyring master-pubkey password`, which covers neither
`pure-api-token` nor `pure-password`. Both sat in `storage.cfg` in cleartext,
and `GET /storage/<id>` returned them — an endpoint that needs
`Datastore.Allocate` on that storage, not root. A Pure API token is typically
array-wide, so that is full control of the FlashArray rather than of one
storage.

Credentials now live in `/etc/pve/priv/storage/<id>.pure-token` and
`<id>.pure-pw`, mode 0600, in a directory pmxcfs keeps root-only — the same
place `PBSPlugin` and `CIFSPlugin` keep theirs.

### Upgrading

**No action is required.** An existing storage keeps working unchanged:
`_resolve_credentials()` prefers the out-of-config secret and falls back to
the value in `storage.cfg`, and a PVE storage update is a merge, so an
unrelated `pvesm set` cannot drop the in-config token either.

**To complete the migration** and remove the cleartext copy, run once per
storage:

```bash
pvesm set <storeid> --pure-api-token <token>
```

That writes the secret file **and** removes the old line from `storage.cfg`,
in one command.

> Do **not** use `pvesm set <storeid> --delete pure-api-token` for this. PVE
> reports a deletion to the plugin as an explicit removal, so it deletes the
> secret file as well and leaves the storage with no credentials at all.

### MEDIUM — The volume name PVE asks for is now honoured

PVE requests a specific name in four places:

| Caller | Name |
|---|---|
| `QemuConfig.pm` | `vm-<vmid>-state-<snap>` (RAM snapshot) |
| `API2/Qemu.pm`, `Cloudinit.pm` | `vm-<vmid>-cloudinit` |
| `VZDump/QemuServer.pm` | `vm-<vmid>-fleece-<n>` (backup fleecing) |
| `API2/Storage/Content.pm` | whatever the operator types to `pvesm alloc` |

Anything the plugin did not recognise fell through to the regular-disk
branch, which **ignored the requested name** and allocated
`vm-<vmid>-disk-<N>` instead. Backup fleecing images therefore came back
looking like ordinary VM disks and consumed a disk id in the guest's
numbering. (Backups still worked, because PVE records and reuses whatever
volid the plugin returns.)

Fleecing is now a first-class volume type — `pve-<storage>-<vmid>-fleece<n>`
on the array, excluded from disk-id allocation — and an unrecognised explicit
name is refused with a message naming the four supported forms instead of
being silently substituted. `LVMPlugin` and `ZFSPoolPlugin` accept any
`vm-<vmid>-<...>` for the same reason.

### Also

- `_get_api()` now requires the storeid, since that is how the credentials are
  located. All 21 call sites pass it, and `tools/audit-invariants.pl` enforces
  it statically so a future call site cannot silently omit it and fall back to
  the legacy path.
- A storage with no resolvable credentials fails with a message naming the
  command to fix it, rather than a generic constructor error.

---

## [1.1.24] - 2026-07-27

Correctness release. Three of these are silent: the plugin and Proxmox VE
disagreed about something, and nothing in either reported an error.

### CRITICAL — Linked clones could gain a phantom "unused" disk pointing at the live volume

`clone_image()` returns `base-102-disk-0/vm-104-disk-0` for a linked clone,
and that is what the guest config stores. `list_images()` reported the bare
`vm-104-disk-0`.

`PVE::QemuServer::update_disk_config` — the code `qm rescan` drives — marks a
volume referenced using the volid from the config, then checks that set
against the volids the plugin reports. With the two forms disagreeing, the
volume looked unreferenced and PVE called `add_unused_volume()`. The guest
ended up with an `unusedN` entry pointing at **the same Pure volume its
`scsi0` was running on**, and removing that "unused disk" in the GUI destroys
the live disk.

`list_images()` now derives the base from Pure's `source` field and emits the
`base/clone` form. Only a `.pve-base` snapshot source is accepted, so full
clones and clones taken from user snapshots keep their bare name — matching on
anything else would invent a dependency that does not exist and produce the
mirror image of this bug. When the array does not report `source` the
behaviour is unchanged. `RBDPlugin::list_images` does the equivalent from the
rbd parent snapshot.

### HIGH — Container backups leaked a Pure volume per mountpoint, indefinitely

`PVE::VZDump::LXC` calls `activate_volumes($cfg, $volids, 'vzdump')`, which
lands in our `path()` and creates a snapshot-access clone on the array,
connects it to the host and waits for its multipath device. It then mounts,
rsyncs, umounts and deletes the `vzdump` snapshot — and never calls
`deactivate_volume` at all (`grep -c deactivate_volume VZDump/LXC.pm` returns
zero), so `_cleanup_temp_snap_clone()` was never invoked.

That is one leaked Pure volume, one host connection and one local multipath
device per container mountpoint per backup run. The one-hour orphan reaper was
the only backstop, and per the millisecond-timestamp bug fixed in v1.1.22 it
never ran at all on an API 2.x array — so sites with scheduled container
backups have been accumulating these since the plugin was installed.

Cleanup is now triggered from `volume_snapshot_delete()`, which PVE does
reliably call, with the same ownership, age and in-use gates as the background
reaper.

**Check for a backlog** after upgrading:
`journalctl -t pvestatd | grep 'temp-clone'`, or look for volumes matching
`pve-<storage>-*-temp-snap-access-*` in the Pure UI.

### HIGH — Resizing a disk did not reach the local device

The local refresh in `volume_resize()` was gated on `$running`. Resize a
stopped VM's disk and the local multipath map keeps the old size; start the
guest and qemu presents the old capacity to it, with no error anywhere. The
same applied to resizing on one node and starting the guest on another, which
no amount of gating could have covered.

The refresh now runs unconditionally — it is a no-op when this node has no
local device for the volume — and `activate_volume()` reconciles the array
size it has already fetched against `blockdev --getsize64`, rescanning only
when they disagree. The whole refresh is best-effort: the array-side resize
has already succeeded by then, so a local failure must not be reported as a
failed resize (a retry would be rejected as a shrink).

This also fixes container resize, which had never worked on this plugin.
`PVE::API2::LXC` always calls `volume_resize(..., $running = 0)` — its own
comment says the parameter only makes sense for QEMU — so the gated refresh
never ran for a container at all. PVE then maps the volume and runs
`resize2fs` against a device still reporting the old capacity, and the
failure surfaces only as a `warn`. The array volume grew, the CT config
recorded the new size, and the filesystem did not change.

### MEDIUM — `$vollist` was matched by prefix

`$vollist` holds complete volids and the base plugin compares them exactly.
A prefix match returned `vm-10-disk-10` and `vm-10-disk-11` when asked for
`vm-10-disk-1`. No current PVE caller passes a vollist, but returning volumes
the caller did not ask for is how "the migration moved a disk I did not
select" happens.

---

## [1.1.23] - 2026-07-27

Data-safety release. Every finding here is one variant of the same design
mistake: a safety check that, when it could not complete, answered "safe to
proceed" instead of "I do not know". Nothing in this release changes normal
operation on a healthy node — it changes what happens on an unhealthy one.

### CRITICAL — The in-use guard now fails CLOSED

`is_device_in_use()` collapsed "I could not determine the answer" into "not in
use". Every internal failure — a `/proc/mounts` read that timed out, a `fuser`
call killed by its own 5-second watchdog, a device path that would not
resolve — fell through to `return 0`.

Why that is severe: for a raw Pure LUN attached to a running VM there is no
mount point and no real holder (the kpartx partitions are deliberately ignored
since v1.1.7), so **`fuser` is the only positive signal that a guest has the
device open**. A timed-out `fuser` therefore turned "a VM is using this disk"
into "nothing is using this disk" — precisely when the node was unhealthy
enough for that watchdog to fire — and `free_image()` would go on to
disconnect the volume from every host and destroy it.

New `device_usage_state()` returns `in-use` / `idle` / `unknown` together with
a human-readable reason. `is_device_in_use()` is now a wrapper that treats
`unknown` as in use. Callers report the reason, so an operator sees *why* the
plugin refused rather than a bare failure.

### CRITICAL — A failed WWID lookup no longer disables the guard

`free_image()`, `volume_snapshot_rollback()` and `create_base()` each did:

```perl
my $wwid = eval { $api->volume_get_wwid($pure_volname); };
if ($wwid) { ... the entire in-use check ... }
... destroy / overwrite anyway ...
```

so a single transient REST error skipped the check and ran the destructive
operation unprotected. Rollback was the worst case: `volume_overwrite()`
replaces the volume's contents outright and, unlike a destroy, has **no
eradication-delay recovery window**.

All three now go through `_require_wwid_for_guard()`, which retries once and
then refuses with an actionable message. A failure to *look up* the local
device is likewise an error rather than being read as "there is no local
device".

### HIGH — No automated path performs an unrecoverable eradication

The orphaned temp-clone reaper and the per-session temp-clone cleanup called
`volume_delete()` without `skip_eradicate`, i.e. `DELETE /volumes` —
permanent, with no recovery window, issued from a background reaper. Both now
soft-destroy, so all 15 delete call sites in the plugin are recoverable within
the array's eradication delay.

Note this reaper only began running at all in 1.1.22: before the millisecond
timestamp fix its age test could never be true on an API 2.x array.

### HIGH — The temp-clone reaper verifies candidates locally

Pure's array-side filter has no anchoring, so the glob
`pve-<storage>-*-temp-snap-access-*` is looser than the names the plugin
actually generates. The reaper now re-matches every candidate against the
exact form `path()` produces —
`pve-<storage>-...-temp-snap-access-<unix-ts>-<pid>` — and skips anything else
with a warning. It also requires **two independent age sources** to agree
before deleting: the array's `created` timestamp and the unix timestamp baked
into the name at creation. They come from different clocks and different code
paths, so a bug or unit mix-up in either one cannot on its own authorise a
deletion.

### HIGH — `alloc_image()` checks before replacing a state/cloudinit volume

This was the only destructive path in the plugin with no in-use check at all:
on finding an existing `vm-<id>-state-<snap>` or `vm-<id>-cloudinit` volume it
disconnected and destroyed it, with a `warn()` as the only trace. A volume
holding a live suspended guest's RAM image would be discarded. It now applies
the same guard every other destroy path uses.

### HIGH — Two mirrored `volume_list()` calls that cancelled each other out

`volume_list()` takes one positional argument, but two call sites passed named
arguments, so `$pattern` bound to the literal string `"pattern"` and the array
was asked for a volume with that exact name:

- `_cleanup_vm_config_volumes()` therefore never deleted anything.
- `free_image()`'s "is this the VM's last disk?" test was always true.

The two bugs cancelled out into "config backup volumes leak". **Fixing only one
side would have started destroying config backups on the first disk deletion of
a multi-disk VM, while snapshots of the remaining disks still referenced
them** — so both are fixed together. `free_image()` now skips the cleanup
entirely rather than guessing when the disk list cannot be retrieved.

### HIGH — Fibre Channel: no more LIP on every rescan

A Loop Initialization Primitive is a **link reset**, not a lookup. It forces
every device behind that HBA port to re-login, including LUNs belonging to
other storage on the same HBA. It is not needed to discover a newly mapped
LUN — the SCSI host scan does that via `REPORT_LUNS` on the existing session.

`rescan_fc_hosts()` issued one unconditionally, and it is called from tight
loops: `path()`'s retry loop (every 2s), `alloc_image()`'s wait loop (every
3s), `wait_for_multipath_device()`'s FC callback (every round), and — before
v1.1.22 — `activate_storage()` on every pvestatd poll. That is a repeated
fabric-wide link reset in exchange for nothing. LIP is now opt-in
(`rescan_fc_hosts(lip => 1)`) and is not used anywhere by default.

`FC.pm` also now reads sysfs through `sysfs_read_with_timeout()` instead of a
bare `open()`. Reading `/sys/class/fc_host/*/port_state` blocks indefinitely
on a wedged HBA, and `get_fc_targets()` runs from `activate_storage()` on the
pvestatd path.

### HIGH — `pve-pure-config-get` cannot hang any more

The disaster-recovery tool used bare `system('mount', ...)` / `system('umount',
...)` with no timeout. A mount against a multipath device whose paths are gone
enters uninterruptible sleep and never returns — and this tool only ever runs
when storage is already in trouble, so that is the expected state, not an edge
case. Ctrl-C does not help. Every external command now goes through
`PVE::Tools::run_command` with an explicit timeout, matching the rule the rest
of the plugin has followed all along.

It also now uses `PVE::INotify::nodename()` rather than `hostname -s`, so it
connects volumes to the same Pure host object the plugin registered, and wraps
device cleanup so a refusal cannot abort a restore whose config has already
been written.

### HIGH — Restore picks the newest destroyed generation

A disk deleted and recreated several times leaves several tombstones, all of
which strip back to the same original name. Sorting them lexically selected
the **oldest** generation; the newer ones then hit a rename-back conflict that
aborted the entire restore. Selection now uses the unix timestamp embedded in
the tombstone suffix, and the tool prints which generation it chose and what
else was available.

### HIGH — The temp-clone reaper respects ownership

A temp clone is connected only to the node that created it, but every node
runs the reaper. Node A's own reaper is stopped by `is_device_in_use()`; node
B has no local device for the clone, sails past that check, disconnects it
from **all** hosts and destroys it. A snapshot-source operation running longer
than an hour on node A — a `qemu-img convert` of a large disk routinely is —
had its device pulled out from under it. The reaper now skips any temp clone
still connected to another node; orphans left by a crashed node are reaped by
that node when it returns, which is the correct owner anyway.

### MEDIUM — Other hardening

- `remove_scsi_device()` verifies the device still carries the expected WWID
  before deleting it. `free_image()` captures the multipath slave list before
  the array-side disconnect and deletes those slaves afterwards; the kernel
  reuses `/dev/sdX` names, so a concurrent rescan could hand the same name to
  an unrelated LUN whose path would then be removed.
- `volume_get_connections()` distinguishes "no connections" from "the query
  failed". Returning an empty list for both made `free_image()` skip the
  disconnect and destroy anyway, leaving orphaned host connections — the ghost
  LUNs behind the v1.1.3/v1.1.4 incident. `free_image()` now refuses to delete
  when connections cannot be listed.
- The last unbounded waits are gone: the intermediate child in `status()` and
  the success path of `sysfs_read_with_timeout()` reap with `WNOHANG` on a
  bounded poll.
- `_run_cmd()` and `sysfs_read_with_timeout()` save and restore any alarm the
  caller had armed instead of clearing it with a bare `alarm(0)`.

### LOW

- `postinst` adds `fuser` to its required-binary check. It is the load-bearing
  check for a running guest, and `psmisc` is already a hard dependency.

---

## [1.1.22] - 2026-07-26

Host-side stability release. Removes a standing SAN-rescan load that Proxmox VE
triggered on every status poll, fixes an unkillable hang inside the command
timeout handler, reworks device discovery, and corrects Pure REST 2.x timestamp
handling. Addresses issue #13 and clarifies the pod capacity reporting behind
issue #10.

### CRITICAL — No more full SAN rescan on every pvestatd poll

Proxmox VE calls `activate_storage()` from `PVE::Storage::storage_info()` on
every pvestatd poll (~10s), sequentially for every configured storage.
`activate_storage()` unconditionally performed, on each of those calls:

- an iSCSI session rescan (up to 10s per `LOGGED_IN` session),
- a SCSI host scan across every iSCSI host,
- a host-wide `multipathd reconfigure`, which rebuilds **every** multipath map
  on the node, and
- `udevadm trigger --subsystem-match=block` followed by `udevadm settle`, which
  re-triggers **every** block device on the system.

That is a full multipath rebuild and a system-wide udev re-trigger six times a
minute, on every node, per Pure storage. Beyond the standing cost — it runs in
series ahead of every other storage's status poll — it competed directly with
device discovery: a VM start or a backup waiting for a newly mapped LUN was
racing a reconfigure that repeatedly tore the map table down and rebuilt it.

Rescans now run **immediately** whenever this node logs in to a new iSCSI
portal, and otherwise at most once per `pure-rescan-interval` (new option,
default 300s; set to 0 to restore the previous behaviour). Discovery of new
LUNs does not depend on this periodic rescan — `activate_volume()`, `path()`
and `alloc_image()` each run their own targeted rescan and wait for the WWID
they need. What remains here is a safety net for LUNs mapped out-of-band.

`multipathd reconfigure` is additionally rate-limited process-wide to at most
once per 30 seconds on all discovery and polling paths, so concurrent callers
cannot turn it back into a reconfigure storm. Genuine configuration changes
(writing `/etc/multipath/conf.d/pure-storage.conf`) still reload immediately.

### HIGH — Unkillable hang inside the command timeout handler

The `_run_cmd` timeout handler in `Multipath.pm` and `ISCSI.pm` ran
`kill('TERM', $pid)` followed by a **blocking** `waitpid($pid, 0)`. A child in
uninterruptible sleep — precisely the case these timeouts exist to survive —
cannot be killed by `TERM` or `KILL`, so the blocking `waitpid` never returned,
and the alarm that would have broken us out had already fired and been cleared.
The timeout handler itself became the hang.

It now escalates `TERM` to `KILL` and reaps only with `WNOHANG` on a bounded
poll, leaving an unreapable child to init rather than joining it in D state —
the same pattern `sysfs_write_with_timeout()` has always used.

### HIGH — Device discovery wait loop reworked (issue #13)

`wait_for_multipath_device()` probed for the device only at the **end** of a
loop body that could consume the entire timeout budget on a degraded fabric
(per-session iSCSI rescan, per-host SCSI scan, `multipathd reconfigure`, `udevadm
trigger`, `udevadm settle`). With a 60s budget and a 45s pass, the caller got a
single look at the device — taken at the worst possible moment, immediately
after a host-wide reconfigure churned the map table. A LUN that surfaced two
seconds later was reported missing. It also never probed *before* rescanning,
so the common case (the device is already present) paid the full cost anyway.

The loop is now an escalation ladder: probe first, then transport rescan, then
SCSI host scan, then udev, and only from the second round a throttled
reconfigure — with a cheap probe after every step and a ~1s poll between steps,
deadline-aware at every stage. `activate_volume()` likewise checks for an
existing device before doing any rescan work.

### HIGH — Orphaned temp-clone cleanup removed from `activate_storage`

That cleanup disconnects and destroys volumes on the array. Mutating,
potentially slow array work does not belong on a path Proxmox VE polls every
~10s with the short-timeout health client. `status()` already forks it into the
background reaper, under a lock, with the resilient client.

### HIGH — Actionable diagnostics when a device does not appear

The "device did not appear" error now reports the host state **captured at
failure time**, rather than leaving an operator to reproduce it:

- what `multipathd` currently sees (total maps, Pure maps, whether a map exists
  for this WWID, and whether its `/dev/mapper` node was actually created),
- other Pure WWIDs multipathd does see, when ours is absent,
- matching `/dev/disk/by-id` symlinks,
- per-session iSCSI state read straight from sysfs, with an explicit note when
  sessions are not `LOGGED_IN` — LUN rescan is only issued on `LOGGED_IN`
  sessions, so a LUN reachable only through a failed path cannot be discovered
  until it recovers,
- for FC, the count of online target ports.

### MEDIUM — Pure REST 2.x timestamps are milliseconds

REST 2.x returns timestamps as milliseconds since the epoch; REST 1.x returns an
ISO 8601 string. The code assumed the opposite. Two consequences:

- Snapshot `ctime` handed to Proxmox VE was a millisecond value read as seconds,
  placing snapshot dates roughly 53,000 years in the future in the Web UI.
- The orphaned temp-clone reaper's "older than one hour" test could never be
  true on a 2.x array, so orphaned temporary snapshot clones were never cleaned
  up. Each one holds a volume slot, a host connection on every cluster node, and
  a stale multipath device.

Both now go through a single `pure_time_to_epoch()` helper that handles both
forms.

### MEDIUM — Host lookup for the connect-to-all-nodes step

API 2.x does not accept wildcards in the `names` query parameter, so
`host_list("pve-<cluster>-*")` always returned empty and new volumes were
pre-connected to the local node only. Live migration still worked — the target
node connects the volume itself during `activate_volume()` — but the
pre-connect that exists to make migration seamless never happened, and the
"not connected to hosts: ..." warning could never fire. Wildcards now go through
the `filter` parameter, as `volume_list` already did.

### MEDIUM — Pod capacity reporting (issue #10)

For a pod-backed storage the plugin reports `total` = the pod's `quota_limit`
and `used` = a pod space figure. Because Pure volumes are thin, a pod holding
one 32 GiB volume reports 32 GiB provisioned with almost nothing written, so a
3 GiB quota set afterwards reads as 100% full immediately — while writing into
the existing volume keeps working. Both halves are correct: the array **will**
refuse the next volume create or grow in the pod, and it will **not** refuse
writes to volumes that already exist. Nothing in the numbers said so.

- `used` is now clamped to the quota, so Proxmox VE is never handed
  `used > total` (which rendered as a >100% bar).
- A pod at or over its quota logs an explanation once per hour, including the
  raw `space` figures the array returned and, for a stretched pod, the number of
  member arrays — several Pure pod space figures are reported per array replica.
- New option `pure-pod-usage-metric` selects which figure is reported:
  `provisioned` (default; predicts allocation failures), `virtual`
  (host-written logical bytes; matches the intuitive "how full is it" reading
  but does not predict allocation failures), or `physical` (post-reduction
  bytes on the array).

### MEDIUM — N+1 REST lookup removed from `deactivate_storage`

The per-volume `volume_get_wwid()` call is replaced by deriving the WWID from
the serial the volume list already returned. The old form was an N+1 storm
against the array's management gateway, fired exactly when a node is shutting
down or a storage is being disabled cluster-wide.

### MEDIUM — API client cache key

The cache keyed on `$scfg->{storage}`, which Proxmox VE never populates, so it
degraded to the portal address alone. Two storages pointing at the same array
with different API tokens — or different `pure-status-timeout` values — shared a
single cached client, and whichever built it first won for the whole 300s TTL.
The key now covers portal, credentials, SSL setting, health-path flag and
timeout.

### LOW — Other fixes

- `filesystem_path()` passed `$scfg->{storage}` as the storage id, which is
  always `undef`, so every call died with a bare "storage is required" from
  inside the naming module. It now fails with an actionable message. No Proxmox
  VE path reaches it for this plugin today.
- Removed the argument-less `multipath_flush()` call in `deactivate_storage`,
  which could only ever throw — the helper deliberately refuses to run
  `multipath -F`, which would flush every unused map on the host.
- `activate_volume()` now tracks the volume WWID, closing a gap where a volume
  activated without `path()` being called was invisible to the cluster
  residual-device cleanup.
- postinst no longer reports another vendor's multipath settings as a Pure
  hazard. The dangerous-settings check grepped the whole of
  `/etc/multipath.conf` with no scope awareness, so `no_path_retry queue`
  inside a `device { vendor "NETAPP" }` block — which cannot affect Pure
  devices, and is that vendor's own recommendation — was reported as a Pure
  risk. The check now tracks scope and only warns for settings in `defaults`
  or in a PURE device block; settings scoped to another vendor are reported
  as a note for awareness.
- `get_managed_capacity()` falls back to `GET /pods/space` when a Purity release
  omits `space` from `GET /pods`.

---

## [1.1.21] - 2026-06-16

Management-plane load and pvestatd-isolation release. Reduces the steady-state
REST load the plugin places on the FlashArray management gateway and prevents a
single slow or degraded array from starving sibling storages on the same node.
Ported from sibling-pattern fixes in the related NetApp plugin.

### HIGH — Isolate the pvestatd health path from a slow array

`activate_storage()` and the foreground of `status()` now use a short-timeout,
single-attempt REST client instead of the resilient data-path client (15s x 2
retries, ~34s worst case). PVE processes storages sequentially every ~10s, so a
slow or degraded array previously backed up the whole pvestatd cycle and starved
sibling storages on the same node into `inactive`. New option
`pure-status-timeout` (default 5s, range 2-60). Dropping per-call retries on
this path costs nothing — the next poll is the retry. The data path
(alloc/free/clone) and the background orphan reaper keep the resilient client.
On a heavily-loaded-but-healthy array, status may briefly show `inactive` and
recover on the next poll; running VMs are unaffected (devices stay mapped).

### HIGH — HTTP keep-alive on the REST client

The `LWP::UserAgent` now reuses one TCP+TLS connection across calls
(`keep_alive => 1`) instead of opening a fresh connection and full TLS handshake
per request. Under steady pvestatd polling (every ~10s on every cluster node,
plus the background reaper) this materially reduces the connection churn the
array's management gateway must absorb. A stale kept-alive socket after a
controller failover fails one request and LWP transparently reconnects, bounded
by the (short, on the health path) timeout.

### MEDIUM — Bounded iSCSI activate discover/login loop

The per-portal timeouts (probe 2s, discovery 30s, login 60s) bound each portal
but not the loop total, so several reachable-but-hanging LIFs could still stall
pvestatd. New option `pure-activate-deadline` (default 30s, 0 disables): once the
budget is spent **and** at least one portal is logged in, the remaining portals
are deferred to a later activation. The budget never applies while zero paths are
up (the storage must get at least one path or fail honestly) and never interrupts
an in-progress login, so a slow-but-reachable storage is never marked inactive.
The iSCSI session list is now snapshotted once before the loop instead of being
queried per portal.

### LOW — Remove per-volume REST call from the temp-clone reaper

`_cleanup_orphaned_temp_clones()` (which runs from the `status()` background
reaper on every poll) now computes each temp clone's WWID locally via
`serial_to_wwid()` from the serial already present in the `volume_list()`
response, instead of issuing a per-volume `volume_get_wwid()` REST call. This
matches the optimisation the orphan reaper already uses.

### LOW — postinst upgrade warning to restart pvestatd

After an upgrade, postinst now prints a prominent warning that the operator must
run `systemctl restart pvestatd` on **every** cluster node to activate the new
plugin code. The package intentionally uses `systemctl reload` (SIGHUP) to avoid
the stop-phase hang on D-state children, but on many PVE versions reload does not
reload Perl modules, so pvestatd can keep running stale code. The warning shows
how to verify the `MainPID` changed.

---

## [1.1.20] - 2026-05-29

Proxmox VE 9.2 compatibility release.

### MEDIUM — Override `get_identity()` for PVE 9.2

PVE 9.2 added `get_identity()` to the base `PVE::Storage::Plugin`, whose
default implementation `die`s with "get_identity not implemented for this
plugin". It is invoked via the new
`GET /nodes/<node>/storage/<storage>/identity` endpoint (primarily for
Proxmox Backup Server instance matching; the Web UI may poll it for any
storage), so on PVE 9.2 the base `die` would surface as a Web UI error.
The plugin now overrides it to return a deterministic
`purestorage:<portal>:<pod>` — the management portal plus the optional
ActiveCluster pod, which together pin the storage to one array. Signature
verified against the pve-storage source (`my ($class, $scfg, $storeid)`).
No `APIVERSION` change is required: the plugin still claims 13, within PVE
9.2's accepted 9..14 range.

---

## [1.1.19] - 2026-05-29

Scale and orphan-reaper safety release. Addresses behaviour on storages
with large volume counts (>1000) and hardens the background orphan
cleanup against reaping live LUNs, with several monitoring additions
carried over from the sibling NetApp plugin.

### HIGH — Volume/snapshot listing no longer truncates past one page

`volume_list()`, `volume_list_destroyed()` and `snapshot_list()` now
follow the API 2.x `continuation_token` across all pages. Pure FlashArray
REST 2.x caps each collection GET at a server page (default ~1000 items)
and signals further pages via `more_items_remaining` + `continuation_token`.
The previous code read only the first page, so a storage with more than one
page of volumes or snapshots silently truncated: `list_images()` hid disks
from the Proxmox VE web UI, and the orphan reaper never saw the tail
volumes (which then risked being mis-classified as residual). API 1.x is
unaffected. A new `API::_get_v2_collection()` helper walks all pages.

### HIGH — Orphan reaper hardening (never reap a live LUN)

- **Per-poll API load removed.** `_cleanup_orphaned_devices()` Phase 1 now
  derives each WWID from the `serial` already present in the `volume_list()`
  response instead of issuing one extra `volume_get_wwid()` REST call per
  volume on every `pvestatd` poll (~10s). On large storages this removes a
  per-poll burst of N REST calls that scaled with volume count and could hit
  the array's API rate limit.
- **Background cleanup serialised.** A non-blocking `flock` per storeid stops
  overlapping cleanup passes from stacking when a single pass exceeds the
  10s poll interval on a large array.
- **Grace period + absence hysteresis.** A WWID first seen less than 600s ago
  is never reaped (protects a just-added LUN before qemu opens it, when the
  in-use check legitimately reports idle), and a WWID must be absent from the
  array for 3 consecutive passes before teardown. This absorbs a single
  transient/incomplete array response. Cross-project hardening from a NetApp
  reaper incident where a freshly-added, in-use LUN was reaped.
- **Cross-storage false positive fixed.** With more than one purestorage
  storage on a host (multiple pods or arrays), Phase 3 used to warn about a
  sibling storage's live device as a stale orphan and recommend
  `multipath -f` on it. Phase 3 now skips WWIDs tracked by any other
  purestorage storage on the node. (Parity with NetApp v0.2.15.)

### MEDIUM — Monitoring additions (NetApp v0.2.10 / v0.2.11 parity)

- **Outage detection:** `status()` logs an ERROR after 3 consecutive failed
  polls (re-emitted at most every 30s while down) and an INFO on recovery,
  tagged `pure-storage:` in the journal for monitoring pickup.
- **Capacity health:** warns at >=90% (WARNING) and >=95% (ERROR) used, once
  per hour.
- **Controller redundancy:** `activate_storage()` warns once per 24h when all
  reachable iSCSI portals resolve to a single Pure controller (no
  controller-level path redundancy).
- **postinst in-flight grace:** detects running `qmrestore`/`vzdump`/`qm
  move-disk`/`clone`/`migrate`/`pvesm` operations and prints a NOTICE with a
  5s grace window before the (graceful SIGHUP) service reload.

---

## [1.1.18] - 2026-05-14

### MEDIUM — Snapshot pre-rename tombstone (mirrors v1.1.15's volume-side fix)

Tracked in [#11]. Pure's destroyed-pending state reserves a snapshot's
suffix for the array's eradication delay (default 24h). Without a
rename before destroy, recreating a snapshot with the same name
within that window fails:

```
TASK ERROR: Snapshot 't1' already exists for volume 'vm-101-disk-0'
```

Common PVE workflows that create-then-delete-then-recreate the same
snapshot (e.g., naming a periodic snapshot "daily", "weekly") were
forced to wait or manually `purevol eradicate` from Pure UI.

#### Fixed
- **`snapshot_delete()` pre-renames the snapshot to
  `<orig-suffix>-pve-tomb-<unix-ts>-<pid>` before destroy**, so
  the original suffix is freed immediately. The tombstoned
  snapshot still goes into destroyed-pending under the new
  suffix and eradicates per the array's normal schedule.
- Uses Pure's `PATCH /volume-snapshots` rename API — verified
  against the FA 2.x OpenAPI spec: the body `name` field is the
  **new suffix only** (not the full name), with the source volume
  association preserved.
- Edge cases handled: 64-char suffix-length overflow falls back
  to direct destroy + warning; already-tombstoned suffixes are
  not re-renamed (idempotent retry on a previously-failed
  destroy); rollback rename on destroy failure restores the
  original suffix for a clean PVE-side retry.
- API 1.x lacks snapshot rename in the REST surface, so the
  tombstone path is API 2.x only. 1.x callers destroy straight
  through under the original name (pre-1.1.18 behaviour).

### LOW — Separate timeout for the config-backup volume's device wait

Tracked in [#12]. The plugin creates a 1 MB auxiliary volume on each
snapshot to archive the VM/CT config (used only by
`pve-pure-config-get` for disaster recovery — non-critical). Previously
this volume's multipath-device wait used `pure-device-timeout`
(default 60s). On degraded multipath, every snapshot operation would
visibly stall for the full timeout even though the
"Config backup device not found, skipping config backup" warning is
non-fatal.

#### Fixed
- **New storage option `pure-config-backup-timeout`** (integer
  `5..60`, default `15`). Sets a separate, shorter wait specifically
  for the auxiliary config-backup volume. Snapshot operations
  return ~15s after a degraded-fabric stall instead of ~60s.
- Warning text expanded to spell out that the skip is non-fatal,
  identify the WWID, and point at the new option for operators
  whose fabric is consistently slow.

### LOW — postinst sanity-checks for required binaries

Tracked in [#9]. The plugin's declared Depends
(`multipath-tools`, `open-iscsi`, `sg3-utils`, `psmisc`) are correct,
but `dpkg -i ...` does not enforce them — the package can land on a
system that lacks `multipathd` / `iscsiadm` / `kpartx`, and the
first storage operation fails with an internal-looking
`open3: exec of /sbin/multipathd reconfigure failed: No such file
or directory`.

#### Fixed
- **postinst now refuses to complete `configure` when required
  binaries are missing.** Detected binaries: `multipathd`,
  `multipath`, `kpartx`, `iscsiadm`, `sg_inq`, `blockdev`. The
  package goes into configured-failed state with a clear
  multi-line error directing the operator at
  `apt --fix-broken install` (recover from a `dpkg -i`) or
  `apt install ./*.deb` (install correctly from scratch).
- **README + README_zh-TW Installation section** now lead with
  `apt install ./*.deb` and carry an explicit warning against
  bare `dpkg -i` for first-time installs.

[#9]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/9
[#11]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/11
[#12]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/12

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
