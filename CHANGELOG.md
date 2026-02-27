# Changelog

All notable changes to this project will be documented in this file.

## [1.0.49-1] - 2026-02-27

### Second-Round Audit Release - Reliability & Correctness Fixes

**Data Integrity Fixes:**
- Fixed `volume_snapshot_list` double-encoding `pve-snap-` prefix, which caused `snapshot_delete` to fail on re-encoded names
- Fixed `list_images` passing pod-prefixed name to `pure_to_pve_volname`, causing decode failure for cloudinit/state volumes in pod setups
- Fixed `parse_volname` returning undef instead of die (violates PVE storage plugin API contract, causes silent failures)
- Fixed `alloc_image` orphan cleanup missing `skip_eradicate`, which could permanently eradicate volumes on allocation retry

**Security Fixes:**
- Fixed `pve-pure-config-get` umount calls to use list-form `system()` to prevent shell injection
- Fixed `pve-pure-config-get` LXC detection operator precedence that misidentified QEMU VMs with `arch:` line as LXC containers

**Reliability Improvements:**
- Fixed `_backup_vm_config` missing `cleanup_lun_devices` on error paths, leaving stale SCSI devices after failed backup
- Fixed API cache fork-safety with PID check to prevent stale session tokens in forked PVE daemon workers
- Fixed `deactivate_storage` to check `is_device_in_use` before disconnect, preventing cleanup of volumes still in use by other VMs
- Fixed `pve-pure-config-get` restore mode cleanup on config write error (umount and disconnect now always run)
- Replaced ad-hoc `multipathd reconfigure` shell calls with `multipath_reload()` for consistency

**Code Quality:**
- Fixed `SG_INVERT` typo to `SG_INQ` in Multipath.pm
- Fixed config volume name length check in `encode_config_volume_name` to truncate snapname when total exceeds 63 chars
- Moved `IO::Select` imports to file-level in ISCSI.pm and Multipath.pm
- Removed dead code in `pve-pure-config-get` restore mode

## [1.0.48-1] - 2026-02-27

### Safety Audit Release - Security & Reliability Fixes

**Critical Security Fixes:**
- Fixed `path()` returning `/dev/null` or synthetic path on API failure, now properly dies to prevent silent data corruption
- Fixed shell injection in `is_device_in_use` fuser call and `_backup_vm_config` system calls (use list-form)

**Data Integrity Fixes:**
- Fixed `get_multipath_device` using substring WWID match that could return wrong device, now uses exact match only
- Fixed `get_device_by_wwid` glob patterns to use exact suffix match instead of substring to prevent device collision
- Fixed ISCSI `_find_multipath_device` and `wait_for_device` to use exact serial suffix matching instead of substring
- Fixed `clone_image` disk ID allocation race by using `_find_free_diskid` instead of manual max+1 logic
- Fixed `_find_free_diskid` to strip pod prefix before `decode_volume_name`
- Fixed `alloc_image` and `clone_image` cleanup to use `skip_eradicate` and preserve original error message (`$@` clobbering)

**Reliability Improvements:**
- Fixed `_cleanup_orphaned_temp_clones` ISO 8601 timestamp parsing for API 2.x (was comparing string to epoch, never cleaning up)
- Fixed `_run_cmd` in ISCSI.pm and Multipath.pm to use `IO::Select` for simultaneous stdout/stderr reading (prevents deadlock)
- Fixed `_run_cmd` timeout to kill child process (prevents orphans)
- Fixed API `volume_get`/`snapshot_get`/`host_get` to distinguish 404 (not found) from transient errors instead of swallowing all
- Fixed API `host_add_initiator` null check on `host_get` result
- Fixed API `_request` to not retry non-idempotent POST on 5xx
- Fixed API `_request` JSON parse error handling on 200 response
- Fixed `_backup_vm_config` mount cleanup on error path
- Added in-use guard to `cleanup_lun_devices` to prevent cleaning devices that are still mounted or held open

**Other Fixes:**
- Fixed `pve-pure-config-get` restore mode: boolean logic was always dying in restore mode
- Fixed `pve-pure-config-get` `san_storage` to use `sanitize_for_pure`

