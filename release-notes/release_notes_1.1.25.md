Credential-storage release. The array credentials no longer live in `/etc/pve/storage.cfg`. Also makes the plugin honour the volume name Proxmox VE asks for, which backup fleecing depends on.

---

## MEDIUM — The API token was stored in cleartext and returned by the config API

Proxmox VE 9 lets a plugin declare which of its properties are sensitive, through `plugindata()->{'sensitive-properties'}`. The storage-config API then pulls those keys out of the request before the config is written and hands them to `on_add_hook` / `on_update_hook` instead, so the plugin can put them somewhere protected.

This plugin never declared it. The list therefore fell back to Proxmox VE's hardcoded `encryption-key keyring master-pubkey password`, which covers neither `pure-api-token` nor `pure-password`. Both sat in `storage.cfg` in cleartext, and `GET /storage/<id>` returned them — an endpoint that needs `Datastore.Allocate` on that storage, **not root**. A Pure API token is normally array-wide, so that is full control of the FlashArray rather than of one storage.

Credentials now live in `/etc/pve/priv/storage/<id>.pure-token` and `<id>.pure-pw`, mode 0600, in a directory pmxcfs keeps root-only — the same place the built-in PBS and CIFS plugins keep theirs.

### Upgrading

**No action is required.** An existing storage keeps working unchanged: the plugin prefers the out-of-config secret and falls back to the value still in `storage.cfg`. A Proxmox VE storage update is a merge, so an unrelated `pvesm set` cannot drop the in-config token either.

**To complete the migration** and remove the cleartext copy, run once per storage:

```bash
pvesm set <storeid> --pure-api-token <token>
```

That writes the secret file **and** removes the old line from `storage.cfg`, in one command.

> Do **not** use `pvesm set <storeid> --delete pure-api-token` for this. Proxmox VE reports a deletion to the plugin as an explicit removal, so it deletes the secret file as well and leaves the storage with no credentials at all.

Verify afterwards with `pvesm status <storeid>` before moving on to the next storage.

---

## MEDIUM — The volume name Proxmox VE asks for is now honoured

Proxmox VE requests a specific name in four places:

| Caller | Name |
|---|---|
| `QemuConfig.pm` | `vm-<vmid>-state-<snap>` (RAM snapshot) |
| `API2/Qemu.pm`, `Cloudinit.pm` | `vm-<vmid>-cloudinit` |
| `VZDump/QemuServer.pm` | `vm-<vmid>-fleece-<n>` (backup fleecing) |
| `API2/Storage/Content.pm` | whatever the operator types to `pvesm alloc` |

Anything the plugin did not recognise fell through to the regular-disk branch, which **ignored the requested name** and allocated `vm-<vmid>-disk-<N>` instead. Backup fleecing images therefore came back looking like ordinary VM disks and consumed a disk id in the guest's numbering. Backups still worked, because Proxmox VE records and reuses whatever volid the plugin returns, so this had never surfaced.

Fleecing is now a first-class volume type — `pve-<storage>-<vmid>-fleece<n>` on the array, excluded from disk-id allocation — and an unrecognised explicit name is refused with a message naming the four supported forms instead of being silently substituted. `LVMPlugin` and `ZFSPoolPlugin` accept any `vm-<vmid>-<...>` for the same reason.

---

## Also

- `_get_api()` now requires the storeid, since that is how the credentials are located. All 21 call sites pass it, and a static check enforces it so a future call site cannot silently omit it and fall back to the legacy path.
- A storage with no resolvable credentials fails with a message naming the command to fix it, rather than a generic constructor error.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.25-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

The package uses `systemctl reload` to avoid the stop-phase hang on D-state children, but reload does not reload Perl modules on many Proxmox VE versions.

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
