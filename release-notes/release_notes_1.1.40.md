**Proxmox VE 9.3: iSCSI disks of this plugin can now be protected from the Node > SAN Wipe.** Upgrade every node first, then set `target` on each iSCSI storage. Fibre Channel is not covered. Nothing changes on Proxmox VE 9.2 or earlier.

---

## iSCSI: set `target` to stop Node > SAN from wiping Pure LUNs

1.1.39 documented that the Proxmox VE 9.3 **Node > SAN** view offers this plugin's LUNs for **Wipe** and **Create VG**: on every node except the one running the guest, and on every node for a stopped guest.

Proxmox VE refuses both actions on a LUN whose iSCSI target matches a storage's `target`, for any storage type. 1.1.40 accepts that key. Set it to the array's iSCSI IQN:

```bash
iscsiadm -m session | awk '{print $4}' | sort -u   # the array's IQN
pvesm set <storage-id> --target <iqn>
```

Afterwards the SAN view refuses with `storage '<storage-id>' serves images from this target`.

- **The value must match exactly.** Proxmox VE compares the string and fails silently on a mismatch. The plugin therefore reads the array's IQN when `target` is set and warns if it differs. It also warns when the array does not answer, and when the storage uses FC.
- **Upgrade every node before setting it.** A node running 1.1.39 or older does not know `target`. It prints `unexpected property 'target'` on every command, and the next time that node writes `storage.cfg` it drops the key, which removes the protection on all nodes.
- **Fibre Channel is not covered.** Proxmox VE matches `target` against iSCSI sessions only. On FC, never run Wipe or Create VG on a LUN whose WWID starts with `3624a9370`.

On a Proxmox VE 9.3 node, the package upgrade lists every iSCSI Pure storage that still has no `target`.

## Proxmox VE 9.3 storage dialog

Proxmox VE 9.3 builds the add and edit storage dialog from the plugin's schema. In that dialog:

- every option now has a title;
- the storage type is named "Pure Storage FlashArray";
- the timeouts, rescan interval, host naming and pod reporting options are in the advanced section.

Earlier versions ignore all of this.

## Tests

New suite `t/sanclaim.pl`. It runs Proxmox VE's own `assert_lun_unreferenced()` against the plugin's configuration, both with and without `target`. It also checks the hook's IQN comparison and that `storage.cfg` keeps the key through a parse and write cycle.

---

## Action required after upgrade

1. On **every** cluster node:

   ```bash
   systemctl restart pvedaemon pvestatd pveproxy
   systemctl show -p MainPID pvedaemon pvestatd pveproxy   # the PIDs must change
   ```

2. Once every node runs 1.1.40, on any one node, for each iSCSI storage:

   ```bash
   pvesm set <storage-id> --target <iqn>
   ```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
