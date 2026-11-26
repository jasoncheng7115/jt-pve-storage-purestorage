**Proxmox VE 9.3 support.** No change in behaviour on earlier versions. If you run Proxmox VE 9.3, read the SAN view warning below before anyone uses that view.

---

## IMPORTANT — Proxmox VE 9.3 Node > SAN can wipe the disks of this plugin

Proxmox VE 9.3 adds a **Node > SAN** view that can wipe a LUN or create a volume group on it. Before it does, it checks whether the LUN belongs to a storage, but it only knows its own storage types: LVM volume groups, iSCSI targets, NVMe-oF subsystems and LVM base volumes. There is no interface for a third-party plugin to claim its LUNs. A LUN of this plugin therefore counts as in use only while a process on **that node** has it open for writing.

This plugin connects every disk to every cluster node, and keeps it connected while the guest is stopped so that it can start or migrate anywhere. As a result:

- the disk of a stopped guest shows as `unused` on every node;
- the disk of a running guest shows as `unused` on every node except the one it runs on.

Partitions do not stop the wipe: Proxmox VE removes the kpartx partition mappings and their signatures first.

**Do not run Wipe or Create VG on a LUN whose WWID starts with `3624a9370`.** The 24 hex digits after that prefix are the volume serial on the array, which identifies the volume. A wiped disk can only be recovered from an array snapshot.

The new cluster-wide multipath settings (`/etc/multipath/conf.d/pve-*.conf`) have two caveats for this plugin: an alias on a Pure WWID renames the map away from the `/dev/mapper/<wwid>` the plugin uses, and a `devices` section for `PURE` in the overrides replaces this plugin's device settings.

Both are in the README (Known Limitations) and TROUBLESHOOTING section 14.

## Storage API 17

Proxmox VE 9.3 ships `libpve-storage-perl` 9.1.26 with APIVER 17 / APIAGE 8. 1.1.38 loads there, but claims 15, so every `pvesm`, `qm` and `pct` call printed `implementing an older storage API`. `api()` now negotiates up to 17, and still claims exactly what each older library reports (15 on 9.1.6–9.1.8, 13 on 9.1.2).

What versions 16 and 17 changed, and why neither needs code here:

| Version | Change | This plugin |
|---|---|---|
| 16 | `volname_for_format()`, `get_parsed_format()` and related methods, called by the base `alloc_image()` and `rename_volume()` | both are overridden without calling the base |
| 17 | volume types `vm-vol`, `vm-state`, `ct-vol` | `parse_volname()` keeps returning `images`, which Proxmox VE accepts wherever a guest volume type is expected |
| 17 | optional `isolate-properties` | not set; every property is listed in `options()`, which 9.3 now requires |

Verified by loading the plugin against the 9.3 libraries and running all 35 test suites there.

## The upgrade notice names all three services

postinst asked for a restart of `pvestatd` only. `pvedaemon` and `pveproxy` run the plugin for every web interface and API request, including guest start, so they keep old code too. The README upgrade SOP now has the same step.

---

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvedaemon pvestatd pveproxy
systemctl show -p MainPID pvedaemon pvestatd pveproxy   # the PIDs must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
