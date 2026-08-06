Found while smoke-testing v1.1.28 on a node whose `libpve-storage-perl` had moved on. No functional change to the data path.

---

## The storage API version is now negotiated, not hardcoded

`pvesm status` was printing this on every call:

```
Plugin "PVE::Storage::Custom::PureStoragePlugin" is implementing an older
storage API, an upgrade is recommended
```

`APIVER` and `APIAGE` live in **`libpve-storage-perl`, which versions independently of `pve-manager`**, and they moved 13 → 14 → 15 within the 9.1 point releases. Proxmox VE treats the two directions very differently:

| What the plugin claims | What happens |
|---|---|
| `> APIVER` | **hard reject** — the plugin never loads and every `purestorage` storage disappears from the node |
| `< APIVER - APIAGE` | hard reject, same outcome |
| in range but `!= APIVER` | loads, and Proxmox VE warns on **every** load of `PVE::Storage` — once per `pvesm`/`qm`/`pct` call, once per daemon start |
| `== APIVER` | loads silently |

So no fixed number is right on every node. Claiming 13 was safe everywhere but noisy on any node with the current library; raising it to 15 would have silenced the warning and made older libraries refuse the plugin outright.

`api()` now returns `min(APIVER, 15)`, floored at 9, falling back to 13 when `PVE::Storage` is not loaded at all (`perl -c`, unit tests). Verified across every library version in the field plus the extremes.

**This is safe because `api()` is only a load-time gate.** Grepping the whole `/usr/share/perl5/PVE` tree confirms nothing branches on the returned value afterwards — Proxmox VE calls plugin methods with its own current signatures either way. The cap of 15 is what this plugin actually implements, and raising it stays gated on implementing that version's delta.

> `APIVERSION_MAX` is a maintenance obligation with a deadline, not a set-and-forget constant: when Proxmox VE's floor (`APIVER - APIAGE`) climbs above it, the plugin stops loading. Today's 15/6 gives a floor of 9, so there are six bumps of headroom.

---

## `volume_resize` no longer drops a snapshot name

API version 14 added a `$snapname` parameter to `volume_resize()`, for storages that keep snapshots as a chain of volumes and therefore have a resizable object per snapshot. This plugin accepted the parameter positionally and dropped it — which would have resized **the parent volume** when the caller meant a snapshot.

It is now refused with an explanatory message. Not reachable in practice: Proxmox VE only passes a snapshot name when `snapshot-as-volume-chain` is set on the storage, which this plugin does not offer. The base plugin refuses the same case for the same reason.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.29-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