## [1.0.47-1] - 2026-02-12

### Fibre Channel SAN Fix Release

**Critical Bug Fixes:**
- Fixed API 2.x `host_add_initiator`: merge new WWN with existing initiators instead of replacing all (was clobbering existing WWNs)
- Fixed API 2.x `host_remove_initiator`: remove only targeted initiator instead of clearing all (was removing all initiators)

**FC SAN Improvements:**
- Fixed `_backup_vm_config`: pass protocol-specific rescan callbacks (`fc_rescan`/`iscsi_rescan`) to `wait_for_multipath_device`
- Fixed `activate_storage`: add FC fabric connectivity verification with warning when no FC target ports detected
- Fixed `volume_snapshot_rollback`: wrap FC/iSCSI rescan calls in eval to prevent rescan failures from aborting rollback
- Fixed `alloc_image`: add FC diagnostic info (online HBA ports, visible targets) in device discovery error messages
- Fixed `deactivate_storage`: add FC-specific logging with volume count
- Fixed `rescan_fc_hosts`: only scan FC-related SCSI hosts (not all), add error handling on LIP issue
- Fixed `get_fc_wwpns_raw`: read directly from sysfs without double format-then-parse conversion
- Fixed `host_create`: add `uri_escape` for host name in API 2.x
- Added `get_fc_targets` to FC.pm exports and plugin imports
- Added missing `multipath_flush` import in plugin

## [1.0.46-1] - 2026-01-26

### Disaster Recovery Feature Release

**New Features:**
- New `-r`/`--restore` option for `pve-pure-config-get` for full VM restore
- Search and display destroyed volumes in restore mode
- Automatically recover destroyed config and disk volumes
- Place config file in correct PVE location (`/etc/pve/qemu-server` or `lxc`)
- Connect recovered disk volumes to host
- Safety check: refuses to overwrite existing VM config

**New API Methods:**
- `volume_list_destroyed()`: list destroyed volumes
- `volume_recover()`: recover destroyed volumes

## [1.0.45-1] - 2026-01-26

- `pve-pure-config-get`: remove config content display, add restore hint

## [1.0.44-1] - 2026-01-26

- Improve `pve-pure-config-get` list output formatting with dynamic column widths

## [1.0.43-1] - 2026-01-26

- Add `-n`/`--snap` option to `pve-pure-config-get` for directly specifying which snapshot's config to retrieve (skip interactive selection)

## [1.0.42-1] - 2026-01-26

- Fix `pve-pure-config-get`: include pod prefix in search pattern when pod is configured, and fix `volume_list` API call to use positional parameter

## [1.0.41-1] - 2026-01-26

- Fix `pve-pure-config-get`: handle "volume does not exist" as empty result when no config backups found for VM
- Suppress "Filesystem too small for a journal" warning in config backup by explicitly disabling journal for small 1MB volumes

## [1.0.39-1] - 2026-01-26

- Fix `pve-pure-config-get`: use correct `host` parameter for API connection

## [1.0.38-1] - 2026-01-26

- Fix VM config backup: use correct `multipath_reload()` function name

## [1.0.37-1] - 2026-01-26

### VM Config Backup Feature Release

**New Features:**
- Automatically backup VM config file to Pure Storage when creating snapshots
- Each snapshot gets its own independent config backup volume
- Config stored in ext4-formatted 1MB volume with metadata
- Config volume naming: `pve-{storage}-{vmid}-vmconf-{snapname}`
- Config volumes automatically cleaned up when snapshot or VM is deleted
- Config volumes hidden from PVE disk listing

**New Tool:**
- `pve-pure-config-get`: command-line tool to retrieve VM config backups
- Lists available config backups for a VM
- Interactive selection and retrieval
- Automatically handles volume connection, mounting, and cleanup

## [1.0.36-1] - 2026-01-26

### Soft Delete Release

- `free_image` now only destroys volumes, does NOT eradicate
- `volume_snapshot_delete` now only destroys snapshots, does NOT eradicate
- Deleted volumes/snapshots go to Pure Storage "Destroyed" state
- Allows recovery from Pure Storage UI if needed
- Pure Storage auto-eradicates based on eradication delay setting (default 24h)
- Cleanup operations (error recovery, temp clones) still eradicate immediately

