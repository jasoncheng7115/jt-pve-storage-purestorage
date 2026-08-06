Snapshot access was broken on any storage whose id is longer than ten characters. If your storage is named something like `purestorage` or `pure-prod-array1`, this affects you.

---

## HIGH — Snapshot access failed on most storage names

Reading from a snapshot creates a clone on the array. Its name is the volume name — itself derived from the storage id — plus a 36-character suffix:

```
pve-<storage>-<vmid>-disk<n>-temp-snap-access-<timestamp>-<pid>
```

Nothing checked the total against the 63 characters Pure allows, even though the plugin already applies that limit to ordinary volumes. And the array does not truncate an over-long name — it **rejects** it:

> Volume name must be between 1 and 63 characters (alphanumeric, `_` and `-`) in length and begin and end with a letter or number.

So this was not a latent risk. On an affected storage, every operation that reads from a snapshot failed:

- backing up a guest from a snapshot
- `qemu-img convert` out of a snapshot
- container backup in snapshot mode

and the array's error never mentions the storage id, which is the part that actually caused it.

The old suffix left room for a storage id of **ten characters**. `purestorage` is eleven — the most obvious name anyone would pick was already over the line:

| Storage id | Old clone name | Now |
|---|---|---|
| `pure1` | 58 | 45 |
| `purestorage` | **64** | 51 |
| `pure-prod-array1` | **69** | 56 |
| `pure-storage-cluster01` | **75** | 62 |

The marker is now `-tsa-` instead of `-temp-snap-access-`, which raises the workable storage id from 10 to **23** — one below the 24 the storage schema allows. The length is also asserted where the name is assembled, so if a name ever does go over, the error names the storage id as the cause instead of leaving you with the array's version.

Both reapers recognise the old marker as well and query both name patterns, so snapshot-access clones created before this release are still collected rather than leaking.

> **Nothing needs migrating.** The change affects only the short-lived clones created while something reads a snapshot; your disk volumes, snapshots and their names are untouched. If snapshot-based backups were failing, they will work after the upgrade with no further action.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.33-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
