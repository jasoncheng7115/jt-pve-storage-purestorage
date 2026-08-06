Naming release. Two ways a name that looks unique to Proxmox VE stops being unique on the array.

---

## HIGH — Two storages could own the same Pure volumes

Volume names are built from the storage id, with characters Pure will not take removed and `-` mapped to `_`. That transform is not one-to-one:

| Storage id | Pure prefix | Volume for VM 100, disk 0 |
|---|---|---|
| `pure-prod` | `pure_prod` | `pve-pure_prod-100-disk0` |
| `pure_prod` | `pure_prod` | `pve-pure_prod-100-disk0` |
| `pure-p.rod` | `pure_prod` | `pve-pure_prod-100-disk0` |

All three are valid, distinct Proxmox VE storage ids. `pure-prod` next to `pure_prod` is an ordinary naming accident, not a contrived case.

That prefix is the **only** thing that scopes ownership. Eight call sites ask the array for `pve-<prefix>-*` and treat every answer as their own — `list_images()`, the orphan reaper, the temp-clone reaper and the config-volume cleanup among them. Two colliding storages on one array therefore shared a single namespace:

- each listed the other's disks as its own, so `qm rescan` on one could attach a volume belonging to the other;
- deleting a volume through one could destroy a volume the other's guests were running on.

Adding a storage that would collide is now refused, with a message naming the existing storage and the prefix they share. The check is scoped to the same array and pod, since a different array or pod is a different namespace.

**Updating a storage only warns.** An operator who already has a colliding pair has to stay able to run `pvesm set` on it — including to set credentials — so refusing there would lock them out of the commands that fix the problem.

Making the transform one-to-one was considered and rejected: it would change the name of every volume that already exists.

> **If you already have a colliding pair**, `pvesm set` on either one now prints the warning naming both. The volumes are intermingled on the array under one prefix; separating them means creating a storage with a non-colliding id and moving disks to it, which is a normal storage migration.

---

## MEDIUM — Long node names share one Pure host object

Node names are truncated to 20 characters for the array, so:

```
virtualization-node-01  ->  pve-pve-virtualization-node-
virtualization-node-02  ->  pve-pve-virtualization-node-
```

The first node to activate the storage creates the host object; the second finds it already there and adds its own initiator to it. Both nodes then *are* that host as far as the array is concerned.

Everything that reasons per node is then wrong. Disconnecting a volume on one node removes it from the other. More seriously, the temp-clone reaper decides ownership by asking whether a clone is connected to a host other than this node's — the check that exists to stop one node tearing down a clone another node is actively reading from during a backup. With one shared host object, that check cannot distinguish them.

The plugin now detects this and warns once an hour, naming the other node.

**It does not rename anything.** The existing volume connections hang off the current host name, and the initiator would come back from the array as "already in use by another host", so a rename is a maintenance operation with a migration behind it — not something an upgrade should do while guests are running. Fixing it means giving the nodes names that differ within their first 20 characters.

`pure-host-mode = shared` is excluded from the check, since one shared host object is the point of that mode.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.31-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