## [1.0.35-1] - 2026-01-25

### Linked Clone Naming Fix

- `clone_image` now returns `base-X-disk-N/vm-Y-disk-M` for template clones
- Added `parse_volname` support for linked clone format
- Added `pve_volname_to_pure` support for linked clone format
- `parse_volname` now returns proper `basename`/`basevmid` for linked clones
- Fixes linked clone not showing parent relationship in PVE

## [1.0.34-1] - 2026-01-25

### Documentation - PVE Full Clone Architecture

- Document PVE Full Clone architecture limitation
- PVE GUI "Full Clone" always uses alloc + data copy (PVE design), does NOT call `clone_image`
- Workaround: use "Linked Clone" for instant cloning via Pure Storage

## [1.0.33-1] - 2026-01-24

- Fix slow `list_images` when no templates exist (was falling back to individual API calls for each volume)

## [1.0.32-1] - 2026-01-24

- Add `clone_image` support for direct volume clone (not just snapshots)

## [1.0.31-1] - 2026-01-24

- Optimize pod prefix queries: use `pod.name` filter to limit results, significantly improves list/status speed for pod-based storage

## [1.0.30-1] - 2026-01-24

- Fix `volume_list` API call: use `destroyed=false` as query parameter, use `filter=name='pattern*'` for wildcard patterns

## [1.0.29-1] - 2026-01-24

- Fix API filter syntax for destroyed volumes: change "not destroyed" to `destroyed=false`

## [1.0.28-1] - 2026-01-24

- Fix API filter syntax error with `pod::` prefix: handle `pod::pattern*` with Perl-side filtering in `volume_list` and `snapshot_list`
- Fix missing pod prefix in volume pattern queries for `_find_free_diskid`, `_cleanup_orphaned_temp_clones`, and `list_images` template query

## [1.0.27-1] - 2026-01-24

- Comprehensive udev trigger fix for all device operations: `activate_storage`, `path`, `volume_resize`, `volume_snapshot_rollback`

## [1.0.26-1] - 2026-01-24

### Device Discovery Fix Release

- Add udev trigger to `wait_for_multipath_device`
- Add protocol-specific rescan callbacks (iSCSI/FC) to wait loop
- Update `activate_volume` and `path` function with proper rescan
- Fixes CT creation, VM clone, and other operations that use `activate_volume`

## [1.0.25-1] - 2026-01-24

### Storage Deactivation Release

- Cleanup local multipath and SCSI devices for storage volumes on `deactivate_storage`
- Disconnect volumes from Pure Storage host
- Logout iSCSI sessions if no more volumes connected
- Flush unused multipath maps
- Add `host_get_volumes` API function

## [1.0.24-1] - 2026-01-24

- Fix `list_images` showing destroyed volumes: add `not destroyed` filter to `volume_list` API call

## [1.0.23-1] - 2026-01-24

- Fix udev WWID cache issue: add `udevadm trigger` after SCSI rescan to refresh stale WWIDs

## [1.0.22-1] - 2026-01-24

### Automatic Multipath Configuration

- Auto-detect and create multipath config if missing
- Use `/etc/multipath/conf.d/` if available (non-invasive)
- Safely append to existing `/etc/multipath.conf` if needed
- Only adds Pure Storage device section, preserves other configs

## [1.0.21-1] - 2026-01-24

- Improve RAM snapshot device discovery diagnostics with verbose logging, session verification, and auto re-establish

## [1.0.20-1] - 2026-01-24

- Fix orphaned state/cloudinit volume cleanup: auto-detect and cleanup orphaned volumes from previous failed attempts

## [1.0.19-1] - 2026-01-24

- Fix RAM snapshot device discovery: add delay for Pure Storage propagation, include iSCSI/FC session rescan in wait loop

## [1.0.18-1] - 2026-01-24

- Fix RAM snapshot device discovery: add iSCSI/FC rescan after creating state/cloudinit volumes, wait for device before returning

## [1.0.17-1] - 2026-01-24

