Documentation release: the management address the plugin is pointed at determines whether a controller failover is transparent or takes the storage offline. **No behaviour change.**

---

## `pure-portal` must be the array's virtual management IP

A FlashArray is assigned three management addresses at setup: one per controller (`ct0.eth0`, `ct1.eth0`), plus a virtual IP (`vir0`) bound to whichever controller currently holds the management primary role. `pure-portal` must point at the virtual IP.

Pointed at a controller's own address, the plugin loses the REST API the moment that controller fails over: `activate_storage()` cannot reach the array and the storage goes `inactive` after three consecutive failed polls (~30s). The plugin has no notion of a secondary management address, so there is nothing to fall back to.

| | Data path (iSCSI/FC) | Management path (REST) |
|---|---|---|
| `pure-portal` = `vir0` | multipath fails over to the surviving controller | the VIP moves with the primary role; the plugin never notices |
| `pure-portal` = a controller IP | the same — unaffected | **the REST API becomes unreachable**; storage goes `inactive` |

**What does not break is worth knowing: running guests keep running.** `status()` failing returns `(0,0,0,0)` and records the failure without touching any device, so the multipath maps stay mapped and I/O continues on the data path. What stops is everything that needs the array's API — create, delete, resize, snapshot, clone, migrate — plus the capacity figures in the UI.

### Why this is the standard, not a preference

This is the same requirement Pure places on its other integrations:

- Pure's OpenStack Cinder driver documentation states that **"the Management VIP address is required to properly configure the FlashArray driver"**
- The FlashArray vSphere Plugin refuses to install with a *"No virtual IP configured"* error
- Pure's Ansible collection models `vir0` as a virtual interface distinct from the `ct0.*` / `ct1.*` controller interfaces

### Check which address you are using

```bash
# On the array — look for the vir0 row
purenetwork list

# From a Proxmox VE node
for ip in <ct0-ip> <ct1-ip> <vir0-ip>; do
    echo -n "$ip: "
    curl -sk --max-time 3 "https://$ip/api/api_version" || echo unreachable
done
```

### If you need to change it

`pure-portal` is a fixed property and cannot be updated with `pvesm set`; the storage has to be removed and re-added. That is safe with guests running, but:

1. Have the API token to hand — removing the storage runs `on_delete_hook`, which deletes `/etc/pve/priv/storage/<storeid>.pure-token`.
2. Reuse **exactly the same storage ID**. Volume names encode it (`pve-<storeid>-<vmid>-disk<n>`).
3. `pvesm remove` only deletes the configuration entry — it does not touch volumes on the array and does not deactivate the storage, so multipath devices stay mapped and running guests keep their I/O.
4. Between the remove and the add, Proxmox VE cannot resolve those volids. Do not start a guest or run any storage operation in that window.

```bash
pvesm remove <storeid>
pvesm add purestorage <storeid> \
    --pure-portal <vir0-ip> \
    --pure-api-token <token> \
    --pure-protocol iscsi \
    --content images,rootdir
pvesm status <storeid>
```

---

Documented in both READMEs, on the documentation site, and in the `pure-portal` property description itself, so it also appears in `pvesm set --help` and the storage API schema.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.27-1_all.deb
```

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
