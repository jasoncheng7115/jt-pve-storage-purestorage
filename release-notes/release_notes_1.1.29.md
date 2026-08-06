Found while smoke-testing v1.1.28 on a node whose `libpve-storage-perl` had moved on. No functional change to the data path.

在一台 `libpve-storage-perl` 已經更新過的節點上對 v1.1.28 做安裝測試時發現的。資料路徑沒有任何功能變更。

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

`pvesm status` 過去每次呼叫都會印出上面那行警告。`APIVER` 與 `APIAGE` 位於 **`libpve-storage-perl`，其版本與 `pve-manager` 各自獨立**，而且在 9.1 的小版本之間就從 13 變到 14 再到 15。

Proxmox VE 對兩個方向的處理完全不同（見上表）：宣告值高於執行中的 `APIVER` 會被**直接拒絕載入**，該節點上所有 `purestorage` storage 都會消失；低於它但仍在範圍內則可以載入，但每一次載入 `PVE::Storage` 都會印出警告——也就是每次 `pvesm`／`qm`／`pct` 呼叫、每次服務啟動各一次。

因此沒有任何固定值在每個節點上都正確。宣告 13 到處都能用但在現行函式庫上很吵；改成 15 可以安靜，但較舊的函式庫會直接拒絕載入。

`api()` 現在回傳 `min(APIVER, 15)`，下限 9，並在 `PVE::Storage` 完全沒載入時（`perl -c`、單元測試）回退為 13。已對現場所有函式庫版本與極端值逐一驗證。

**這樣做是安全的，因為 `api()` 只是載入時的關卡。** 掃過整個 `/usr/share/perl5/PVE` 樹確認之後沒有任何地方會依這個值改變行為——Proxmox VE 一律用它自己當前的簽章呼叫外掛方法。上限 15 是本外掛實際實作到的版本，要往上調仍然必須先實作該版本的差異。

> `APIVERSION_MAX` is a maintenance obligation with a deadline, not a set-and-forget constant: when Proxmox VE's floor (`APIVER - APIAGE`) climbs above it, the plugin stops loading. Today's 15/6 gives a floor of 9, so there are six bumps of headroom.
>
> `APIVERSION_MAX` 是有期限的維護義務，不是設定完就不用管的常數：當 Proxmox VE 的下限（`APIVER - APIAGE`）超過它，外掛就會無法載入。目前 15/6 的下限是 9，還有六個版本的餘裕。

---

## `volume_resize` no longer drops a snapshot name

API version 14 added a `$snapname` parameter to `volume_resize()`, for storages that keep snapshots as a chain of volumes and therefore have a resizable object per snapshot. This plugin accepted the parameter positionally and dropped it — which would have resized **the parent volume** when the caller meant a snapshot.

It is now refused with an explanatory message. Not reachable in practice: Proxmox VE only passes a snapshot name when `snapshot-as-volume-chain` is set on the storage, which this plugin does not offer. The base plugin refuses the same case for the same reason.

API 版本 14 為 `volume_resize()` 新增了 `$snapname` 參數，供那些把快照保存為 Volume 鏈、因此每個快照都有可調整大小物件的 storage 使用。本外掛原本會依位置接下這個參數然後丟棄——在呼叫端要求調整快照大小時，實際被調整的會是**母 Volume**。

現在改為明確拒絕並說明原因。實務上不會走到：Proxmox VE 只有在該 storage 設定了 `snapshot-as-volume-chain` 時才會傳入快照名稱，而本外掛不提供該選項。base plugin 基於同樣理由也是拒絕。

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.29-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node / 在**每一個**叢集節點執行：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