- Fix RAM snapshot (Include RAM) support: handle `vm-{vmid}-state-{snapname}` and `vm-{vmid}-cloudinit` volume types in `alloc_image`

## [1.0.16-1] - 2026-01-24

### Error Handling & Migration Release

**Error Handling Improvements:**
- Add existence checks for all snapshot operations
- Improve `volume_snapshot_delete` with dependency detection
- Add `volume_snapshot_rollback` validation and safety checks
- Improve `clone_image` with source validation and better error messages
- Add linked clone support validation (template vs snapshot)
- Improve `create_base` with in-use detection
- Add host/initiator conflict detection and helpful error messages
- Add detailed device discovery failure diagnostics
- Add capacity/quota error detection

**Migration Support:**
- Add `_connect_to_all_hosts()` helper for cluster-wide volume access
- Volumes now connected to all cluster hosts on creation
- Support container (CT) storage with `rootdir` content type

## [1.0.15-1] - 2026-01-24

### FC WWN Format Fix

- Use raw WWN format (no colons) for Pure Storage API compatibility
- Add `normalize_wwn()` for format-agnostic WWN comparison
- Add `get_fc_wwpns_raw()` for API-compatible WWPN retrieval
- Handle API 2.x `wwns`/`iqns` and API 1.x `wwnlist`/`iqnlist` formats

## [1.0.14-1] - 2026-01-23

- Fix snapshot suffix: replace underscore and dot with dash (Pure Storage snapshot suffix only allows alphanumeric and `-`)

## [1.0.12-1] - 2026-01-23

- Fix pod prefix missing in all volume operations: `deactivate_volume`, `path`, `volume_snapshot`, `volume_snapshot_delete`, `volume_snapshot_rollback`, `volume_snapshot_list`, `create_base`, `rename_volume`, `clone_image`

## [1.0.11-1] - 2026-01-23

- Fix API 2.x volume size field: use `provisioned` instead of `size`
- Fix API 2.x used space: use `space.total_physical` instead of `volumes`

## [1.0.10-1] - 2026-01-23

- Fix API 2.x wildcard queries: use `filter` parameter instead of `names` for `volume_list` and `snapshot_list`

## [1.0.9-1] - 2026-01-23

### API 2.x Query String Fix

- Fix API 2.x: `names`/`source_names` must be in query string, not request body
- URL-encode `pod::volname` format (`::` becomes `%3A%3A`) in query strings
- Fix `volume_create`, `volume_clone`, `snapshot_create`, `volume_connect_host`, `volume_connect_hgroup`

## [1.0.8-1] - 2026-01-23

- Show pod quota limit as storage capacity when configured
- Add `pod_get` API function

## [1.0.7-1] - 2026-01-23

- Add `pure-pod` option for ActiveCluster configurations
- Support pod-prefixed volume names (`pod::volname` format)
- Fix volume creation when File service is enabled

## [1.0.6-1] - 2026-01-23

- Fix API 2.x host creation: use query parameter for names (`POST /hosts?names=hostname`)

## [1.0.5-1] - 2026-01-23

- Fix API 2.x endpoints: arrays, ports, network-interfaces
- Handle API 2.x response format with `{items: [...]}`
- Fix capacity reporting for API 2.x nested space object

## [1.0.4-1] - 2026-01-23

- Use API 2.x with `POST /login` endpoint for authentication
- Detect API version via `/api/api_version` endpoint
- Support API versions up to 2.42

## [1.0.3-1] - 2026-01-23

- Implement two-stage authentication: use `POST /auth/session` with api-token to get `x-auth-token`

## [1.0.2-1] - 2026-01-23

- Fix Content-Type header issue on GET requests causing 401 errors

## [1.0.1-1] - 2026-01-23

- Fix API version detection for Pure Storage arrays without API 2.x
- Improve 401 authentication error diagnostics
- Handle Pure Storage API returning HTTP 200 with error body

## [1.0.0-1] - 2026-01-13

### Initial Release

- Support for Pure Storage FlashArray via iSCSI and Fibre Channel
- Volume management: create, delete, resize
- Snapshot: create, delete, rollback
- Clone support via Pure Storage snapshots
- Template support
- Multipath I/O support
- Live migration support
