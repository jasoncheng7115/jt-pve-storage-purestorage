Credential-storage release. The array credentials no longer live in `/etc/pve/storage.cfg`. Also makes the plugin honour the volume name Proxmox VE asks for, which backup fleecing depends on.

憑證儲存釋出。陣列憑證不再存放於 `/etc/pve/storage.cfg`。同時讓外掛遵照 Proxmox VE 要求的 Volume 名稱——備份 fleecing 依賴這一點。

---

## MEDIUM — The API token was stored in cleartext and returned by the config API

Proxmox VE 9 lets a plugin declare which of its properties are sensitive, through `plugindata()->{'sensitive-properties'}`. The storage-config API then pulls those keys out of the request before the config is written and hands them to `on_add_hook` / `on_update_hook` instead, so the plugin can put them somewhere protected.

This plugin never declared it. The list therefore fell back to Proxmox VE's hardcoded `encryption-key keyring master-pubkey password`, which covers neither `pure-api-token` nor `pure-password`. Both sat in `storage.cfg` in cleartext, and `GET /storage/<id>` returned them — an endpoint that needs `Datastore.Allocate` on that storage, **not root**. A Pure API token is normally array-wide, so that is full control of the FlashArray rather than of one storage.

Credentials now live in `/etc/pve/priv/storage/<id>.pure-token` and `<id>.pure-pw`, mode 0600, in a directory pmxcfs keeps root-only — the same place the built-in PBS and CIFS plugins keep theirs.

Proxmox VE 9 允許外掛透過 `plugindata()->{'sensitive-properties'}` 宣告哪些設定屬於機密。storage 設定 API 會在寫入設定檔之前把這些鍵抽出來，改交給 `on_add_hook`／`on_update_hook`，讓外掛自行存放到受保護的位置。

本外掛一直沒有宣告。清單因此回退到 Proxmox VE 硬編的 `encryption-key keyring master-pubkey password`，兩者都不涵蓋 `pure-api-token` 與 `pure-password`。兩者都以明文留在 `storage.cfg`，而 `GET /storage/<id>` 會把它們回傳——該端點只需要該 storage 上的 `Datastore.Allocate`，**不需要 root**。Pure 的 API token 通常是整台陣列的權限，因此外洩的是整台 FlashArray 的控制權，而不只是這個 storage。

憑證現在存放於 `/etc/pve/priv/storage/<id>.pure-token` 與 `<id>.pure-pw`，權限 0600，目錄由 pmxcfs 維持只有 root 可讀——與內建的 PBS、CIFS 外掛相同。

### Upgrading / 升級

**No action is required.** An existing storage keeps working unchanged: the plugin prefers the out-of-config secret and falls back to the value still in `storage.cfg`. A Proxmox VE storage update is a merge, so an unrelated `pvesm set` cannot drop the in-config token either.

**不需要任何動作。** 既有 storage 會照常運作：外掛優先使用設定檔外的機密，找不到時回退到仍留在 `storage.cfg` 裡的值。Proxmox VE 的 storage 更新是合併操作，因此無關的 `pvesm set` 也不會把設定檔裡的 token 弄丟。

**To complete the migration** and remove the cleartext copy, run once per storage / **若要完成遷移**、移除明文副本，每個 storage 執行一次：

```bash
pvesm set <storeid> --pure-api-token <token>
```

That writes the secret file **and** removes the old line from `storage.cfg`, in one command.

這一道指令會寫入機密檔**並且**移除 `storage.cfg` 裡的舊行。

> Do **not** use `pvesm set <storeid> --delete pure-api-token` for this. Proxmox VE reports a deletion to the plugin as an explicit removal, so it deletes the secret file as well and leaves the storage with no credentials at all.
>
> **請勿**用 `pvesm set <storeid> --delete pure-api-token` 來做這件事。Proxmox VE 會把刪除當成明確的移除指令傳給外掛，因此連機密檔也會一併刪掉，該 storage 將完全沒有憑證可用。

Verify afterwards with `pvesm status <storeid>` before moving on to the next storage.

完成後先用 `pvesm status <storeid>` 確認可用，再處理下一個 storage。

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

Proxmox VE 會在四個地方指定名稱（見上表）。外掛認不得的名稱會落到一般磁碟分支，該分支**忽略要求的名稱**，改為配置 `vm-<vmid>-disk-<N>`。因此備份 fleecing 映像回來時看起來就是一顆普通的 VM 磁碟，並且佔用了 guest 磁碟編號中的一格。備份仍然可用，因為 Proxmox VE 會記錄並沿用外掛回傳的 volid，所以這個問題一直沒有浮現。

fleecing 現在是一級 Volume 類型——陣列上為 `pve-<storage>-<vmid>-fleece<n>`，且不納入磁碟編號配置——而無法辨識的明確名稱會被拒絕，並在訊息中列出四種支援的形式，不再默默替換掉。`LVMPlugin` 與 `ZFSPoolPlugin` 基於同樣理由接受任何 `vm-<vmid>-<...>`。

---

## Also / 其他

- `_get_api()` now requires the storeid, since that is how the credentials are located. All 21 call sites pass it, and a static check enforces it so a future call site cannot silently omit it and fall back to the legacy path.
- A storage with no resolvable credentials fails with a message naming the command to fix it, rather than a generic constructor error.

- `_get_api()` 現在必須傳入 storeid，因為那是定位憑證的依據。21 個呼叫點全部已傳入，並有靜態檢查把關，未來的呼叫點無法無聲地漏傳而退回舊路徑。
- 完全找不到憑證的 storage 會以「明確指出該執行哪道指令」的訊息失敗，而不是丟出一個泛用的建構子錯誤。

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.25-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node / 在**每一個**叢集節點執行：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

The package uses `systemctl reload` to avoid the stop-phase hang on D-state children, but reload does not reload Perl modules on many Proxmox VE versions.

套件採用 `systemctl reload` 以避免 D state 子行程造成的 stop 階段卡死，但在許多 Proxmox VE 版本上 reload 不會重新載入 Perl 模組。

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
