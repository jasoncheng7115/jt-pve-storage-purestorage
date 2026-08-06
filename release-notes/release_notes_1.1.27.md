Documentation release: the management address the plugin is pointed at determines whether a controller failover is transparent or takes the storage offline. **No behaviour change.**

文件釋出：外掛指向哪一個管理位址，決定了控制器 failover 是完全透明，還是讓 storage 直接離線。**無行為變更。**

---

## `pure-portal` must be the array's virtual management IP

A FlashArray is assigned three management addresses at setup: one per controller (`ct0.eth0`, `ct1.eth0`), plus a virtual IP (`vir0`) bound to whichever controller currently holds the management primary role. `pure-portal` must point at the virtual IP.

Pointed at a controller's own address, the plugin loses the REST API the moment that controller fails over: `activate_storage()` cannot reach the array and the storage goes `inactive` after three consecutive failed polls (~30s). The plugin has no notion of a secondary management address, so there is nothing to fall back to.

| | Data path (iSCSI/FC) | Management path (REST) |
|---|---|---|
| `pure-portal` = `vir0` | multipath fails over to the surviving controller | the VIP moves with the primary role; the plugin never notices |
| `pure-portal` = a controller IP | the same — unaffected | **the REST API becomes unreachable**; storage goes `inactive` |

**What does not break is worth knowing: running guests keep running.** `status()` failing returns `(0,0,0,0)` and records the failure without touching any device, so the multipath maps stay mapped and I/O continues on the data path. What stops is everything that needs the array's API — create, delete, resize, snapshot, clone, migrate — plus the capacity figures in the UI.

FlashArray 在建置時會配置三個管理位址：兩顆控制器各一個（`ct0.eth0`、`ct1.eth0`），加上一個虛擬 IP（`vir0`），綁定在當下擔任管理主控角色的那顆控制器上。`pure-portal` 必須指向虛擬 IP。

若指向某顆控制器自己的位址，該控制器一旦 failover，外掛立刻失去 REST API：`activate_storage()` 連不到陣列，storage 在連續三次輪詢失敗後（約 30 秒）轉為 `inactive`。外掛沒有備援管理位址的概念，沒有東西可以回退。

**不會壞的部分同樣值得知道：執行中的 guest 照常運作。** `status()` 失敗時回傳 `(0,0,0,0)` 並記錄，不碰任何裝置，因此 multipath 對應維持不變、I/O 沿資料路徑繼續。停止運作的是所有需要陣列 API 的事——建立、刪除、調整大小、快照、複製、遷移——以及 UI 上的容量數字。

### Why this is the standard, not a preference

This is the same requirement Pure places on its other integrations:

- Pure's OpenStack Cinder driver documentation states that **"the Management VIP address is required to properly configure the FlashArray driver"**
- The FlashArray vSphere Plugin refuses to install with a *"No virtual IP configured"* error
- Pure's Ansible collection models `vir0` as a virtual interface distinct from the `ct0.*` / `ct1.*` controller interfaces

這與 Pure 對自家其他整合的要求一致：OpenStack Cinder 驅動文件寫明「the Management VIP address is required to properly configure the FlashArray driver」；FlashArray 的 vSphere Plugin 在未設定虛擬 IP 時以「No virtual IP configured」錯誤拒絕安裝；Pure 的 Ansible collection 也把 `vir0` 建模為與 `ct0.*`／`ct1.*` 分開的虛擬介面。

### Check which address you are using / 確認目前用的是哪一個

```bash
# On the array — look for the vir0 row / 在陣列上，找 vir0 那一列
purenetwork list

# From a Proxmox VE node / 從 Proxmox VE 節點
for ip in <ct0-ip> <ct1-ip> <vir0-ip>; do
    echo -n "$ip: "
    curl -sk --max-time 3 "https://$ip/api/api_version" || echo unreachable
done
```

### If you need to change it / 若需要修改

`pure-portal` is a fixed property and cannot be updated with `pvesm set`; the storage has to be removed and re-added. That is safe with guests running, but:

`pure-portal` 是 fixed 參數，無法用 `pvesm set` 更新，必須移除 storage 再重新加入。這件事可以在 guest 執行中進行，但請注意：

1. Have the API token to hand — removing the storage runs `on_delete_hook`, which deletes `/etc/pve/priv/storage/<storeid>.pure-token`.
   先準備好 API token——移除 storage 會觸發 `on_delete_hook`，它會刪除該檔案。
2. Reuse **exactly the same storage ID**. Volume names encode it (`pve-<storeid>-<vmid>-disk<n>`).
   必須重用**完全相同的 storage ID**，Volume 名稱把它編碼在裡面。
3. `pvesm remove` only deletes the configuration entry — it does not touch volumes on the array and does not deactivate the storage, so multipath devices stay mapped and running guests keep their I/O.
   `pvesm remove` 只刪除設定條目，不動陣列上的 Volume，也不會 deactivate storage。
4. Between the remove and the add, Proxmox VE cannot resolve those volids. Do not start a guest or run any storage operation in that window.
   空窗期內 Proxmox VE 無法解析那些 volid，這段時間請勿啟動 guest 或執行儲存操作。

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

已寫入兩份 README、文件網站，以及 `pure-portal` 屬性說明本身，因此 `pvesm set --help` 與 storage API schema 也看得到。

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.27-1_all.deb
```

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
