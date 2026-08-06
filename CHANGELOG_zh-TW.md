# 變更紀錄

**jt-pve-storage-purestorage** 所有重要變更皆紀錄於此檔案。
格式參考 [Keep a Changelog](https://keepachangelog.com/),
版本號採用 `MAJOR.MINOR.PATCH-DEBIAN` 規則。

語言 / Language: [English](CHANGELOG.md) | [繁體中文](CHANGELOG_zh-TW.md)

---

## [1.1.33] - 2026-08-07

### 修正
- 只要 storage id 超過十個字元，快照存取就會失敗。快照存取用的複製名稱是
  Volume 名稱（本身又由 storage id 推導）再加上 36 個字元的字尾，而沒有任何地方
  檢查總長度是否超過 Pure 允許的 63 個字元。陣列對過長的名稱是**直接拒絕**，
  不會截斷：*"Volume name must be between 1 and 63 characters (alphanumeric,
  '_' and '-') in length and begin and end with a letter or number."* 因此受影響
  的 storage 全部失去了「從快照備份」、「對快照執行 `qemu-img convert`」與
  容器備份的能力，而陣列回報的錯誤完全不會提到 storage id。`purestorage` 是
  十一個字元，也就是說最直覺的命名早就已經超標。標記現在由
  `-temp-snap-access-` 改為 `-tsa-`，可用的 storage id 長度從 10 提高到 23——
  比 schema 允許的 24 只少一個——並且在組出名稱的地方就檢查長度，訊息中直接
  指出 storage id 是原因。兩個回收器同時認得舊標記、也會查詢兩種名稱樣式，
  因此本次釋出之前建立的複製仍然會被回收。

## [1.1.32] - 2026-08-06

### 修正
- 在 `pure-host-mode = shared` 之下，某個節點可能銷毀屬於另一個節點的暫存快照
  複製。暫存複製只會連線到建立它的那個節點，因此兩個回收器都以「這個複製有沒有
  連到不是本節點的 host」來判斷歸屬。但在 shared 模式下每個節點回報的 Pure host
  名稱都相同，所以對叢集中任何一個節點建立的複製，這個問題的答案都是「是我的」
  ——而建立者自己的使用中檢查只保護得了自己。於是第二個節點可能中斷連線並銷毀
  第一個節點正在讀取的複製，那正是當初加入歸屬檢查所要防止的事故。現在在無法
  確立歸屬時，回收器會等過任何合理作業的時間：shared 模式改為 24 小時，取代原本
  快速清理的 60 秒與背景回收的 1 小時。`per-node` 模式維持不變，而真正殘留的
  複製在 shared 模式下仍然會被回收。
- 1.1.31 加入的 host 名稱碰撞檢查放在 host 驗證快取之前，因此每次 pvestatd 輪詢
  都會重跑，而不是每個快取週期一次。實測成本可忽略，但 `activate_storage()` 是
  熱路徑，那個快取存在的目的就是讓這條路徑不做事。

### 新增
- 當快照存取用的複製名稱超過 Pure 允許的 63 個字元時發出警告。該名稱是 Volume
  名稱再加 36 個字元，因此 storage id 只要超過約 13 個字元就會超標，即使磁碟
  Volume 本身長度綽綽有餘。若陣列拒絕，快照存取就會失敗——從快照備份、對快照做
  `qemu-img convert`、容器備份——而錯誤訊息完全不會提到 storage id。

## [1.1.31] - 2026-08-06

### 修正
- 兩個只差在 `-`、`_`、`.` 的 storage id 會擁有同一批 Pure Volume。Volume 名稱
  由 storage id 推導，過程中會移除 Pure 不接受的字元並把 `-` 換成 `_`，因此
  `pure-prod`、`pure_prod`、`pure-p.rod` 都會產生
  `pve-pure_prod-<vmid>-disk<n>`。而這個前綴是唯一界定歸屬的依據：
  `list_images()`、殘留回收器、暫存複製回收器與設定 Volume 清理，全都是向陣列
  查詢 `pve-<前綴>-*`，並把每一筆結果都當成自己的。因此同一台陣列上兩個互相
  碰撞的 storage 會共用一個命名空間——彼此都會列出對方的磁碟，而透過其中一個
  執行刪除，可能銷毀另一個的 guest 正在使用的 Volume。現在新增這樣的 storage
  會被拒絕，並在訊息中指出既有的那個；更新則只警告，讓既有的碰撞組合仍可編輯。

### 新增
- 當叢集中其他節點會產生相同的 Pure host 名稱時發出警告。節點名稱會被截斷成
  20 個字元，因此 `virtualization-node-01` 與 `virtualization-node-02` 都會變成
  `pve-pve-virtualization-node-`：先啟用的節點建立該 host，後啟用的節點把自己的
  initiator 加進去，陣列從此無法分辨兩者。所有以節點為單位的歸屬判斷都會出錯，
  包含暫存複製回收器的判斷。外掛選擇回報而非自動改名，因為既有的 Volume 連線
  掛在目前的名稱上，而陣列會以「該 initiator 已被其他 host 使用」拒絕。
  `pure-host-mode = shared` 不在此列，該模式本來就是刻意共用一個 host 物件。

## [1.1.30] - 2026-08-06

### 修正
- 執行中容器的快照沒有經過任何一致性處理。Proxmox VE 在呼叫
  `volume_snapshot()` 之前會用 cgroup 凍結 LXC 容器的行程，但只有在 storage
  透過 `volume_snapshot_needs_fsfreeze()` 要求時才會凍結檔案系統，而本外掛
  沒有實作這個方法。凍結行程只能停止新的寫入，不會把主機核心已經持有的
  dirty page 寫出去，而陣列是透過 REST 取得快照，與本機的 block layer 無關。
  因此執行中容器的快照——包含 snapshot 模式的 vzdump 備份——只是
  crash-consistent，而非檔案系統一致。`RBDPlugin` 基於相同理由也是這樣做。
  QEMU guest 從來不受影響：它們的檔案系統一致性由 guest agent 處理，完全
  不會用到這個方法。
- 快照前的 `sync` 與 `blockdev --flushbufs` 在裝置使用中時會被跳過，而那正是
  有 dirty page 需要寫出的情況——執行中容器的檔案系統是由主機核心掛載的。
  現在兩個呼叫一律執行，仍然有時間上限、仍然是盡力而為。
- `rename_snapshot()` 與 `volume_snapshot_info()` 改為明確拒絕。繼承來的實作
  會走 `filesystem_path()`，而本外掛無法實作該方法；base 的
  `rename_snapshot()` 還會試圖對檔案系統做 `rename()`。目前兩者都不會被呼叫
  到，明確拒絕是為了讓未來的呼叫端得到直接的答案。

## [1.1.29] - 2026-08-06

### 變更
- `api()` 改為與執行中的 Proxmox VE 協商 storage API 版本，不再固定宣告 13。
  `APIVER` 位於 `libpve-storage-perl`，其版本與 `pve-manager` 各自獨立，且在
  9.1 的小版本之間就從 13 變到 14 再到 15，因此沒有任何固定值在每個節點上都
  正確。宣告值低於執行中的 `APIVER` 時，Proxmox VE 會在每一次 `pvesm`、`qm`、
  `pct` 呼叫與每次服務啟動時印出
  `Plugin ... is implementing an older storage API, an upgrade is recommended`；
  而宣告值高於它，較舊的函式庫則會直接拒絕載入外掛，該節點上所有
  purestorage storage 都會消失。現在改為宣告 `min(APIVER, 15)`，下限 9，並在
  `PVE::Storage` 未載入時回退為 13。功能沒有變化：`api()` 只是載入時的關卡，
  Proxmox VE 之後不會依據這個值改變任何行為。

### 修正
- `volume_resize()` 原本會接下 API 版本 14 新增的 `$snapname` 參數卻默默丟棄，
  在呼叫端要求調整快照大小時，實際被調整的會是母 Volume。現在改為明確拒絕並
  說明原因。實務上不會走到：Proxmox VE 只有在設定
  `snapshot-as-volume-chain` 時才會傳入快照名稱，而本外掛不提供該選項。

## [1.1.28] - 2026-08-06

v1.1.25 憑證變更的後續：在整個遷移流程中唯一會被混合版本叢集咬到的那一點加上警告。

### 升級是安全的；在所有節點升級完之前執行遷移則不然

安裝套件不需要任何協調。它不會碰 storage 設定，因此 `on_add_hook`／
`on_update_hook_full` 完全不會執行、不會寫出任何機密檔，尚未遷移的 storage 仍然從
`storage.cfg` 裡的值通過認證——新舊節點皆然。

風險在於遷移指令本身：

```bash
pvesm set <storeid> --pure-api-token <token>
```

`/etc/pve` 會同步，機密檔立刻出現在每個節點。但仍在執行 1.1.25 之前版本的節點不知道
要去讀它，而它原本在讀的明文副本剛剛被移除了。那個節點的 storage 會一直無法通過
認證，直到它的套件升級為止。

外掛現在會在操作者實際承擔這個風險的當下提出警告，而不是在安裝時——那時候這個決定
還沒擺在他面前：

```
Storage 'pure1': moved 'pure-api-token' out of storage.cfg into
/etc/pve/priv/storage/pure1.pure-token (root-only).
  IMPORTANT: every node in this cluster must be running plugin version 1.1.25
  or later before this takes effect safely. Older nodes read the credential
  from storage.cfg, which no longer holds it, and will fail to authenticate
  against the array. Check with:
    pvesh get /nodes --output-format json | grep -o '"node":"[^"]*"'
    # then on each: dpkg -l jt-pve-storage-purestorage
```

兩份 README 也補上同樣的順序要求，並明確寫出套件升級本身不需要協調——避免這個警告
被過度解讀。

**建議順序：**

1. 逐節點升級套件，並在每個節點執行 `systemctl restart pvestatd`。
2. 用 `dpkg -l jt-pve-storage-purestorage` 確認每個節點都是 1.1.25 以上。
3. 此時一切照常運作；token 還在 `storage.cfg`，外掛會回退讀它。
4. 最後才逐一遷移，每個 storage 遷移後先用 `pvesm status <storeid>` 確認，再處理
   下一個。

第 3 步與第 4 步之間沒有時間壓力——尚未遷移的 storage 可以無限期正常運作，只是
token 仍是明文。

---

## [1.1.27] - 2026-08-06

文件釋出：外掛指向哪一個管理位址，決定了控制器 failover 是完全透明，還是讓
storage 直接離線。

### `pure-portal` 必須是陣列的虛擬管理 IP

FlashArray 在建置時會配置三個管理位址：兩顆控制器各一個（`ct0.eth0`、
`ct1.eth0`），加上一個虛擬 IP（`vir0`），綁定在當下擔任管理主控角色的那顆控制器
上。

若指向某顆控制器自己的位址，該控制器一旦 failover，外掛立刻失去 REST API：
`activate_storage()` 連不到陣列，storage 在連續三次輪詢失敗後（約 30 秒）轉為
`inactive`。

**不會**壞的部分同樣值得知道：執行中的 guest 照常運作。`status()` 失敗時不會碰任何
裝置，因此 multipath 對應維持不變，I/O 沿資料路徑繼續。停止運作的是所有需要陣列
API 的事——建立、刪除、調整大小、快照、複製、遷移——以及 UI 上的容量數字。

這與 Pure 對自家其他整合的要求一致。Pure 的 OpenStack Cinder 驅動文件寫明
「the Management VIP address is required to properly configure the FlashArray
driver」，而 FlashArray 的 vSphere Plugin 在未設定虛擬 IP 時會以
「No virtual IP configured」錯誤拒絕安裝。

已寫入兩份 README（含移除重建的操作步驟，因為 `pure-portal` 是 fixed 參數，無法用
`pvesm set` 修改）、文件網站，以及 `pure-portal` 屬性說明本身，因此
`pvesm set --help` 與 storage API schema 也看得到。

無行為變更。

---

## [1.1.26] - 2026-07-27

管理平面負載釋出，延續 v1.1.21 開始的工作。

### 中——穩態下約有一半的 REST 呼叫是可以省掉的

實際計算一次 pvestatd 輪詢的成本——每個節點、每個 storage、每約 10 秒一次——找出
四個不必要的呼叫：

- **同一顆 pod 被抓兩次。** `get_managed_capacity()` 先取得 pod 物件，接著呼叫
  `pod_get_quota_limit()`，後者又把同一顆 pod 抓一次。現在改為把已取得的物件傳
  進去。
- **每個新用戶端都重新偵測 REST 版本。** `_detect_api_version()` 至少要付出一次
  未認證的 `GET /api/api_version`，失敗時最多再探測九次。而它對每個用戶端物件都會
  執行：外掛的用戶端快取 300 秒過期，背景回收又因為 fork 而必然建立新的。陣列不會
  在 pvedaemon 執行期間改變自己的 REST 版本，因此結果現在以陣列為鍵、在行程生命
  週期內快取。若是因為陣列沒有回應而採用的預設猜測值，則刻意**不**快取——下一個
  用戶端應該重新正確偵測，而不是繼承那個猜測。
- **每次 fork 出來的回收都重新登入一次。** Pure 的 `x-auth-token` 是 bearer token，
  因此新用戶端可以沿用其他用戶端已建立的 session。跨 fork **不能**共用的是
  keep-alive 連線，而每個用戶端仍會建立自己的 UA。失效的 token 只會換來一次 401，
  既有的重試路徑會重新登入。
- **`activate_storage()` 重複詢問不會變的東西。** 它每次輪詢都取得 iSCSI 埠清單並
  重新驗證 Host 物件。兩者現在都以行程為範圍快取 `API_CACHE_TTL`（300 秒）。Host
  的紀錄只在檢查**確實成功之後**才寫入，因此短暫失敗不會讓檢查沉默整個 TTL；而若
  Host 物件在快取期間被人從陣列上刪除，`volume_connect_host()` 仍會以明確錯誤失敗。

在附計數器的 API stub 測試環境中，連續三次 `activate_storage()` 加 `status()` 前景
的輪詢：**修正前 15 次呼叫，修正後 8 次。**

以五節點、兩個 Pure storage 的叢集換算，等於完全閒置時從每秒約九次 REST 降到四次
以下。

### 中——rename 可能被重試，導致 Volume 永久滯留

`volume_rename()` 與 `snapshot_rename()` 是 `PATCH` 請求，而 `_request()` 只把
`POST` 排除在 5xx 重試之外——但 LWP 會把讀取逾時回報為合成的 500。因此回應遺失的
rename 會被重試，重試針對的是已經不存在的名稱，回來 404，呼叫端於是判定 rename
失敗。

在 `volume_delete()` 的 tombstone 路徑上，這代表：改用**原始**名稱 destroy → 404
→ 回報刪除失敗 → 陣列上留下一顆已改名但仍存活的 Volume。操作者重試時以原始名稱
找不到東西，回報「可能已經被刪除」，該 Volume 就此永久滯留——持續佔用容量與陣列的
Volume 數量上限，而且再也沒有任何機制會找到它。

兩個 rename 現在都使用新的 `no_retry` 選項，並在失敗時先向陣列查證 rename 是否其實
已經生效，再決定要不要相信那個錯誤。冪等的操作則保留原本的重試韌性。

### 中——`pure-pod` 指向不存在的 Pod 現在會直接失敗

容量查詢原本會回退到整台陣列的數字，因此一個打錯的 `pure-pod` 會讓 storage 回報
整台陣列都可用，而每次建立 Volume 卻都因為 Pod 不存在而失敗——兩個互相矛盾的症狀，
中間只有 pvestatd 日誌裡一行泛用警告可以串起來。

### 文件

兩個 storage 共用同一個 Pod 時，Proxmox VE 會重複計算容量：每個 storage 都把該 Pod
的配額回報為自己的 total、Pod 的 provisioned 回報為自己的 used。Volume 名稱仍正確
隔離，功能不會壞，但兩邊的「可用空間」都是錯的。已寫入兩份 README 的 Pod 章節。

---

## [1.1.25] - 2026-07-27

憑證儲存釋出。陣列憑證不再存放於 `/etc/pve/storage.cfg`。

### 中——API token 以明文儲存，且會被設定 API 回傳

PVE 9 允許外掛透過 `plugindata()->{'sensitive-properties'}` 宣告哪些設定屬於機密。
storage 設定 API 會在寫入設定檔之前把這些鍵抽出來，改交給 `on_add_hook`／
`on_update_hook`，讓外掛自行存放到受保護的位置。

我們一直沒有宣告。清單因此回退到 PVE 硬編的
`encryption-key keyring master-pubkey password`，兩個都不涵蓋 `pure-api-token`
與 `pure-password`。兩者都以明文留在 `storage.cfg`，而 `GET /storage/<id>` 會把它們
回傳——該端點只需要該 storage 上的 `Datastore.Allocate`，不需要 root。Pure 的 API
token 通常是整台陣列的權限，因此外洩的是整台 FlashArray 的控制權，而不只是這個
storage。

憑證現在存放於 `/etc/pve/priv/storage/<id>.pure-token` 與 `<id>.pure-pw`，權限
0600，目錄由 pmxcfs 維持只有 root 可讀——與 `PBSPlugin`、`CIFSPlugin` 存放位置相同。

### 升級

**不需要任何動作。** 既有 storage 會照常運作：`_resolve_credentials()` 優先使用
設定檔外的機密，找不到時回退到 `storage.cfg` 裡的值；而 PVE 的 storage 更新是
合併操作，因此無關的 `pvesm set` 也不會把設定檔裡的 token 弄丟。

**若要完成遷移**、移除明文副本，每個 storage 執行一次：

```bash
pvesm set <storeid> --pure-api-token <token>
```

這一道指令會寫入機密檔**並且**移除 `storage.cfg` 裡的舊行。

> **請勿**用 `pvesm set <storeid> --delete pure-api-token` 來做這件事。PVE 會把
> 刪除當成明確的移除指令傳給外掛，因此連機密檔也會一併刪掉，該 storage 將完全
> 沒有憑證可用。

### 中——現在會遵照 PVE 要求的 Volume 名稱

PVE 會在四個地方指定名稱：

| 呼叫者 | 名稱 |
|---|---|
| `QemuConfig.pm` | `vm-<vmid>-state-<snap>`（記憶體快照） |
| `API2/Qemu.pm`、`Cloudinit.pm` | `vm-<vmid>-cloudinit` |
| `VZDump/QemuServer.pm` | `vm-<vmid>-fleece-<n>`（備份 fleecing） |
| `API2/Storage/Content.pm` | 操作者在 `pvesm alloc` 打的任何字串 |

外掛認不得的名稱會落到一般磁碟分支，該分支**忽略要求的名稱**，改為配置
`vm-<vmid>-disk-<N>`。因此備份 fleecing 映像回來時看起來就是一顆普通的 VM 磁碟，
並且佔用了 guest 磁碟編號中的一格。（備份仍然可用，因為 PVE 會記錄並沿用外掛回傳
的 volid。）

fleecing 現在是一級 Volume 類型——陣列上為 `pve-<storage>-<vmid>-fleece<n>`，且不
納入磁碟編號配置——而無法辨識的明確名稱會被拒絕，並在訊息中列出四種支援的形式，
不再默默替換掉。`LVMPlugin` 與 `ZFSPoolPlugin` 基於同樣理由接受任何
`vm-<vmid>-<...>`。

### 其他

- `_get_api()` 現在必須傳入 storeid，因為那是定位憑證的依據。21 個呼叫點全部已
  傳入，且 `tools/audit-invariants.pl` 會靜態檢查，未來的呼叫點無法無聲地漏傳而
  退回舊路徑。
- 完全找不到憑證的 storage 會以「明確指出該執行哪道指令」的訊息失敗，而不是丟出
  一個泛用的建構子錯誤。

---

## [1.1.24] - 2026-07-27

正確性釋出。其中三項是無聲的：外掛與 Proxmox VE 對某件事的認知不一致，而兩邊都
不會報錯。

### 嚴重——Linked clone 可能多出指向使用中 Volume 的幽靈「未使用」磁碟

`clone_image()` 對 linked clone 回傳 `base-102-disk-0/vm-104-disk-0`，guest 設定
存的也是這個。但 `list_images()` 回報的是單純的 `vm-104-disk-0`。

`PVE::QemuServer::update_disk_config`——`qm rescan` 實際執行的程式——會用設定檔裡的
volid 標記「已被引用」，再拿這組去比對外掛回報的 volid。兩種形式不一致時，該
Volume 看起來就是沒被引用，PVE 於是呼叫 `add_unused_volume()`。guest 因此多出一個
`unusedN`，**指向它 `scsi0` 正在使用的同一顆 Pure Volume**；操作者在 GUI 移除這個
「未使用磁碟」，就會銷毀使用中的磁碟。

`list_images()` 現在會從 Pure 的 `source` 欄位推導 base，並輸出 `base/clone` 形式。
只接受 `.pve-base` 快照作為來源，因此 full clone 與從使用者快照建立的複製仍維持
單純名稱——比對到其他來源會憑空製造一個不存在的相依關係，產生這個 bug 的鏡像版本。
當陣列未回報 `source` 時，行為與先前相同。`RBDPlugin::list_images` 是以 rbd parent
snapshot 做同樣的事。

### 高——容器備份每次洩漏一顆 Pure Volume，且無限累積

`PVE::VZDump::LXC` 呼叫 `activate_volumes($cfg, $volids, 'vzdump')`，落到我們的
`path()`，在陣列上建立一顆快照存取用的複製、連線到主機、等待它的 multipath 裝置。
接著掛載、rsync、卸載、刪除 `vzdump` 快照——然後**完全不會呼叫 `deactivate_volume`**
（`grep -c deactivate_volume VZDump/LXC.pm` 回傳 0），因此
`_cleanup_temp_snap_clone()` 從未被觸發。

也就是每個容器 mountpoint、每次備份，洩漏一顆 Pure Volume、一條主機連線、一個本機
multipath 裝置。唯一的後備是那個一小時的殘留回收器，而依 v1.1.22 修正的毫秒時間戳記
問題，它在 API 2.x 陣列上根本從未執行過——因此有排程容器備份的站點，從安裝外掛以來
就一直在累積這些。

清理改由 `volume_snapshot_delete()` 觸發，那是 PVE 確實會呼叫的位置，並套用與背景
回收器相同的歸屬、年齡與使用中三道閘門。

升級後**檢查是否已有累積**：`journalctl -t pvestatd | grep 'temp-clone'`，或在 Pure
UI 搜尋符合 `pve-<storage>-*-temp-snap-access-*` 的 Volume。

### 高——調整磁碟大小不會傳達到本機裝置

`volume_resize()` 的本機刷新被 `$running` 判斷包住。在 VM 停機時調整大小，本機
multipath map 仍維持舊容量；啟動 guest 後 qemu 交給它的就是舊容量，而且任何地方
都不會報錯。在某個節點調整、在另一個節點啟動也是同樣結果，那是再怎麼加判斷都涵蓋
不到的。

刷新現在無條件執行——本節點沒有該 Volume 的裝置時它就是 no-op——並且
`activate_volume()` 會用它本來就已取得的陣列端大小與 `blockdev --getsize64` 對帳，
只在不一致時才重掃。整段刷新都是 best-effort：此時陣列端的 resize 已經成功，本機
失敗不能被回報成 resize 失敗（重試會被當成縮小而拒絕）。

這同時修好了容器的 resize——它在本外掛上從來沒有真正生效過。
`PVE::API2::LXC` 呼叫 `volume_resize(..., $running = 0)` 時 `$running` 恆為 0
（它自己的註解說明該參數只對 QEMU 有意義），因此被判斷式包住的刷新對容器完全
不會執行。PVE 接著對應該 Volume 並執行 `resize2fs`，面對的是仍回報舊容量的裝置，
而失敗只會以一行 `warn` 呈現。陣列上的 Volume 變大了、CT 設定記下了新大小，
檔案系統卻沒有任何改變。

### 中——`$vollist` 用前綴比對

`$vollist` 裝的是完整 volid，base plugin 是精確比對。前綴比對在查詢
`vm-10-disk-1` 時會一併回傳 `vm-10-disk-10` 與 `vm-10-disk-11`。目前 PVE 沒有呼叫者
會傳 vollist，但回傳呼叫端沒有要求的 Volume，正是「遷移搬走了我沒選的磁碟」的成因。

---

## [1.1.23] - 2026-07-27

資料安全釋出。本次每一項發現都是同一個設計錯誤的變形：安全檢查在自己無法完成時，
回答的是「可以繼續」而不是「我不知道」。在健康的節點上，本次變更不影響任何正常
操作；它改變的是節點不健康時會發生什麼事。

### 嚴重——使用中檢查改為 fail-closed

`is_device_in_use()` 把「我無法判斷」歸類成「沒有在使用」。任何內部失敗——
`/proc/mounts` 讀取逾時、`fuser` 被自己的 5 秒看門狗殺掉、裝置路徑無法解析——
都會落到 `return 0`。

為什麼嚴重：對一顆交給執行中 VM 使用的 raw Pure LUN 而言，沒有掛載點，也沒有
真正的 holder（kpartx 分割自 v1.1.7 起就被刻意忽略），因此
**`fuser` 是唯一會回報「guest 正持有此裝置」的訊號**。`fuser` 一旦逾時，
「有 VM 正在使用這顆磁碟」就變成「沒有任何東西在用這顆磁碟」——而且恰好發生在
節點不健康到足以觸發該看門狗的時候——接著 `free_image()` 會把該 Volume 從所有
主機斷線並銷毀。

新增的 `device_usage_state()` 回傳 `in-use`／`idle`／`unknown` 並附上可讀的
理由。`is_device_in_use()` 現在只是包裝，把 `unknown` 視為使用中。呼叫端會把
理由一併回報，操作者看得到外掛「為什麼」拒絕，而不是只看到一個失敗。

### 嚴重——WWID 查詢失敗不再讓安全檢查失效

`free_image()`、`volume_snapshot_rollback()` 與 `create_base()` 原本都是：

```perl
my $wwid = eval { $api->volume_get_wwid($pure_volname); };
if ($wwid) { ... 整段使用中檢查 ... }
... 照樣銷毀／覆寫 ...
```

因此一次短暫的 REST 錯誤就會跳過檢查，讓破壞性操作在無保護的狀態下執行。
rollback 是最糟的情況：`volume_overwrite()` 會直接取代 Volume 的全部內容，
而且與銷毀不同，**沒有 eradication delay 的復原窗口**。

三者現在都改走 `_require_wwid_for_guard()`，重試一次後即拒絕並給出可據以行動的
訊息。**查詢本機裝置**失敗同樣視為錯誤，不再被解讀成「本機沒有裝置」。

### 高——不再有任何自動路徑執行不可復原的 eradicate

殘留暫存複製回收與逐 session 的暫存複製清理，原本呼叫 `volume_delete()` 時未帶
`skip_eradicate`，也就是 `DELETE /volumes`——永久刪除、沒有任何復原窗口，而且是
由背景回收程序發出的。兩者現在都改為軟銷毀，因此外掛中全部 15 個刪除呼叫點都可
在陣列的 eradication delay 內復原。

請注意這個回收器其實是到 1.1.22 才開始真正運作：在毫秒時間戳記修正之前，它的
年齡判斷在 API 2.x 陣列上永遠不成立。

### 高——暫存複製回收改為在本機二次驗證

Pure 陣列端的 filter 沒有錨定能力，因此
`pve-<storage>-*-temp-snap-access-*` 這個 glob 比外掛實際產生的名稱寬鬆。回收器
現在會把每個候選對象重新比對 `path()` 產生的精確格式——
`pve-<storage>-...-temp-snap-access-<unix-ts>-<pid>`——不符者跳過並記錄警告。
刪除前還要求**兩個互相獨立的年齡來源**都同意：陣列回報的 `created` 時間戳記，
以及建立當下寫進名稱裡的 unix 時間戳記。兩者來自不同時鐘、不同程式路徑，因此
任一方的 bug 或單位錯置都無法單獨授權一次刪除。

### 高——`alloc_image()` 取代 state／cloudinit Volume 前會先檢查

這是外掛中唯一完全沒有使用中檢查的破壞性路徑：一旦發現同名的
`vm-<id>-state-<snap>` 或 `vm-<id>-cloudinit` Volume，就直接斷線並銷毀，唯一的
痕跡只有一行 `warn()`。若該 Volume 保存的是執行中暫停 guest 的 RAM 映像，就會被
丟棄。現在改為套用其他銷毀路徑一致的保護。

### 高——兩個互相抵消的 `volume_list()` 呼叫

`volume_list()` 只接受一個位置參數，但有兩處以具名參數呼叫，導致 `$pattern` 綁到
字串常值 `"pattern"`，等於去向陣列詢問一顆名稱正好是 `pattern` 的 Volume：

- `_cleanup_vm_config_volumes()` 因此從未刪除過任何東西。
- `free_image()` 的「這是這台 VM 的最後一顆磁碟嗎」判斷永遠為真。

兩個 bug 互相抵消，結果只表現為「config 備份 Volume 洩漏」。**若只修好其中一邊，
多磁碟 VM 在刪除第一顆磁碟時就會開始銷毀 config 備份，而其餘磁碟的快照還在引用
它們**——因此兩者一併修正。`free_image()` 在無法取得磁碟清單時改為直接跳過清理，
不再用猜的。

### 高——Fibre Channel：不再每次 rescan 都發 LIP

LIP（Loop Initialization Primitive）是**鏈路重置**，不是查詢。它會強迫該 HBA
port 後面所有裝置重新登入，包含同一張 HBA 上屬於其他儲存的 LUN。而探索新對應的
LUN 根本不需要它——SCSI host 掃描透過既有 session 的 `REPORT_LUNS` 就能做到。

`rescan_fc_hosts()` 原本無條件發送 LIP，而它被呼叫的位置都是緊密迴圈：
`path()` 的重試迴圈（每 2 秒）、`alloc_image()` 的等待迴圈（每 3 秒）、
`wait_for_multipath_device()` 的 FC callback（每一輪），以及 v1.1.22 之前的
`activate_storage()`（每次 pvestatd 輪詢）。等於反覆對整個 fabric 做鏈路重置，
卻換不到任何東西。LIP 現在改為選用（`rescan_fc_hosts(lip => 1)`），預設不啟用。

`FC.pm` 也改用 `sysfs_read_with_timeout()` 讀 sysfs，不再用裸 `open()`。在卡住的
HBA 上讀 `/sys/class/fc_host/*/port_state` 會無限期阻塞，而 `get_fc_targets()`
正是在 pvestatd 路徑上的 `activate_storage()` 裡被呼叫。

### 高——`pve-pure-config-get` 不會再卡死

這支災難復原工具原本用裸 `system('mount', ...)`／`system('umount', ...)`，完全
沒有逾時。對一個路徑已經全斷的 multipath 裝置做 mount 會進入不可中斷睡眠而永遠
不返回——而這支工具本來就只在儲存已經出問題時才會被執行，所以那是預期狀態而非
邊角案例，連 Ctrl-C 都沒用。現在所有外部指令都走
`PVE::Tools::run_command` 並帶明確逾時，與外掛其餘部分一貫的規則一致。

它同時改用 `PVE::INotify::nodename()` 而非 `hostname -s`，確保連線到的是外掛
實際註冊在陣列上的那個 Pure Host 物件；裝置清理也包了保護，避免在設定檔已經
寫入之後才因清理被拒而中止。

### 高——還原時挑選最新的一代

一顆被刪除又重建多次的磁碟會留下多個 tombstone，strip 之後全部指向同一個原始
名稱。原本以字典序排序會挑到**最舊**的一代，較新的幾代接著撞名衝突，導致整個
還原中止。現在改用 tombstone 後綴裡內嵌的 unix 時間戳記來挑選，並且明確印出
選了哪一代、還有哪些其他世代可用。

### 高——暫存複製回收器尊重歸屬

暫存複製只會連線到建立它的節點，但每個節點都在跑回收器。節點 A 自己的回收器會被
`is_device_in_use()` 擋下；節點 B 本機沒有這顆裝置，因此直接越過該檢查，把它從
**所有**主機斷線並銷毀。在節點 A 上執行超過一小時的快照來源操作——大磁碟的
`qemu-img convert` routinely 就會超過——裝置就這樣被抽走。回收器現在會跳過仍連線
到其他節點的暫存複製；崩潰節點留下的殘留由該節點回來時自行清理，那本來就是比較
正確的歸屬模型。

### 中——其他強化

- `remove_scsi_device()` 刪除前會驗證裝置仍帶有預期的 WWID。`free_image()` 是在
  陣列端斷線**之前**擷取 multipath slave 清單、在之後才刪除；kernel 會重用
  `/dev/sdX` 名稱，因此併發的 rescan 可能把同一個名稱給了不相干的 LUN，導致該
  LUN 的路徑被移除。
- `volume_get_connections()` 區分「沒有連線」與「查詢失敗」。兩者都回傳空清單，
  會讓 `free_image()` 跳過斷線直接刪除，留下殘留的主機連線——也就是 v1.1.3／
  v1.1.4 事故背後的 ghost LUN。`free_image()` 現在在無法列出連線時拒絕刪除。
- 最後幾個無上限的等待也移除了：`status()` 的中介子行程，以及
  `sysfs_read_with_timeout()` 的成功路徑，都改用 `WNOHANG` 有界輪詢回收。
- `_run_cmd()` 與 `sysfs_read_with_timeout()` 會保存並還原呼叫端原本設定的
  alarm，而不是用裸 `alarm(0)` 把它清掉。

### 低

- `postinst` 將 `fuser` 加入必要 binary 檢查。它是判斷執行中 guest 的關鍵檢查，
  而 `psmisc` 本來就是硬相依。

---

## [1.1.22] - 2026-07-26

主機端穩定性釋出。移除 Proxmox VE 每次狀態輪詢都會觸發的常態 SAN 重新掃描
負載，修正指令逾時處理器內部無法終結的卡死，重寫裝置探索流程，並修正 Pure
REST 2.x 的時間戳記處理。本次同時處理 issue #13，並釐清 issue #10 背後的
pod 容量回報行為。

### 嚴重——不再於每次 pvestatd 輪詢執行完整 SAN 重新掃描

Proxmox VE 會在每次 pvestatd 輪詢（約 10 秒）時，由
`PVE::Storage::storage_info()` 對每個已設定的 storage 循序呼叫
`activate_storage()`。而 `activate_storage()` 在每一次呼叫中都無條件執行：

- iSCSI session 重新掃描（每個 `LOGGED_IN` session 最多 10 秒）；
- 對所有 iSCSI host 執行 SCSI host 掃描；
- 全主機範圍的 `multipathd reconfigure`，會重建節點上的**每一個** multipath
  對應；以及
- `udevadm trigger --subsystem-match=block` 後接 `udevadm settle`，會重新觸發
  系統上的**每一個**區塊裝置。

換言之，每個節點、每個 Pure storage 每分鐘會做六次完整 multipath 重建與全系統
udev 重新觸發。除了常態成本之外（它會排在其他所有 storage 狀態輪詢之前循序
執行），它更直接與裝置探索互相競爭：正在等待新對應 LUN 的 VM 啟動或備份作業，
等於在跟一個不斷拆除並重建對應表的 reconfigure 賽跑。

現在只有在本節點**實際登入新的 iSCSI portal** 時才會立即重新掃描，其餘情況
最多每 `pure-rescan-interval` 執行一次（新選項，預設 300 秒；設為 0 可回到
先前行為）。新 LUN 的探索並不依賴這個週期性掃描——`activate_volume()`、
`path()` 與 `alloc_image()` 各自會針對所需的 WWID 執行專屬的重新掃描與等待。
保留在此處的僅是針對外部（out-of-band）對應 LUN 的安全網。

此外，`multipathd reconfigure` 在所有探索與輪詢路徑上都以行程範圍限流，最多
每 30 秒一次，避免多個呼叫端又形成 reconfigure 風暴。真正的設定變更（寫入
`/etc/multipath/conf.d/pure-storage.conf`）仍會立即重新載入。

### 高——指令逾時處理器內部無法終結的卡死

`Multipath.pm` 與 `ISCSI.pm` 的 `_run_cmd` 逾時處理器原本執行
`kill('TERM', $pid)` 之後接一個**會阻塞的** `waitpid($pid, 0)`。處於不可中斷
睡眠（D state）的子行程——正是這些逾時機制存在的理由——無法被 `TERM` 或
`KILL` 終結，因此阻塞的 `waitpid` 永遠不會返回，而原本能救我們出來的 alarm
早已觸發並被清除。逾時處理器本身變成了卡死點。

現在改為由 `TERM` 升級到 `KILL`，並只以 `WNOHANG` 在有限次數的輪詢中回收，
若仍無法回收則交由 init 處理，而不是讓自己一起陷入 D state——與
`sysfs_write_with_timeout()` 一貫採用的作法相同。

### 高——重寫裝置探索等待迴圈（issue #13）

`wait_for_multipath_device()` 原本只在迴圈本體的**最後**才檢查裝置，而該本體
在劣化的 fabric 上可能耗盡整個逾時預算（逐 session 的 iSCSI 重新掃描、逐 host
的 SCSI 掃描、`multipathd reconfigure`、`udevadm trigger`、`udevadm settle`）。
在 60 秒預算而單趟耗時 45 秒的情況下，呼叫端只會看到裝置一次——而且是在最糟的
時間點，剛好在全主機 reconfigure 攪動對應表之後。晚兩秒才出現的 LUN 就會被
判定為不存在。它也從不在重新掃描**之前**先檢查，因此最常見的情況（裝置其實
已經在了）仍然要付出完整成本。

現在改為逐級升高的流程：先檢查，接著是傳輸層重新掃描、SCSI host 掃描、udev，
只有從第二輪起才動用受限流的 reconfigure——每個步驟後都會再檢查一次，步驟之間
以約 1 秒間隔輕量輪詢，且每個階段都會檢查截止時間。`activate_volume()` 同樣
會在執行任何重新掃描前先確認裝置是否已存在。

### 高——`activate_storage` 不再執行殘留暫存複製的清理

該清理會在陣列上中斷連線並刪除 Volume。具變更性、可能緩慢的陣列操作，不應該
放在 Proxmox VE 每約 10 秒以短逾時健康用戶端輪詢的路徑上。`status()` 早已將它
以背景回收行程 fork 出去，並在鎖保護下使用耐用用戶端執行。

### 高——裝置未出現時提供可據以行動的診斷資訊

「裝置未出現」錯誤現在會回報**在失敗當下擷取**的主機狀態，而不是留給管理者
自行重現：

- `multipathd` 當下看到的內容（對應總數、Pure 對應數、此 WWID 是否有對應、
  其 `/dev/mapper` 節點是否確實已建立）；
- 若找不到我們的 WWID，列出 multipathd 確實看得到的其他 Pure WWID；
- 相符的 `/dev/disk/by-id` 符號連結；
- 直接自 sysfs 讀取的逐 session iSCSI 狀態，並在 session 非 `LOGGED_IN` 時明確
  標註——LUN 重新掃描只會對 `LOGGED_IN` 的 session 發出，因此只能經由失效路徑
  抵達的 LUN，在該路徑恢復前無法被探索到；
- FC 環境則回報線上目標埠數量。

### 中——Pure REST 2.x 時間戳記為毫秒

REST 2.x 回傳的時間戳記是自 epoch 起算的毫秒，REST 1.x 回傳的則是 ISO 8601
字串，而原本的程式碼假設剛好相反。造成兩個後果：

- 交給 Proxmox VE 的快照 `ctime` 是被當成秒來讀的毫秒值，導致 Web UI 上的快照
  日期落在約 53000 年後。
- 殘留暫存複製回收的「超過一小時」判斷在 2.x 陣列上永遠不成立，因此殘留的暫存
  快照複製從未被清理。每一個都佔用一個 Volume 名額、在每個叢集節點上佔用一條
  主機連線，並留下一個殘留的 multipath 裝置。

兩者現在都改用單一的 `pure_time_to_epoch()` 輔助函式，可同時處理兩種格式。

### 中——連線至所有節點步驟的主機查詢

API 2.x 的 `names` 查詢參數不接受萬用字元，因此
`host_list("pve-<cluster>-*")` 總是回傳空值，新 Volume 只會預先連線到本機
節點。線上遷移仍然可用——目標節點會在 `activate_volume()` 時自行連線該
Volume——但用來讓遷移更順暢的預先連線從未發生，且「未連線至下列主機：⋯」的
警告也永遠不會出現。萬用字元現在改走 `filter` 參數，與 `volume_list` 既有作法
一致。

### 中——Pod 容量回報（issue #10）

對於使用 pod 的 storage，外掛以 pod 的 `quota_limit` 作為 `total`，並以某個
pod 空間數值作為 `used`。由於 Pure 的 Volume 是精簡配置，一個內含 32 GiB
Volume 的 pod 即使幾乎沒有寫入資料，其 provisioned 仍為 32 GiB，因此之後才
設定的 3 GiB 配額會立刻顯示為 100% 已滿——而寫入既有 Volume 卻仍然正常。兩者
都是正確的：陣列**會**拒絕該 pod 內的下一次 Volume 建立或擴充，但**不會**拒絕
對既有 Volume 的寫入。過去這些數字並未說明這一點。

- `used` 現在會被限制在配額之內，Proxmox VE 不會再拿到 `used > total`
  （先前會呈現超過 100% 的長條）。
- 達到或超過配額的 pod 每小時會記錄一次說明，內容包含陣列回傳的原始 `space`
  數值；若為延伸（stretched）pod，也會列出成員陣列數量——Pure 的部分 pod 空間
  數值是以每個陣列副本為單位回報的。
- 新增選項 `pure-pod-usage-metric` 可選擇回報哪一個數值：`provisioned`
  （預設，可預測配置失敗）、`virtual`（主機寫入的邏輯位元組，符合直覺的
  「用了多少」但無法預測配置失敗）或 `physical`（陣列上縮減後的實際位元組）。

### 中——移除 `deactivate_storage` 的 N+1 REST 查詢

逐 Volume 的 `volume_get_wwid()` 呼叫已改為由 Volume 清單既有回傳的 serial
在本地推導 WWID。舊寫法是對陣列管理閘道的 N+1 風暴，而且正好發生在節點關機或
storage 於整個叢集停用時。

### 中——API 用戶端快取鍵

快取鍵原本使用 `$scfg->{storage}`，而 Proxmox VE 從不填入該欄位，因此實際上
退化為僅以 portal 位址作為鍵值。指向同一陣列但使用不同 API token——或不同
`pure-status-timeout`——的兩個 storage 會共用同一個快取用戶端，且先建立者會在
整個 300 秒 TTL 內勝出。新的鍵值涵蓋 portal、憑證、SSL 設定、健康路徑旗標與
逾時。

### 低——其他修正

- `filesystem_path()` 原本把 `$scfg->{storage}` 當作 storage id 傳遞，而該值
  恆為 `undef`，因此每次呼叫都會在命名模組內部以「storage is required」失敗。
  現在改為以可據以行動的訊息失敗。目前 Proxmox VE 沒有任何路徑會對本外掛呼叫
  到它。
- 移除 `deactivate_storage` 中不帶參數的 `multipath_flush()` 呼叫，該呼叫只可能
  拋出例外——此輔助函式刻意拒絕執行 `multipath -F`，因為它會清除主機上所有未
  使用的對應。
- `activate_volume()` 現在會追蹤 Volume 的 WWID，補上原本的缺口：未經 `path()`
  呼叫而啟用的 Volume，對叢集殘留裝置清理是不可見的。
- postinst 不再把其他廠商的 multipath 設定回報為 Pure 的風險。原本的危險設定
  檢查是對整份 `/etc/multipath.conf` 做 grep，完全不判斷作用範圍，因此位於
  `device { vendor "NETAPP" }` 區塊內的 `no_path_retry queue`——它對 Pure
  裝置毫無作用，而且是該廠商自己的建議值——會被當成 Pure 的風險回報。現在會
  追蹤作用範圍，只有位於 `defaults` 或 PURE device 區塊的設定才會發出警告；
  屬於其他廠商範圍的設定則以提示方式列出供參考。
- 當某些 Purity 版本的 `GET /pods` 未回傳 `space` 時，`get_managed_capacity()`
  會改用 `GET /pods/space`。

---

## [1.1.21] - 2026-06-16

管理平面負載與 pvestatd 隔離釋出。降低外掛對 FlashArray 管理閘道造成的穩態
REST 負載，並避免單一緩慢或劣化的陣列拖垮同節點上的其他 storage。本次修正
自相關 NetApp 外掛的同型樣式（sibling-pattern）移植而來。

### 高——將 pvestatd 健康路徑與緩慢陣列隔離

`activate_storage()` 與 `status()` 的前景現在改用短逾時、單次嘗試的 REST
用戶端，取代原本耐用的資料路徑用戶端（15 秒 × 2 次重試，最壞約 34 秒）。PVE
每約 10 秒會循序輪詢各 storage，因此緩慢或劣化的陣列先前會拖累整個 pvestatd
週期，把同節點上的其他 storage 拖成 `inactive`。新增選項 `pure-status-timeout`
（預設 5 秒，範圍 2 至 60）。在此路徑上取消每次呼叫的重試不會有任何損失——
下一次輪詢本身就是重試。資料路徑（配置／釋放／複製）與背景殘留回收仍維持
耐用用戶端。在負載很重但健康的陣列上，狀態可能短暫顯示 `inactive` 並於下次
輪詢恢復；執行中的 VM 不受影響（裝置維持對應）。

### 高——REST 用戶端啟用 HTTP keep-alive

`LWP::UserAgent` 現在會跨呼叫重複使用同一條 TCP+TLS 連線
（`keep_alive => 1`），而非每次請求都重開連線與完整 TLS 交握。在穩態
pvestatd 輪詢下（每個叢集節點每約 10 秒一次，外加背景回收），這明顯降低
陣列管理閘道需吸收的連線抖動。控制器故障切換後若有失效的 keep-alive 連線，
只會讓單一請求失敗，LWP 會透明重連，並受（健康路徑上的短）逾時所限。

### 中——限制 iSCSI 啟用的探索／登入迴圈總時間

每個 portal 的逾時（探測 2 秒、探索 30 秒、登入 60 秒）只能限制單一 portal，
無法限制整個迴圈的時間，因此數個可達但卡住的 LIF 仍可能拖住 pvestatd。新增
選項 `pure-activate-deadline`（預設 30 秒，設 0 可停用）：一旦時間預算用盡
且至少有一個 portal 已登入，其餘 portal 便延後至後續啟用再處理。當尚無任何
路徑時不會套用此預算（storage 必須取得至少一條路徑，否則據實失敗），且不會
中斷進行中的登入，因此緩慢但可達的 storage 不會被標記為 inactive。iSCSI
session 清單現在於迴圈前一次性快照，不再逐 portal 查詢。

### 低——移除暫存複製回收中的逐 Volume REST 呼叫

`_cleanup_orphaned_temp_clones()`（每次輪詢都會由 `status()` 背景回收執行）
現在改用 `serial_to_wwid()`，從 `volume_list()` 回應中已含的 serial 在本地
計算每個暫存複製的 WWID，而非逐 Volume 發出 `volume_get_wwid()` REST 呼叫。
這與殘留回收已採用的最佳化一致。

### 低——postinst 升級後提示重新啟動 pvestatd

升級後，postinst 現在會顯示醒目警告，提示操作者必須在叢集的每個節點執行
`systemctl restart pvestatd` 以啟用新的外掛程式碼。本套件刻意使用
`systemctl reload`（SIGHUP）以避免 stop 階段卡在 D-state 子行程，但在許多
PVE 版本上 reload 並不會重新載入 Perl 模組，因此 pvestatd 可能仍執行舊程式碼。
該警告也說明如何驗證 `MainPID` 已變更。

---

## [1.1.20] - 2026-05-29

Proxmox VE 9.2 相容性釋出。

### 中——覆寫 `get_identity()` 以相容 PVE 9.2

PVE 9.2 在 base `PVE::Storage::Plugin` 新增了 `get_identity()`，其預設實作會
`die` 並回報「get_identity not implemented for this plugin」。它透過新的
`GET /nodes/<node>/storage/<storage>/identity` 端點被呼叫（主要供 Proxmox
Backup Server 比對實例；Web UI 也可能對任一 storage 輪詢），因此在 PVE 9.2
上，base 的 `die` 會在 Web UI 浮現為錯誤。外掛現在覆寫此方法，回傳具決定性的
`purestorage:<portal>:<pod>`——管理 portal 加上選用的 ActiveCluster pod，兩者
一起把 storage 綁定到單一陣列。簽章已對照 pve-storage 原始碼驗證
（`my ($class, $scfg, $storeid)`）。不需變更 `APIVERSION`：外掛仍宣告 13，落在
PVE 9.2 接受的 9..14 範圍內。

---

## [1.1.19] - 2026-05-29

規模化與殘留清理安全性釋出。處理大量 Volume（超過 1000）情境下的行為，並強化
背景殘留清理，避免誤清正在使用中的 LUN；另外移植數項來自相關 NetApp 外掛的
監控功能。

### 高——Volume／Snapshot 列舉不再只取第一頁

`volume_list()`、`volume_list_destroyed()` 與 `snapshot_list()` 現在會依
API 2.x 的 `continuation_token` 逐頁抓取。Pure FlashArray REST 2.x 對每次集合
GET 都有單頁上限（預設約 1000 筆），並以 `more_items_remaining` 加
`continuation_token` 表示尚有後續頁。先前的程式只讀第一頁，因此當某 storage 的
Volume 或 Snapshot 超過一頁時會被靜默截斷：`list_images()` 會讓 Proxmox VE
Web UI 看不到部分磁碟，殘留清理也看不到後段 Volume（進而可能被誤判為殘留）。
API 1.x 不受影響。新增 `API::_get_v2_collection()` 協助函式負責逐頁走訪。

### 高——殘留清理強化（絕不清掉使用中的 LUN）

- **移除每次輪詢的 API 負載**：`_cleanup_orphaned_devices()` 的 Phase 1 現在
  直接從 `volume_list()` 回應中已帶有的 `serial` 推導 WWID，不再對每顆 Volume
  於每次 `pvestatd` 輪詢（約 10 秒）多打一次 `volume_get_wwid()` REST 呼叫。在
  大型 storage 上，這消除了會隨 Volume 數量線性成長、且可能觸發陣列 API 速率
  限制的每輪呼叫爆量。
- **背景清理序列化**：以 per-storeid 的非阻塞 `flock`，避免單次清理在大型陣列
  上超過 10 秒輪詢間隔時、多個清理行程互相堆疊。
- **寬限期加缺席遲滯**：首次追蹤未滿 600 秒的 WWID 一律不清（保護剛加入、qemu
  尚未開啟的 LUN——此時使用中檢查理應回報為閒置），且 WWID 必須連續 3 次清理
  輪詢都不在陣列上才會拆除。這可吸收單次短暫或不完整的陣列回應。此為跨專案
  強化，源自 NetApp 端「剛加入、使用中的 LUN 被清掉」的事故。
- **修正跨 storage 誤判**：當一台主機上有多個 purestorage storage（多個 pod 或
  多個陣列）時，Phase 3 以往會把另一個 storage 的使用中裝置當成殘留、並建議對它
  執行 `multipath -f`。Phase 3 現在會聯集本節點上其他 purestorage storage 已
  追蹤的 WWID 並略過它們。（對應 NetApp v0.2.15。）

### 中——監控功能新增（對應 NetApp v0.2.10／v0.2.11）

- **停機偵測**：`status()` 在連續 3 次輪詢失敗後記錄一筆 ERROR（停機期間最多每
  30 秒重發一次），恢復時記錄 INFO，於 journal 以 `pure-storage:` 標記供監控
  擷取。
- **容量健康**：使用率達 90%（WARNING）與 95%（ERROR）時警告，每小時一次。
- **控制器冗餘**：`activate_storage()` 在所有可達的 iSCSI portal 都落在單一
  Pure 控制器時（無控制器層級的路徑冗餘），每 24 小時警告一次。
- **postinst 進行中操作寬限**：偵測進行中的 `qmrestore`／`vzdump`／`qm
  move-disk`／`clone`／`migrate`／`pvesm` 操作，於重新載入服務（優雅 SIGHUP）前
  印出 NOTICE 並提供 5 秒寬限。

---

## [1.1.18] - 2026-05-14

### 中——Snapshot 砍前先 tombstone rename（與 v1.1.15 Volume 端的修法相對應）

Tracked in [#11]。Pure 的 destroyed-pending 狀態會保留 snapshot
suffix 直到陣列的 eradication delay（預設 24 小時）。砍 snapshot
之前若沒有先改名，這段期間建立同名 snapshot 會失敗：

```
TASK ERROR: Snapshot 't1' already exists for volume 'vm-101-disk-0'
```

常見的 PVE 工作流——例如建週期性 snapshot 名為 daily、weekly，要
delete 後 recreate——會被卡住，必須等待或手動到 Pure UI 執行
`purevol eradicate`。

#### 修正
- **`snapshot_delete()` 在 destroy 前先把 snapshot rename 為
  `<orig-suffix>-pve-tomb-<unix-ts>-<pid>`**，原 suffix 立即釋放。
  Tombstone snapshot 仍進入 destroyed-pending、依陣列正常時程
  eradicate，只是用新 suffix。
- 使用 Pure 的 `PATCH /volume-snapshots` rename API——已對照 FA 2.x
  OpenAPI spec 驗證：body 的 `name` 欄位是**新的 suffix**（不是
  完整新名），來源 Volume 關聯保留。
- 處理的邊界情境：suffix 加上 tombstone 後超過 64 char 跳過 rename
  並 warn、已有 tombstone 標記的 suffix 不會二次 rename（idempotent
  retry）、destroy 失敗時 rollback rename 回原 suffix 讓 PVE 端
  重試走得通。
- API 1.x 的 REST 介面不支援 snapshot rename，所以 tombstone 路徑
  僅限 API 2.x；1.x 走原本的直接 destroy 路徑。

### 低——Config backup volume 等 device 改用獨立較短的 timeout

Tracked in [#12]。Plugin 每次 snapshot 都建一個 1 MB 輔助 Volume
存 VM/CT config（給 `pve-pure-config-get` 災難復原用——非必要）。
之前等這個 Volume 的 multipath device 時用的是
`pure-device-timeout`（預設 60 秒）。當 multipath 部分斷線時，
每次 snapshot 都會明顯卡 60 秒才出現「Config backup device not
found, skipping config backup」warning，雖然 warning 是非致命，
但卡 60 秒體感很差。

#### 修正
- **新增 storage 參數 `pure-config-backup-timeout`**（整數 `5..60`，
  預設 `15`）。專門給 config-backup Volume 用的較短 wait。multipath
  降級時 snapshot 操作會在 ~15 秒返回而非 ~60 秒。
- Warning 訊息改寫，明確說明 skip 是非致命、列出 WWID、指向新參數
  方便長期 fabric 偏慢的客戶調整。

### 低——postinst 加上必要外部執行檔的檢查

Tracked in [#9]。Plugin 的 Depends 宣告
（`multipath-tools`、`open-iscsi`、`sg3-utils`、`psmisc`）是正確的，
但 `dpkg -i ...` 不會強制安裝相依——套件可能落在沒有 `multipathd`／
`iscsiadm`／`kpartx` 的系統上，第一次儲存操作就會以
`open3: exec of /sbin/multipathd reconfigure failed: No such file
or directory` 這種看起來像內部錯誤的方式失敗。

#### 修正
- **postinst 在缺少必要執行檔時拒絕完成 `configure`。** 檢測的
  binary：`multipathd`、`multipath`、`kpartx`、`iscsiadm`、`sg_inq`、
  `blockdev`。套件會進入 configured-failed 狀態，並印出多行明確
  錯誤訊息引導操作者執行 `apt --fix-broken install`（從 `dpkg -i`
  恢復）或 `apt install ./*.deb`（從頭以正確方式安裝）。
- **README 與 README_zh-TW 的 Installation 段落**改為以
  `apt install ./*.deb` 為首選，並明確警告**首次安裝避免**用
  `dpkg -i`。

[#9]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/9
[#11]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/11
[#12]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/12

---

## [1.1.17] - 2026-05-13

### 中——Pod 容量 `used` 改採 provisioned 配置量（對齊 Pure 配額強制邏輯）

`get_managed_capacity()` 對 pod-backed storage 的 `used` 改為以
`space.total_provisioned`（pod 內所有 Volume size 加總）為主，
不再以 `space.virtual`（host 寫入 bytes）為主。

#### 為何採用此指標
Pure pod quota 在 allocate 階段是對 `total_provisioned` 強制——這
是陣列實際會拒絕分派的依據。Pure UI pod 詳細頁面最顯眼的「Size」
指標也是這個數字，所以回報值與操作者在陣列端看到的一致。

`virtual` 指標反映 guest 實際寫入磁碟的量，是有用的數字但**無法
表達剩餘可分派空間**。一個 2 TB 配額的 pod 裡放著一個 2 TB 的
thin volume、即使 guest 完全沒寫任何資料，陣列仍會拒絕新的
allocation；`used = total_provisioned` 才能在容量條上反映這個事實。

#### Fallback chain（形狀不變）
`total_provisioned` → `virtual` → `total_physical` → `total_used`。
順序改成 total_provisioned 優先；舊版 Purity 若沒有 total_provisioned
仍會依序回退到原本的次要指標。

#### 升版後 operator 可見的差別
Pod storage 的 `used` 數字可能會跳升、反映 provisioned 配置量而非
寫入量。PVE 容量條會跟 Pure UI 對 pod 顯示的「Size」用量一致，也跟
陣列下次 allocate 時會准許的剩餘空間一致。

每顆 Volume 在 PVE GUI 上顯示的大小不變——`list_images` 與
`volume_size_info` 一直以來都讀 Volume 自己的 `provisioned` 欄位
（Pure 端的 Volume size），那邊本來就是對的。

[#7]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/7

---

## [1.1.16] - 2026-05-13

### 高——`pve-pure-config-get` restore 模式沒跟上 v1.1.15 的 tombstone

v1.1.15 推完隨即在 code review 發現的問題。Plugin v1.1.15 改了
`volume_delete`，在 destroy 之前先 rename Volume 為
`<orig>-pve-tomb-<unix-ts>-<pid>`。災難復原工具
`pve-pure-config-get` 在 restore 模式（`--restore`）下會去查 Pure 的
destroyed-volumes 列表、找到 config 備份 Volume 與 VM 的 disk
Volumes、把它們 recover 並重建這台 PVE 上的 VM config。v1.1.15
之後，工具找到的 destroyed Volume 全部帶 tombstone 字尾，導致兩個
問題：

#### 壞掉的部分
1. **顯示（視覺問題但混淆）**：`decode_config_volume_name` 的
   greedy `(.+)$` 把 `-pve-tomb-<ts>-<pid>` 字尾整段抓進
   snapname。restore picker 顯示
   `snap1-pve-tomb-1747000000-12345` 而非 `snap1`，難以辨認是哪
   一個 snapshot。
2. **功能（嚴重）**：recover 回來的 disk Volume 在 Pure 上仍叫
   tombstone 名（例如
   `pve-pure1-100-disk0-pve-tomb-1747000000-12345`），但工具寫到
   `/etc/pve/qemu-server/<vmid>.conf` 的 VM config 引用的是 PVE
   volid（`vm-100-disk-0`），plugin 的 `pve_volname_to_pure` 會
   把它 map 回原名（`pve-pure1-100-disk0`）。VM 啟動時 PVE 用
   原名找 disk → 找不到（disk 在 tombstone 名下）→ 還原好的 VM
   啟動失敗 "volume does not exist."。

#### 修正
- **`pve-pure-config-get` 顯示前先剝掉
  `-pve-tomb-<ts>-<pid>` 字尾**再丟給 `decode_config_volume_name`。
  Snapname 顯示乾淨。
- **`volume_recover` 之後立即把 tombstone Volume rename 回原名**，
  讓 Volume 在 Pure 上的名稱就是還原後 VM config 期待的名字。
  Config 備份 Volume 與每一個 recover 回來的 disk Volume 都套用。
- **Rename-back 衝突處理**：原名已被另一個 alive Volume 佔走
  （罕見——只在 operator 已經重建了該 VM、現在想復原舊版本時
  發生），工具會 **abort restore** 並印出明確錯誤，列出衝突的
  tombstone 名稱、給兩個復原方向（手動 rename + 清掉衝突 Volume，
  或改用不同 VMID 復原）。
- **工具也改用 v1.1.14 的 `storeid_to_pure_prefix` helper**，不再
  自己 inline duplicate sanitize+底線轉換。讓帶 dot 的 storage ID
  在整個 restore 流程也走得通（補齊 #6 漏網之魚）。

#### Build / CI
- **`make test` 現在也對 `bin/pve-pure-config-get` 做語法檢查**，
  跟 library 模組一視同仁。工具 Perl 語法錯誤現在會讓 build
  跟新的 [GitHub Actions deb-build workflow](.github/workflows/build-deb.yml)
  （v1.1.13 加的）失敗，不會等到 operator 在真實災難下才發現。

#### Operator 可見的差別
1.1.16 之前如果遇到要用 v1.1.15+ destroy 過的 Volume 做災難復原，
還原好的 VM 會悄悄啟動不了，要手動到 Pure 端 rename Volume。
1.1.16 之後行為跟 v1.1.15 之前的 disk 復原一模一樣，直接動。

---

## [1.1.15] - 2026-05-13

### 中——Pure destroy 後保留原名 24h 卡住同名重建，改用 pre-rename tombstone

**@pulipulichen** 回報（[#8]）。

PVE VM 磁碟刪除後，Pure 端 Volume 進入「destroyed-pending」狀態，**Pure 預設會保留該 Volume 名稱直到陣列的 eradication delay（預設 24 小時）**。這段期間建立同名 Volume 會失敗。對於需要 delete-and-recreate 同一個 disk 的 PVE 工作流（重建相同 VM ID、snapshot／restore 循環等），症狀是「無法建立」錯誤，只能等 24 小時或手動到 Pure UI eradicate。

**注意**：這是 Pure **故意的設計**——destroyed-pending 視窗是讓 admin 可以用 `purevol recover` 撤銷誤刪。不是 Pure bug。Plugin 的責任是用對的方式呼叫 API 避免不必要的長時間佔用名稱。

#### 修正
- **[中] `volume_delete()` 在 destroy 之前先 rename Volume 為
  `<orig-name>-pve-tomb-<unix-ts>-<pid>`**。原名 rename 成功後立即釋放；tombstone Volume 仍以 suffix 後的名稱進入 destroyed-pending、依陣列正常時程 eradicate。Operator 在 Pure 的 Destroyed Volumes 列表透過 `-pve-tomb-` 標記可一眼識別。

#### Tombstone 路徑處理的邊界情境
- **Pod 內 Volume**（`pod::vol`）：rename 時保留 `pod::` 前綴——Pure 不允許跨 pod rename。63 char 限制只算 `::` 後的部分。
- **加 tombstone 後超過 63 char**：跳過 rename、走原名 destroy（接受 24h 名稱保留，比 truncation collision 安全）+ warn 解釋為什麼這個 Volume 名稱被保留。
- **已是 tombstone 的名字**：偵測到名稱含 `-pve-tomb-<digits>` 標記（例如前次 destroy 失敗留下的 tombstone 重新 destroy）就跳過 rename，避免遞迴變成 `-pve-tomb-X-pve-tomb-Y`。
- **跨節點併發 destroy 同個 Volume**：PID suffix 保證不同行程在同一個 wall-clock 秒內產生不同的 tombstone 名稱、不會撞名。
- **WWID 保留**：Pure rename 不會改 Volume WWID，plugin 的 WWID tracking JSON 以 WWID 為 key、不以名稱為 key，所以**不需要更新追蹤檔**。
- **caller opt-out**：`volume_delete($name, tombstone => 0)` 允許完全跳過 rename。（多數情況不需要：上面的 regex 已防 accidental double-tombstoning。）

#### Destroy 失敗時的 rollback
如果 rename 成功但後續 destroy 失敗（例如 Volume 上掛了未預期的 protection group、pod 處於 degraded 狀態、暫時性 API 錯誤），`volume_delete()` 會把 Volume **rename 回**原名後再把 destroy 錯誤往上拋。這樣回到了呼叫前的狀態，operator 重試走 PVE 正常流程就行。

沒有這個 rollback 的話，rename 成功 + destroy 失敗會留下 tombstoned-but-alive Volume；下一次 `free_image` 重試會找原名但找不到（Volume 已經改名了）、回 "not found"、必須到陣列手動清理。

Rollback 是 **best-effort**：如果連 rollback rename 也失敗（罕見，代表陣列層級故障），會 log tombstone 名稱讓 operator 可以到 Pure UI 手動清。

#### 與此修法**無關**的路徑
**PVE snapshot rollback**（倒回快照）走的是 `volume_overwrite()`，透過 `POST /volumes?names=X&overwrite=true` 原地覆寫現有 Volume 的內容——沒有任何 Volume 被 destroy，所以**不會進入 tombstone 路徑**。

[#8]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/8

---

## [1.1.14] - 2026-05-13

### 高——multipath 部分斷線下，VM 含記憶體快照會拖垮整個 PVE 管理層

**@pulipulichen** 回報（[#5]）並提供關鍵診斷線索：同一台節點 CT
快照、VM 不含記憶體快照都正常，**只有 VM 含記憶體快照**會觸發，
且只在 multipath 已經部分斷線時（4 個 portal、2 條 path 斷掉）才
出事。一次 snapshot 之後，pvedaemon／pvestatd 漸進失能，最終 Web
UI 對所有 storage 都顯示 `?`，只能強制重開機恢復。

**根因**：VM 含記憶體快照會在陣列上**建一個 VMSTATE Volume** 儲存
RAM dump，建好之後 host 端要做 iSCSI rescan + 等 multipath 看到
這個新 device。原本的 `rescan_sessions()` 走的是
`iscsiadm -m session --rescan`——**單一次 iscsiadm 呼叫嘗試 rescan
所有 active session**，包括已斷線的那些。死掉的 session 會把 SCSI
command 塞進 SCSI bus 等 kernel timeout（每條死 path 通常 30 秒以
上），iscsiadm 父行程在我們設的 60 秒 wrapper timeout 被殺掉，但
留下 **D-state 子行程**（無法 SIGKILL ——詳見 CLAUDE.md 教訓 #3）。
每次 pvestatd 輪詢（10 秒）又 fire 一次同樣的 rescan，D-state 累
積到管理層撐不住為止。

CT 快照與「VM 不含記憶體」快照不會重現是因為**不需要建新 Volume、
不會走 host 端 activation 路徑**——純儲存層操作。

#### 修正
- **[高] `rescan_sessions()` 重寫**：
  1. 透過 `/sys/class/iscsi_session/` 列舉 session（kernel 維護
     的 sysfs、不會被 iscsiadm hang 影響），readdir 有 alarm 上限
  2. bounded sysfs read 讀每個 session 的 `state`，**state 不是
     `LOGGED_IN`**（FREE、REOPEN、FAILED 等）就跳過
  3. 對 LOGGED_IN session **個別 rescan**
     （`iscsiadm -m session -r <sid> --rescan`），每個 session 給
     10 秒 timeout（取代原本「所有 session 一次 60 秒」）
- 最壞情況的 D-state 子行程數量從「每次輪詢、每條死 path 都來一
  個、永遠累積」降為「每次呼叫、每個卡住的 LOGGED_IN session 最
  多一個、有上限」。
- 跳過 non-LOGGED_IN session 時會 warning 列出狀態（例如
  `session1=FREE, session2=REOPEN`），讓 operator 知道底層 iSCSI
  fabric 出狀況，而不只是看到管理層卡住的症狀。

#### 套用後在同樣 reproducer 上的預期行為
4 LIF Pure、2 條 path 斷、VM 含記憶體快照：
- rescan_sessions 只 rescan 2 條健康的 session，各自 <1 秒
- VMSTATE Volume 在 2 條健康 path 上出現、multipath 看到、snapshot
  完成
- pvestatd 輪詢不再累積 D-state 子行程
- Web UI 保持回應

---

### 中——storage ID 含 `.` 時 PVE Web UI 的 disk 列表會空白

**@pulipulichen** 回報（[#6]）。

加入 ID 為 `pure-plugin-5.111-pvepod2` 的 storage 後，PVE Web UI 上
這個 storage 的 disk 列表是空的，即使該 storage 上的 VM 仍在執行
且陣列端 Volume 確實存在。把 storage 重新命名為
`pure-plugin-5-pvepod2`（去掉點）就正常了。

**根因**：寫入路徑與讀取路徑的 sanitize 不對稱。

- `encode_volume_name()`（寫入）會先呼叫
  `sanitize_for_pure($storage)` 去掉 `.` 與其他非
  `[a-zA-Z0-9_-]` 字元，再 `s/-/_/g`。storage ID
  `pure-plugin-5.111-pvepod2` 變成 Volume 前綴
  `pure_plugin_5111_pvepod2`（點消失），實際存在陣列上的 Volume
  名稱是 `pve-pure_plugin_5111_pvepod2-<vmid>-disk<N>`。
- `list_images()`（讀取）以及 `PureStoragePlugin.pm` 內**六個別的
  pattern 建構處**全部只做
  `$san_storage = $storeid; $san_storage =~ s/-/_/g;` ——
  點還在！filter pattern 變成
  `pve-pure_plugin_5.111_pvepod2-*`，跟實際存在的 Volume 名稱永遠
  match 不到，`list_images` 回空陣列。

#### 修正
- **[中] 新 helper `Naming::storeid_to_pure_prefix($storeid)`**：執
  行與 `encode_volume_name` 一致的完整 transform（sanitize_for_pure
  +`s/-/_/g`）。export 出來讓所有建構 pattern 的呼叫者共用同一份
  正確邏輯。
- `PureStoragePlugin.pm` 內 7 處 inline 重複全部換成呼叫 helper。
- `Naming.pm` 內自己另外 3 處 inline 重複（encode_config_volume_name、
  pve_volname_to_pure 的 cloudinit 與 state 分支）也一起收攏到
  helper——日後 storage 名稱編碼規則若再改，只要動一處。

[#5]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/5
[#6]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/6

---

## [1.1.13] - 2026-05-11

### 高——Snapshot 倒回在 REST API 2.x 上沉默無作用

**@tgdfama1**（[#1]）與 **@pulipulichen**（[#2]）獨立回報。建立快照後
修改 Volume、再從 PVE UI 倒回，task 顯示成功但 Volume 內容**沒有**真的
還原——倒回後重啟 VM 仍能看到 snapshot 之後寫入的檔案。

**根因**：`volume_overwrite()` 使用 `PATCH /api/2.x/volumes` 並把
`source` 放 body。對照 FA 2.x OpenAPI spec，`PATCH /volumes` 是
**rename ／ destroy ／ modify** 端點，body 並不接受 `source` 欄位——
Pure 回 `No attribute specified.` 但 HTTP 200 帶空 body 給上層，PVE
task 層因此判定成功，實際 copy-over 從未發生。

#### 修正
- **[高] `volume_overwrite()` 從 `PATCH` 改為
  `POST /volumes?names=<target>&overwrite=true`**，`source` 放 body——
  與 `volume_clone()` 已經在用的同一個 POST 端點，加上 spec 定義給
  object-copy 用的 `overwrite=true` query 參數。`add_to_protection_group_names`
  與 `with_default_protection` 在 `overwrite=true` 時 spec 明確禁止，
  故此 path 不傳。

#### 重現步驟
1. 在 Pure-backed storage 建一個 VM 磁碟
2. 在 PVE 對 VM 建 snapshot
3. 開機、寫一個檔案、關機
4. PVE UI 右鍵 → 倒回該 snapshot
5. **修正前**：task 顯示 OK，但開機後 snapshot 之後寫的檔案還在
6. **修正後**：snapshot 之後寫的檔案已消失，Volume 內容正確回到
   snapshot 當時的狀態

---

### 中——Pod-backed Storage 在 thin Volume 一建好就顯示 100% used

**@pulipulichen** 回報（[#3]）。

v1.1.12 修好 Pod 配額讀取（讀 `Pod.quota_limit`）後，下一個露出來的
表面問題是：配額大小的 thin Volume 一建好（例如 2 TB pod 內建一個
2 TB Volume），即使 host 端零寫入，PVE 立刻顯示 storage 100% used；
但 Pure GUI 對同一個 pod 顯示「幾乎空的」。

**根因**：`get_managed_capacity()` 在 `//` fallback chain 中優先取
`space.total_provisioned`（所有 Volume size 加總）而非 `space.virtual`
（host 端寫入的 logical bytes）。當時的理由是「Pod 配額對
provisioned 強制」，但 operator 看到 PVE 100% / Pure GUI 0% 的落差
比想像中的「PVE 允許 over-allocate」風險更傷信任——而且如果真的
撞到配額，陣列在 allocate 階段會回明確錯誤，`translate_pure_error()`
也會把訊息攤給操作者。status() 不需要先悲觀化容量上限。

#### 修正
- **[中] `get_managed_capacity()` 的 fallback 順序重排**：優先取
  `virtual`（對齊 Pure UI 的 pod 用量顯示），再依序 `total_physical`
  → `total_used` → `total_provisioned`。PVE 的容量條現在會跟 Pure
  GUI 對 pod 的用量視圖一致。

---

### CI：手動觸發的 `.deb` build workflow

**@pulipulichen** 貢獻（[#4]）。

- **新檔 `.github/workflows/build-deb.yml`**——在 `ubuntu-24.04`
  runner 跑 `make test` + `dpkg-buildpackage -us -uc -b`，將產出的
  `.deb` 上傳成保留 30 天的 GitHub Actions artifact
- 只透過 `workflow_dispatch` 手動觸發（不自動推、不會動到 `releases/`）
- 對於想驗證 build 是否乾淨、又不想架 Debian 開發環境的貢獻者，
  以及想針對任一 branch 快速產 artifact 的 release 工程師都有用

[#1]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/1
[#2]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/2
[#3]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/3
[#4]: https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/4

---

## [1.1.12] - 2026-05-08

### 中——不再把 file-services 配額 Policy 誤當成 Pod block 配額讀

接續 v1.1.10 / v1.1.11 同一個現場：那次工單同時揭露了一個更根本的
事實——**Pure GUI 的 `Storage > Policies` 整個面板都是 FlashArray
Files／managed-directory 用的**，即使 GUI 讓你建 quota policy 時可
以指定 Pod，那也不是 block volume 的配額機制。Pure 內建五種 policy
類型全部都是 file-services：`autodir`、`nfs`、`smb`、`quota`、
`snapshot`。任何一條從這個面板建出來的 policy 一旦掛到 Pod 上，
Pure 就會把 Pod 標記成「附掛了 file-services policy」，之後所有
block volume create 都會被拒絕並回傳誤導性的：

```
Pure Storage API: Pod contains file systems or policies. (context: <podname>)
```

#### 因此這版要修兩件事

1. **v1.1.10 的 `pod_get_quota_limit` 會去走
   `/policies/quota` + `/policies/quota/rules`，把那個 policy 的
   `quota_limit` 當成 Pod block 配額回報。** 這個數值從來沒對
   block volume 生效——它只對 managed directory 的檔案用量生效。
   PVE 被告知的 cap 跟它實際關心的資源無關。v1.1.12 把這段走
   policy 的邏輯整段拿掉，`pod_get_quota_limit` 只讀
   `Pod.quota_limit`——那才是真正的 block-level Pod 配額欄位。

2. **v1.1.11 在 `volume_create` / `volume_clone` 加的
   `with_default_protection=false` 並沒有解掉現場的「Pod contains
   file systems or policies.」拒絕。** 該拒絕點在 Pure 內部比
   container default protection 還更上層；把這個參數設為 false
   並不會改變 Pure 的判斷。真正的解法在 Pure 端：把那條
   file-services policy 砍掉、改設 `Pod.quota_limit`。
   v1.1.11 加的這個參數**保留**（它本身是正確的防禦性修改——
   外掛由 `volume_snapshot` / `volume_overwrite` 自行管理 snapshot，
   本來就不依賴 Pure 的 default protection——拿掉只會徒增 churn），
   但不再宣稱它是這個情境的解。

#### 修正
- **[中] `pod_get_quota_limit()` 改為只讀 `Pod.quota_limit`。**
  v1.1.10 加的 80+ 行 policies/quota 巡訪程式整段拿掉。更精簡、
  更快（每次 poll 少 1 次 API call，多 policy 情境少 2 次），
  也不再回報誤導性的 cap。
- **README 與 README_zh-TW 的方案 A「Pod 加配額」區塊**現在明確
  列出設定 Pod block 配額的三種正確路徑——CLI（`purepod
  --quota-limit`）、REST API（`PATCH /pods` body `quota_limit`）、
  GUI（6.6+ Edit Pod）——並明確警告**不要**用 `Storage > Policies`
  設 Pod block 配額。錯誤訊息的字面與「砍 policy 並改設
  Pod.quota_limit」的恢復步驟都寫進去，讓操作者不必聯絡支援就能
  自行排除。

#### 現場端排除（不用改外掛）
任何之前用 Pure GUI 建過 quota policy、現在在建 Volume 時看到
`Pod contains file systems or policies.` 的操作者：

```
# Pure 端 CLI
purepolicy quota destroy <policy-name>
purepod setattr <pod-name> --quota-limit 2T

# 或走 REST（PVE Web UI Shell，使用 storage 已存的 API token）
DELETE /api/2.x/policies/quota?names=<policy-name>
PATCH  /api/2.x/pods?names=<pod-name>  body  {"quota_limit": <bytes>}
```

#### 變更檔案
- `lib/PVE/Storage/Custom/PureStorage/API.pm`：
  - `pod_get_quota_limit()` 重寫為只讀 `Pod.quota_limit`
- `README.md`、`README_zh-TW.md`：
  - 「方案 A——Pod 加配額」更新明確警告與三種正確設定路徑

---

## [1.1.11] - 2026-05-08

### 高——Pod 上掛了任何 Policy 後，建立／複製 Volume 全失敗

接續 v1.1.10 同一個 pod 配額現場：v1.1.10 修好之後，操作者按需求在
Storage > Policies 把 quota policy 掛到 pod 上，結果接下來建任何 VM
磁碟都會失敗：

```
Pure Storage API: Pod contains file systems or policies. (context: pvepod2)
```

錯誤點落在 `PureStoragePlugin.pm:1660` `alloc_image` 內的
`volume_create`。錯誤訊息誤導——實際上 pod 並沒有 file system，只有剛
掛上的 quota policy。

對照 FA 2.26 OpenAPI spec `POST /api/2.x/volumes` 的根因：

- `with_default_protection` query 參數預設為 `true`。
- 預設行為會把 **container default protection** 套用到剛建好的 Volume
  （容器在這裡指 pod；非 pod 時則指 array）。
- 一旦 pod 有任何 policy 附掛，Pure 就會拒絕對新 Volume 套用
  default protection，並回傳這條誤導性的「Pod contains file systems
  or policies.」錯誤。

外掛本身不依賴 Pure 的 default-protection 機制——PVE 端的 snapshot 由
`volume_snapshot` / `volume_overwrite` 自行管理——因此正確的修法是
明確選擇關掉它：

#### 修正
- **[高] `volume_create` 與 `volume_clone` 在 Volume 名稱帶 `pod::`
  前綴時，會在 `POST /volumes?names=…` query string 多加
  `&with_default_protection=false`。** 改在
  `lib/PVE/Storage/Custom/PureStorage/API.pm`：
  - `volume_create()` —— 名稱含 `::` 時自動附上參數
  - `volume_clone()` —— 同樣處理 pod 內 clone
- 非 pod Volume 刻意保持原行為，以保留使用者於 array-level 設定的
  `default_protections`。
- `volume_overwrite`（rollback）與 snapshot create 走的是另一個端點，
  不接受 `with_default_protection`，因此不需動。

#### 實際重現環境
Purity//FA 6.5.9，pod `pvepod2` 上掛了 2 TB 的 quota policy
`pvepodquota2`。`qm create 107 ... -scsi0 pure-storage:32` 在 API 層
失敗；`dpkg -i 1.1.11-1` 安裝後重跑同樣指令成功。

---

## [1.1.10] - 2026-05-08

### 中——Pod 配額（Quota）被忽略，容量回報跑成整個 FlashArray

當 Storage 以 `--pure-pod <name>` 建立時，PVE 儲存狀態面板顯示的容量是
**整個 FlashArray 全容量**，而不是該 Pod 的配額。例如 50 TB 陣列上設了
2 TB Pod 配額，PVE 顯示為 50 TB 全可用，操作者無從在配額用盡前得到任何
警示，直到陣列拒絕超量的 Volume 建立才會發現。

Pure FlashArray API 2.x 的 Pod 配額有**兩種設定路徑**，舊版程式碼
兩種常見情況都漏掉了：

- **(a)** Pod 物件本身有一個 `quota_limit` 欄位，由
  `purepod create --quota-limit` 或 `purepod setattr --quota-limit`
  CLI 設定（Purity 6.4.4+ 起）。舊版程式碼有讀這個欄位，**但**當配額
  是用下面的 Policy 機制 (b) 設定時，這個欄位會永遠保持 0——而 GUI
  走的就是 Policy 機制這條路。
- **(b)** 較新的 Purity 還允許建立 `policy_type='quota'` 的 Policy，
  Policy 物件本身有一個 `pod` 欄位指到對應的 Pod；真正的
  `quota_limit` 由 `/policies/quota/rules` 上的 Rule 攜帶。
  Storage > Policies UI 走的就是這條路。**重點是這個機制不會把
  cap 寫回 Pod 的 `quota_limit` 欄位**——只讀 Pod 物件永遠看到 0。

原本的程式因此永遠拿到 `quota = 0`，直接走 `if (quota > 0)` 之後的
fallback 分支，回傳 `array_space()` 給的全陣列容量。

> ⚠ 本修正最初的草稿曾試圖用 `/policies/quota/members` 並加上
> `member.resource_type='pods'` filter——這對 pod 是**錯的**：依
> Pure API 2.26 spec，這個 members 表只用於將 quota policy 綁到
> **managed directory**。Pod 配額 policy 的關聯是讀 policy 物件
> 自己的 `pod` 欄位來判斷。

實際重現環境：Purity//FA 6.5.9，Pod `pvepod` 上掛了一個 quota policy
`pvepodquota`（2 TB rule、enabled、enforced=false），Pod 內已有一個 2 T
Volume。PVE 顯示為陣列全容量、used 0%。

#### 修正
- **[中] `get_managed_capacity()` 改為兩種設定路徑都查。**
  新增 helper `API::pod_get_quota_limit($podname)`：
  1. 讀 Pod 物件本身的 `quota_limit`（路徑 a）
  2. `GET /policies/quota?filter=pod.name='X'` —— 列出 `pod` 欄位
     指到本 Pod 的所有 quota policy（路徑 b）
  3. `GET /policies/quota/rules?policy_names=Y,Z` —— 取得這些 policy
     的所有 rule（使用 FA 2.26 spec 文件化的 `policy_names` array
     參數，不再用 `or` 串接的 filter）
  4. 在 (a) 與 (b) 所有 rule 之中取**最小的正值 `quota_limit`**——
     最嚴格的 cap 與陣列實際強制配額時的判斷一致
- 處理的邊界情境：
  - 一個 policy 多 rule、一個 Pod 多 policy → 全部一起比，取最小
  - `enabled=false` 或 `destroyed=true` 的 policy → 整個忽略
  - `enforced=false`（軟性、僅通知）rule → 仍計入，使用者既然刻意
    建立了配額，PVE 配置決策就應尊重該意圖
  - 舊版 Purity 對這幾個端點不支援 filter 參數 → 改用無 filter
    列舉 + Perl 端比對
  - 端點 404（舊版 Purity 沒這端點）、權限 token 403、filter 語法
    不支援 400 → warning + fall through 回全陣列容量（status() 輪詢
    絕不 croak）
  - Pod 名稱含 `'` 或 `\`（會破壞 filter 字面量）→ 跳過並 warning
  - API 1.x → 跳過（Pod 配額為 API 2.x 才有的功能）
- **Pod `used` 容量改用 `total_provisioned`**（依 API 2.26 Pod
  space schema，這是 Pure 配額實際計量的指標），取代原本的
  `total_used`（資料縮減後的實體用量）。當 `total_provisioned`
  不存在時依序回退到 `virtual` / `total_used` / `total_physical`。
  原本邏輯下，2 T Pod 內剛建一個 2 T Volume，PVE 仍會顯示 used 0%，
  但陣列端其實已經 100% 滿——下一次配置就會被陣列拒絕。

#### 變更檔案
- `lib/PVE/Storage/Custom/PureStorage/API.pm`：
  - `pod_get_quota_limit()` —— 新 helper，同時讀取 Pod 物件本身的
    `quota_limit` 並巡訪 `policies/quota` 與 `policies/quota/rules`，
    每一個 API 呼叫都用 eval 包覆錯誤處理且帶無 filter fallback
  - `get_managed_capacity()` —— 改呼叫新 helper；`used` 改採
    `total_provisioned`

---

## [1.1.9] - 2026-05-05

### 嚴重——無法連通的 iSCSI portal 會卡住 activate_storage() 並讓 Web UI 整個轉圈

當 Pure FlashArray 對外提供的 iSCSI LIF 數量多於本機 PVE 實際能連通的
數量（線路不對稱、控制器埠在另一網段、fabric 部分故障），
`activate_storage()` 會把 `iscsi_get_ports()` 回傳的每一個 LIF 都丟給
`iscsiadm -m discovery` 與 login。每一個無法連通的 LIF 都會吃完整的
iscsiadm timeout——discovery 30 秒、login 最多 60 秒——即使外層 eval
不會 die，整個迴圈仍會被卡住。實際案例為：陣列 4 個 LIF、其中 2 個
不通，`pvesm add purestorage` 會阻塞 60 秒以上才回傳，且之後每一輪
`pvestatd` 輪詢都會重新走一次同樣的列舉，導致 Web UI Status 面板永遠
停在「Loading...」，連帶拖累節點上其他儲存。

實際重現環境：4 個 LIF 的 Pure（每控制器 2 個 LIF，分兩個網段）搭配
2 節點 PVE，但實體線路只走得到其中一個控制器所在的網段。`pvesm add`
回傳時帶兩行 `Failed to connect to portal ...: Command timed out
after 30s`，行號落在 `PureStoragePlugin.pm:1352 (discover_targets)`。
唯一恢復方式是移除該 Storage。

#### 修正
- **[高] `activate_storage()` 現在會在 iscsiadm 之前先做 TCP 預探測。**
  新增 helper `ISCSI::probe_portal($ip, $port, timeout => $t)`，
  以有界的 `IO::Socket::INET` connect 試打 portal；若在
  `pure-portal-probe-timeout` 秒內沒回應就跳過該 portal、只留一行
  warning，不再讓 iscsiadm 自己 timeout。同樣的 probe 也套到
  `alloc_image()` 為 state/cloudinit Volume 重建 session 的次要 login
  區塊。
- **`activate_storage()` 在「沒有任何 portal 可連通」時改為 fail-fast。**
  過去會傳回成功讓 `status()` 對著一個沒有可用路徑的 Storage 永遠輪詢，
  現在會直接 `die`，錯誤訊息明確指引使用者檢查網路/zoning，或使用
  `--nodes` 把 Storage 綁到能連到陣列的節點。

#### 新增
- **新增 Storage 設定 `pure-portal-probe-timeout`**（整數，0..30，預設
  2）。設為 0 可停用 pre-check，回到 1.1.8 行為；若儲存網路 TCP 建立
  延遲合理超過預設值可調高。可透過
  `pvesm set <storeid> --pure-portal-probe-timeout <n>` 逐個 Storage
  調整。

#### 架構備註
這屬於 sibling-pattern 稽核範疇：plugin 中所有可能因網路故障而卡住的
路徑早已有界保護（`_run_cmd` timeout、`sysfs_read_with_timeout`、
1.1.8 為 glob 加的 alarm 包裝）。Portal 列舉是 `activate_storage()`
最後一條無界路徑；過去 plugin 一直假設「陣列回報的 LIF 都連得到」，
此假設在實驗室與 CI 成立，但在實務 cabling 不一定成立。

---

## [1.1.8] - 2026-04-26

### 來自本作者相關專案 NetApp v0.2.9 的 sibling-pattern 稽核

本作者另一個專案 jt-pve-storage-netapp v0.2.9 針對兩個問題出了修正，
引發本專案進行 sibling-pattern 稽核。其中兩個在此程式碼有對應的 bug，另外三個沒有（Pure 直接以 Volume 名做
identifier，不會踩到 create-then-lookup 的 eventual consistency 視窗；
`alloc_image` 早已是有界 retry loop；`multipath -F` 已是 forbidden
pattern）。

#### 修正
- **[中等] `_cleanup_orphaned_devices()` 現在會先驗證本機 multipath 裝置
  確實消失才 untrack WWID。** 過去該函式在 `cleanup_lun_devices()` 之後
  無條件呼叫 `_untrack_wwid()`，即使清理失敗也照樣 untrack。在 Volume 已從陣列
  刪除的情況下，Phase 1 無法重新 import 該 WWID，導致一次清理失敗
  （kpartx holder、multipathd 故障、dmsetup busy）就會悄悄留下殘留裝置，
  之後任何 status() 輪詢都找不到它。此修正鏡像 `free_image()` 在 1.1.x
  已採用的 conditional-untrack 模式：若 `get_multipath_device($wwid)`
  仍能回傳路徑，保留 WWID tracking 以便下一輪重試；只在驗證消失後才
  untrack。

- **[低] `glob("/dev/disk/by-id/...")` 呼叫加上 5 秒 alarm 保護**，影響
  `Multipath::get_device_by_wwid()`、`ISCSI::wait_for_device()`、
  `ISCSI::get_device_by_serial()`。`get_device_by_wwid()` 在 glob 之後的
  `-b` stat 會解析 symlink 到 `/dev/sd*` 或 `/dev/dm-*`；當 multipath
  裝置所有路徑都失效且 `queue_if_no_path` 仍生效時，這個 stat 會掉進與
  `vgs`、`lvs` 相同的 kernel block-layer wait。模式與既有的 `_run_cmd`、
  `sysfs_read_with_timeout` 一致。

---

## [1.1.7] - 2026-04-11

### 重大 — kpartx partition holder 擋住所有 Volume 刪除

每個裝了作業系統的 VM 磁碟都有 GPT/MBR 分割表。Linux kernel 會自動掃描
multipath LUN 並透過 kpartx 建立 partition dm 裝置。這些 partition 裝置在
`/sys/block/<dm-N>/holders/` 中出現。1.1.2 的 `is_device_in_use()` 修正把
**所有** holder 都視為「使用中」並擋住刪除 — 對 LVM holder 而言正確
（資料遺失防護），但對 bare kpartx partition 而言過度（被動的 kernel 產物，
主機端沒有任何東西在使用）。這讓**所有裝了 OS 的 VM 磁碟在 Pure 儲存上都
無法刪除**。不是邊界情境 — 是所有正式環境 VM 的正常情況。

#### 修正
- **[重大] `is_device_in_use()` 現在會區分 bare kpartx partition 與真正的
  holder。** 對每個 holder：
  - 檢查 dm-name 是否符合已知 kpartx pattern（`*-part1`、`*p1`、`*1`、
    `sd*1`）或有 kernel `/sys/block/<h>/partition` flag
  - 若是 partition：檢查是否有 sub-holder（上面的 LVM/dm-crypt）、是否被
    mount（`/proc/mounts`，同時檢查 `/dev/dm-N` 與 `/dev/mapper/<name>`
    兩種路徑）、是否被 swap（`/proc/swaps`）
  - 若**全部** holder 都是 bare partition 且沒有 sub-holder/mount/swap →
    安全忽略，允許刪除
  - 若**任何** holder 不是 partition，或任何 partition 有
    sub-holder/mount/swap → 仍然擋住（資料遺失防護不變）
- **[高] `cleanup_lun_devices()` 現在在嘗試移除 multipath map 之前先執行
  `kpartx -d <device>`。** 沒有這步，partition holder 裝置會讓
  `multipathd remove map` 與 `multipath -f` 失敗。
- **[中] `get_device_usage_details()` 不再把 kpartx partition dm-name 誤解
  為 LVM VG 名稱。** dm-name `3624a9370...-part1` 過去會被解析為 VG
  `3624a9370...` LV `part1`。現在會先檢查 partition pattern 並排除。
- **[低] orphan 警告 cooldown。** `_cleanup_orphaned_devices` 的 Phase 3
  untracked 裝置警告現在用 per-WWID flag file 限制為每個 WWID 每小時最多
  一次。過去 pvestatd 每 10 秒 `status()` 輪詢會讓相同警告每 10 秒重複。

---

## [1.1.6] - 2026-04-10

### postinst 必須 reload 所有 PVE 服務 + LVM global_filter 偵測

來自相關專案 jt-pve-storage-netapp Incident 9 (pvestatd 未 reload) 與
Incident 10 （升級版 PVE 節點上主機 LVM 自動啟用 guest VG) 的兩個問題。

#### 修正
- **[重大] postinst 現在會在安裝後 reload pvedaemon、pvestatd、以及
  pveproxy。** 過去的版本**不會** reload 任何 PVE 服務，代表含舊 bug
  的程式碼會一直留在記憶體中無限期執行。特別是 pvestatd 每 10 秒
  輪詢 `status()` — 若舊程式碼觸發 D-state 子行程 （例如 1.1.5 之前
  的 SCSI host scan bug 在 HPE 硬體上）,D-state 行程會不斷累積，直到
  硬體 watchdog 或手動重新開機介入。

  從 `systemctl restart` 改為 `systemctl reload` (SIGHUP）。若舊程式碼
  已經產生 D-state 子行程，`restart` 的 stop phase 會卡在等待無法
  kill 的行程。`reload` 發送 SIGHUP，讓 `PVE::Daemon` 以 `re-exec()`
  自己載入新程式碼，完全跳過 stop phase。
- **[高] postinst 現在會檢查 `/etc/lvm/lvm.conf` 是否有
  `global_filter`，並在缺少時警告。** 在從 PVE 7/8 升級到 9 的節點上，
  舊的 `lvm.conf` 缺少排除 device-mapper 和 multipath 裝置免於 LVM
  掃描的 filter。主機 LVM 會自動啟用 guest VM 磁碟內的 VG （那些是以
  multipath 裝置形式呈現的原始 LUN)，在 multipath 裝置上方建立
  holder dm 裝置。這些 holder 讓 `is_device_in_use()` 正確擋住
  `free_image()` 的刪除，但舊版錯誤訊息無法讓操作員自行診斷。
- **[高] `free_image()` 現在在 `is_device_in_use()` 擋住刪除時提供
  詳細的使用狀態資訊。** `Multipath.pm` 新增的
  `get_device_usage_details()` helper 會列舉 holder 裝置名稱、
  dm-name，從 dm-name 慣例偵測 LVM VG 名稱，並說明根本原因
  （升級版 PVE 節點上的主機 LVM 自動啟用） 以及精確的修復方式：
  `vgchange -an <vg>` 立即停用，`lvm.conf` 中設定 `global_filter`
  做長期修正。

---

## [1.1.5] - 2026-04-10

### 重大 — `rescan_scsi_hosts()` 可能在 HPE / Dell / Lenovo HBA 上掛起

自 1.0.0 起就存在的潛在 bug，在第一位客戶把外掛部署到 HPE ProLiant、
Dell PERC、Lenovo ThinkSystem 或任何同時有 SAS HBA / 硬體 RAID 控制器
與 iSCSI 卡的伺服器上就會浮現。**所有更早版本都受影響。強烈建議升級。**

#### 修正
- **[重大] `rescan_scsi_hosts()` 過去會迭代 `/sys/class/scsi_host/`
  下的每一個項目，包含非 iSCSI 的 host。** 對 HPE Smart Array 控制器
  (smartpqi 驅動）、Dell PERC (megaraid_sas) 或 LSI HBA (mpt3sas) 的
  scan 檔案寫入 `"- - -"`，會觸發驅動端的完整 target 重新掃描，在
  kernel 中**進入 D-state 達 600+ 秒**。`sysfs_write_with_timeout()`
  保護父行程不被阻擋，但**處於 D-state 的子行程無法被 SIGKILL 收回**,
  而且它會持有 kernel scan lock 直到驅動完成，造成後續每個 VM 操作都
  發生連鎖的 config-lock timeout，再加上 `pvedaemon` 重新啟動會掛起
  必須強制重新開機。

  修法：把 host 清單來源從 `/sys/class/scsi_host/` 改為
  `/sys/class/iscsi_host/`。`scsi_transport_iscsi` 這一層會在任何
  iSCSI 驅動呼叫 `iscsi_host_alloc()` 時把該 host 註冊到這裡，不論
  底層是 `iscsi_tcp`、`iser`、`bnx2i`、`qla4xxx`、`qedi`、`be2iscsi`、
  `cxgb3i`、`cxgb4i`、或任何未來的 iSCSI 驅動。非 iSCSI 驅動絕對
  不會在這裡註冊，所以迭代這個 class 既完整又安全。

  在實機上驗證 （含 8 個 scsi_host:host0-3 非 iSCSI、host4-7 iSCSI):
  `strace` 確認修正後只會對 host4-7 寫入。修正前則會對全部 8 個寫入。

  **教訓：** Timeout 保護涵蓋的是父行程，不是 kernel。對於會持有
  kernel lock 的 sysfs 寫入，正確的修法是「一開始就不執行該操作」，
  而不是「對該操作做 timeout」。
- **[高] `FC.pm rescan_fc_hosts()` 使用 bare `open()`** 寫入
  `/sys/class/fc_host/<host>/issue_lip` 與
  `/sys/class/scsi_host/<host>/scan`。SCSI scan 迴圈本來就只對 FC
  host 過濾 （透過 `get_fc_hosts()` — 沒有 Bug 1 風險），但 bare
  `open()` 代表 HBA 卡死時父行程也會卡住。修法：把兩處寫入都改走
  `sysfs_write_with_timeout()`，與 `Multipath.pm` 中已有的保護一致。

#### 新增
- **`API.pm` 中的 `translate_pure_error()` helper**，把 Pure FlashArray
  原始 API 錯誤訊息轉成對操作員友善的訊息。1.1.5 之前，操作員碰到
  陣列 Volume 數量上限會看到 `Maximum number of volumes is reached`，完全
  沒有任何指引。1.1.5 之後會看到一段說明：碰到哪個上限、為什麼
  「destroyed 但尚未 eradicate 的 Volume」會占用配額、以及如何恢復。
  比對 Pure 已知的上限錯誤訊息：per-array Volume 數量、per-volume 快照
  數量、host 連線數量、protection group 數量、容量耗盡、API rate
  limit。未知的錯誤照原樣傳遞。

  套用在最常見的 die 點：`alloc_image()`、`clone_image()`、
  `volume_snapshot()`。

---

## [1.1.4] - 2026-04-09

### 1.1.3 後內部深度稽核又找到 6 個 bug

套用「同類模式」稽核原則 （每個 bug 修正都觸發全程式庫搜尋同一反模式）
到所有清理路徑、`/sys/block` 存取、以及 API 版本分歧點。**建議用 1.1.4 而非 1.1.3** —
API 1.x normalisation 問題對使用 Pure REST API 1.x 的用戶屬 HIGH 等級。

#### 修正
- **[HIGH] `volume_get_connections()` 沒有正規化 API 1.x 的回傳格式。**
  Pure REST 1.x 回傳
  `[{ host => "h1", lun => 1, name => "myvol" }, ...]`，其中
  `name` 欄位是**Volume**名，不是 host 名。2.x 分支已經正規化為
  `{ name => "<host>" }`。所有 caller (`free_image`、
  `_disconnect_from_all_hosts`、`_backup_vm_config`、
  `_cleanup_orphaned_temp_clones`、`_cleanup_temp_snap_clone`、
  `alloc_image` orphan-cleanup) 都迭代 `$conn->{name}`，在 1.x
  上拿到的是**Volume 名**。後續的 `volume_disconnect_host($vol,
  $conn->{name})` 把 Volume 名當作 host 引數傳入，在 eval 內 silent
  失敗。**結果：在 API 1.x 上每個 disconnect 呼叫都是 no-op,
  殘留 host 連線永遠留著，而每個 `volume_delete` 清理都走 Bug E
  ghost-LUN 失敗模式。** 修法：在
  `volume_get_connections()` 的 API 1.x 分支正規化為相同的
  `[{ name => "<host>" }]` 形狀，並 fallback 至 `host_name` 與
  `name` 欄位。
- **[HIGH] `path()` 臨時 clone 的 connect 失敗有兩個 bug 串在一起**:
  (a) Bug E 模式 — `volume_delete($temp)` 沒先 disconnect,
  (b) `$@` 被覆寫 — 內部清理 eval 重設 `$@`，所以後續
  `die "...$@"` 顯示的是清理錯誤而非原本的 connect 錯誤。兩者
  都修：先 `$connect_err = $@` 保存，再呼叫
  `_disconnect_from_all_hosts`，然後 `volume_delete`，最後用
  保存的 error die。
- **[HIGH] `_backup_vm_config()` 的 connect 失敗有相同的 Bug E
  模式**:`volume_connect_host` 失敗 → `volume_delete` 沒 disconnect
  → 陣列上殘留 host 連線。修法：在 connect-fail 分支與
  「Cannot get WWID」分支的 `volume_delete` 之前都呼叫
  `_disconnect_from_all_hosts`。
- **[MEDIUM] `clone_image()` 缺 disk-id collision retry** —
  與 1.1.0 前的 `alloc_image` 同一 TOCTOU 視窗。兩個並行
  `qm clone` 對同一來源 VM 可能都從 `_find_free_diskid` 拿到相同
  diskid，一個會以 "already exists" 失敗。修法：在
  `volume_clone` 呼叫外加 5 次重試迴圈。
- **[LOW] `rescan_scsi_device()` 用 `basename()` 而非
  `_resolve_block_device_name()`。** 目前所有 caller 都傳
  `/dev/sdX` 所以這個 bug 是潛在的，但作為 exported helper,
  未來呼叫者若傳 `/dev/mapper/<wwid>` 就會 silent 失敗。為了
  與 Multipath 模組其他函式一致，做防禦性修正。
- **[LOW] `_backup_vm_config()` 對 `mkfs.ext4` / `mount` / `umount`
  使用 bare `system()`。** 1MB Volume 是剛分配的，正常情況下裝置是
  健康的，但若 multipath 卡死，`mount` 會進入 D state。將 4 處
  全部換成 `PVE::Tools::run_command(..., timeout => 30)`，並在
  `umount` 之前加上明確的 `sync`。

---

## [1.1.3] - 2026-04-09

### 主動同類模式稽核發現的 3 個 bug

1.1.2 修了 4 個 bug 之後，相關專案 jt-pve-storage-netapp 的維護者主動稽核了所有
出現相同 bug 模式的位置。又找出 3 個。Pure 外掛全部都中。**建議用
1.1.3 而非 1.1.2** — Bug E 即使不走 resize / rollback 路徑，單純透過
`clone_image` （或 `alloc_image`) 的失敗路徑也能造成節點掛起。

#### 修正
- **[HIGH] Bug E — `alloc_image()` 與 `clone_image()` 失敗清理路徑
  在呼叫 `volume_delete()` 前沒有先 disconnect Volume 的所有 host 連線。**
  `_connect_to_all_hosts()` 在 per-node 模式下會迭代每一台叢集 host;
  若它在 host 1..K 成功、在 K+1 失敗，清理執行時 Volume 仍然連著 K 個 host。
  Pure （與 ONTAP 不同） 會直接銷毀仍在連線中的 Volume，但**殘留 host 連線
  紀錄**會讓其他叢集節點上的 iSCSI rescan 發現幽靈 LUN，進而變成
  殘留 multipath 裝置。配上 `defaults` 區塊中的 `no_path_retry queue`
  — 與 1.1.0 起源的正式環境掛起事故同一根本原因。修法：新增
  `_disconnect_from_all_hosts()` helper，查詢陣列當前的連線清單，
  逐一 disconnect,**在所有清理路徑的 `volume_delete` 之前**呼叫。
  共修正 4 個位置：`alloc_image()` 主要 connect-fail 清理、
  `alloc_image()` state/cloudinit 「Cannot get WWID」清理、
  `alloc_image()` state/cloudinit 「裝置未出現」清理、以及
  `clone_image()` connect-fail 清理。
- **[LOW] Bug F — `volume_snapshot()` 現在會在呼叫陣列的
  `snapshot_create` 之前先 flush 主機端 dirty buffer**，與
  `volume_snapshot_rollback()` 之前已有的行為對稱。對執行中的 VM,
  qemu 的 freeze 會在檔案系統層處理一致性；但對離線 Volume 或外部 script
  呼叫者 （例如某些備份工具直接對停機 VM 的 Volume 寫入）,dirty page cache
  可能不在快照裡，產生檔案系統不一致的快照。用 `is_device_in_use()`
  防護避免在繁忙的線上遷移時阻擋。

#### 移除
- **[LOW] Bug G + dead export 稽核 — 從 `Multipath.pm` 移除 4 個
  exported 但 0 個 caller 的函式：** `multipath_add`、
  `multipath_remove`、`get_multipath_wwid`、`get_scsi_devices_by_serial`。
  `get_multipath_wwid` 含有與 1.1.2 修正的 `is_device_in_use`
  相同類別的 `/dev/mapper` symlink 潛在 bug；與其修正死碼 （以及未來
  維護者可能看到它在 `@EXPORT_OK` 中而呼叫的風險），不如直接整個
  移除。其他三個也都沒有任何呼叫者。

---

## [1.1.2] - 2026-04-09

### 重大 — 從相關專案 jt-pve-storage-netapp 後續修正中移植的 4 個 bug

jt-pve-storage-netapp 在正式環境上一次 resize 事故揭露 4 個 bug,Pure 外掛**也都有**。
其中一個是沉默資料遺失等級。**所有 1.0.x / 1.1.0 / 1.1.1 的正式環境使用者
應立即升級。**

#### 修正
- **[CRITICAL — 資料遺失] `is_device_in_use()` 對 `/dev/mapper/<wwid>`
  路徑永遠回傳 0。** 它用 `basename($device)` 組成
  `/sys/block/<name>/holders` 路徑，但對 multipath 裝置而言會解析成
  `/sys/block/<wwid>/holders`，這個路徑**不存在** — holders 目錄位於
  `/sys/block/dm-N/` 之下。所以對任何 multipath 裝置都會回傳 "未在
  使用"，不管上面有沒有 LVM volume group、dm-crypt 容器、dm-raid 或
  其他 holder。然後 `free_image()` 就會繼續刪除 Volume — 把客戶的 LVM
  資料一起帶走。**任何在 Pure Volume 之上使用 LVM （或 dm-crypt / dm-raid /
  bcache / ...) 的正式環境都有風險。** 修正方式：新增
  `_resolve_block_device_name()` helper，在任何 `/sys/block/` 存取之前
  先把 `/dev/mapper/<wwid>` symlink 解析成底層的 `dm-N` 名稱。
- **[HIGH] `get_multipath_slaves()`** 有同樣的破損模式。對
  `/dev/mapper/<wwid>` 路徑永遠回傳空 list，代表 `free_image()` 的
  清理後 SCSI slave 移除步驟會沉默地跳過每個裝置，跨操作累積 SCSI
  殘留。
- **[HIGH] `volume_resize()`** 呼叫的是 `rescan_scsi_hosts()` (host
  scan，用於發現**新**裝置），而不是 per-device rescan （用於重讀
  **既有**裝置的屬性）。Pure 側 resize 後，陣列顯示新大小，但 multipath
  裝置仍回報舊大小，QEMU 的 `block_resize` 對執行中 VM 會失敗並回報
  `Cannot grow device files`。修正方式：對每個 slave 做
  `echo 1 > /sys/block/sdX/device/rescan`，然後呼叫
  `multipathd resize map <name>` （新 helper) 重新整理 device-mapper
  那一層的大小。
- **[HIGH] `volume_snapshot_rollback()`** 有與 resize 相同的錯誤
  rescan，加上第二個問題：即使底層 SCSI 路徑已更新，kernel 緩衝快取
  仍可能持有 rollback 之前的內容頁面。從 rolled-back Volume 的後續讀取
  可能會回傳過期資料。修正方式：(1) 每個 slave rescan、
  (2) `multipath_resize_map`、（3) `blockdev --flushbufs <device>`
  讓 kernel 緩衝快取失效。

#### 新增
- `Multipath.pm` 新增 `_resolve_block_device_name()` helper。在對可能是
  `/dev/mapper/<wwid>` 的路徑做任何 `/sys/block/<name>/` 存取之前，
  都應先呼叫此函式。可處理 `/dev/sdX`、`/dev/dm-N` 與
  `/dev/mapper/<name>` （解析 symlink）。
- `Multipath.pm` 新增 `multipath_resize_map()` helper，已 export。

---

## [1.1.1] - 2026-04-09

### Multipath / 防掛起後續修正

對 v1.1.0 與 PVE 儲存外掛開發指南交叉檢查時發現。**建議用 1.1.1 而非
1.1.0** — 1.1.0 雖有叢集清理架構，但 multipath device 區塊仍然缺
`no_path_retry`，代表在 `defaults` 區塊有 `no_path_retry queue` 的主機
上，殘留裝置仍會掛起。本版本補上這個漏洞。

#### 修正
- **Pure multipath device 區塊現在明確設定 `no_path_retry 30` 與
  `fast_io_fail_tmo 5`。** 過去缺這兩項時，per-device 區塊會繼承
  `defaults` 區塊的值，而很多現場 （受歷史 NetApp HA 建議影響） 是 `queue`。
  配上殘留 Pure 裝置，會讓 `sync` / `blockdev` / `multipath -f` 進入
  uninterruptible sleep — 正是 1.1.0 想阻擋的情境。
- **`_ensure_multipath_config` 現在會在產生的設定檔內寫入版本標記**
  (`# pure-multipath-config-version: 2`)，只有帶這個標記的
  plugin-managed 檔案會在版本變動時被外掛重寫。**沒有**標記的檔案
  （操作員手改或第三方產生） 一律不動。這代表從 1.0.x → 1.1.x 升級時
  能真正吃到新的安全設定，而不是繼續沉默地用舊檔。
  > **⚠️ 升級陷阱：** 若你既有的
  > `/etc/multipath/conf.d/pure-storage.conf` 是由更早版本 (1.0.x)
  > 建立的，它**沒有**標記行，所以 1.1.x 會保留不動。你必須手動把它
  > 對齊新版 device 區塊 （見 README「升級 SOP」上方的警告框）,
  > 或是 `rm` 掉該檔讓外掛重新建立。否則新的 `no_path_retry 30` /
  > `fast_io_fail_tmo 5` 安全設定不會生效。
- 將 `is_device_in_use` 中的 bare `system('fuser', ...)` 改為
  timeout-bounded `_run_cmd` (5s）。`fuser` 會開啟裝置路徑，在
  `queue_if_no_path` 的卡住 multipath 裝置上，自身就會 D-state 永不返回。
- 將 `volume_resize` 中的 bare `system('sync')` 與 `system('blockdev', ...)`
  改為 `PVE::Tools::run_command(..., timeout => 10)`。
- 新增 `_udev_refresh()` helper，透過 `PVE::Tools::run_command` 執行
  `udevadm trigger` 與 `udevadm settle`,timeout 10s。將 plugin 與
  Multipath 模組裡所有 13 處 bare `system('udevadm ...')` 統一改為呼叫
  此 helper。

---

## [1.1.0] - 2026-04-09

### 重大可靠性釋出 — 從相關專案 jt-pve-storage-netapp (v0.2.x) 移植正式環境驗證過的修正

由真實正式環境事故驗證：殘留 multipath 裝置加上 `queue_if_no_path`，造成
PVE daemon 進入不可中斷睡眠，只能重新啟動節點復原。

#### 防掛起 (Section 1)
- 在 `Multipath.pm` 新增 `sysfs_write_with_timeout` /
  `sysfs_read_with_timeout` helper。所有對
  `/sys/class/scsi_host/*/scan`、`/sys/class/block/*/device/{delete,rescan}`
  的直接寫入，以及對 `/proc/mounts` 與 `/sys/.../wwid` 的讀取，
  全部改走 fork-bounded 子行程，即使底層 HBA 卡死也不會把父行程
  拖進 D state。
- 將清理路徑中的 bare `system('sync')` / `system('blockdev')` 改為
  timeout-bounded `_run_cmd` 呼叫。
- `cleanup_lun_devices` 在嘗試 `sync` / `blockdev` / `multipath -f` 之前，
  會先呼叫 `multipathd disablequeueing` 與
  `dmsetup message ... fail_if_no_path`。否則 queueing 會讓這些操作在
  死掉的裝置上永遠卡住。
- `multipath_flush` 不再允許在沒有 device 引數的情況下被呼叫
  （過去會 fall through 到 `multipath -F`，該指令會 flush 主機上**所有**
  未使用的 map，可能切斷客戶手動管理的非 Pure 儲存）。
- `multipath_flush` 內建 `dmsetup --force` fallback，當
  `multipath -f <wwid>` 失敗或 timeout 時自動使用。

#### 叢集安全 (Section 2)
- 在 `ISCSI.pm` 新增 `is_portal_logged_in()`，並在 `login_target` 與
  `activate_storage` 中使用。Pure 控制器在多個 LIF 之間共用一個 IQN;
  只用 target 名稱檢查會在第一個 portal 登入後沉默地跳過所有後續 portal,
  讓主機只剩 1 條路徑而非 N 條。
- `login_target` 現在會設定 `node.session.timeo.replacement_timeout` 為
  120，讓暫時性中斷以及 Pure 控制器 failover 在無論 `iscsid.conf` 怎麼
  設定的情況下都能順利恢復。
- `activate_storage` 對已連線的 portal 跳過 `iscsiadm discovery+login`
  （每次 status 輪詢可省下最多 30 秒的 discovery latency）。

#### `free_image` 操作順序 (Section 3)
- **在 unmap 前**先擷取 multipath slave 裝置清單 (unmap 後
  `/sys/block/.../slaves` 目錄會消失）。
- 先 disconnect 所有 host，再清理本地裝置，最後在陣列上刪 Volume。舊順序會
  讓另一節點正在執行的 iSCSI rescan 重新匯入該 LUN，在我們背後重建
  multipath 裝置。
- `cleanup_lun_devices` 之後，使用擷取的清單再移除殘留的 SCSI slave 裝置，
  並 reload `multipathd` 確保狀態收斂。

#### API 韌性 (Section 4)
- 預設 UA timeout 從 30s 降到 15s,retry 從 3 降到 2 (worst case
  從 ~102s 降到 ~34s）。
- `_request` 接受 per-call `timeout` 選項，單次覆寫 UA timeout，並在
  所有出口路徑還原。
- `volume_delete` 使用 60s per-call timeout，因為當 volume 有許多
  snapshot 時 Pure 銷毀可能很慢。
- 401 retry 在 `_create_session` 重建 LWP::UserAgent 後會重新套用任何
  per-call timeout 覆寫。
- `status()` 現在在 API 錯誤時 fail-fast （回 inactive zeros)，而不是
  讓輪詢執行緒卡住。
- `status()` 現在用 double-fork grandchild 跑 orphan / temp-clone 清理，
  grandchild 被 reparent 到 init，清理永遠不會擋住 storage daemon。

#### 叢集殘留 / orphan 清理 (Section 5)
- 新增 WWID 追蹤架構：per-storage 狀態檔位於
  `/var/lib/pve-storage-purestorage/<storeid>-wwids.json`，鎖檔位於
  `/var/run/pve-storage-purestorage/<storeid>-wwids.lock`。鎖採用
  non-blocking `flock` 配上有上限的重試 (10s deadline)，避免在卡死的
  worker 上永遠等待。
- `path()` 在成功解析出真實裝置後追蹤 WWID。
- `free_image` 只在確認本地 multipath 裝置已消失後才取消追蹤 WWID —
  若清理留下殘留裝置，WWID 維持追蹤狀態，讓下一輪 orphan 清理可以重試。
- `_cleanup_orphaned_devices` 三階段執行：
  1. **自動匯入**：從陣列拿到所有 Pure 管理的 LUN WWID，加入本地追蹤
     (讓所有叢集節點對 alive set 的認知收斂一致)。
  2. **清理**：對每個追蹤中但不在陣列上的 WWID，若本地有殘留 multipath
     裝置就清掉。
  3. **警告**：列出本地有但不在追蹤中也不在陣列上的 Pure multipath 裝置
     (**不**自動清 — 可能是客戶手動管理)。

#### postinst (Section 6)
- 印出「CRITICAL Multipath Safety Rules」橫幅，說明 `multipath -F` 與
  `multipath -f` 的差別、restart 與 reload 的差別，以及建議的
  Pure-friendly multipath.conf 設定。
- 偵測 `/etc/multipath.conf` 中的危險設定 (`no_path_retry queue`、
  `queue_if_no_path`、`dev_loss_tmo infinity`) 並警告，**不**自動修改
  客戶 config。
- 升級時偵測既有的殘留 Pure multipath 裝置，並列出精確的手動清理指令。
- 預先以 mode 0700 建立 `/var/lib/pve-storage-purestorage` 與
  `/var/run/pve-storage-purestorage`。

#### 程式品質 (Section 7)
- `alloc_image` 在磁碟 ID 衝突時重試 (`_find_free_diskid` 與
  `volume_create` 之間的 TOCTOU，兩個 worker 賽跑）。
- `path()` 改用受 `pure-device-timeout` （預設 30s) 限制的重試迴圈，
  而非單次 rescan。
- `list_images` 範本偵測 fallback 加上 10s wall-clock deadline,
  避免慢陣列把 timeout 連環擴散到上百個 volume。

#### 文件 (Section 8)
- README.md 與 README_zh-TW.md 在開頭附近加入醒目的
  **CRITICAL: Multipath Safety Rules** 與 **Upgrade SOP** 段落。
- 新增 `docs/TESTING.md` 與 `docs/TESTING_zh-TW.md`:Pure-Storage-specific
  測試計畫，涵蓋基本連線、VM 生命週期、熱插拔、快照/clone、叢集 orphan
  清理、混合環境安全、失敗注入 （控制器 failover、阻擋 LIF、阻擋 API、
  `queue_if_no_path` + 殘留裝置掛起）、API 1.x 與 2.x 雙覆蓋、命名邊界、
  pod (ActiveCluster) 模式、per-node 與 shared host 模式、效能/sanity、
  以及升級路徑。

---

## [1.0.49] - 2026-02-27

### 第二輪可靠性與正確性稽核修正

- 修正 `volume_snapshot_list` 對 `pve-snap-` 前綴的雙重編碼，造成
  `snapshot_delete` 在重複編碼後的名稱上失敗。
- 修正 `list_images` 將帶 pod 前綴的名稱傳給 `pure_to_pve_volname`,
  造成 pod 環境中 cloudinit / state volume 的解碼失敗。
- 修正 `parse_volname` 在錯誤時返回 undef 而非 die （違反 PVE 儲存
  外掛 API 合約，造成沉默失敗）。
- 修正 `pve-pure-config-get` LXC 偵測的運算子優先權，過去會把帶
  `arch:` 行的 QEMU VM 誤判為 LXC 容器。
- 修正 `pve-pure-config-get` 的 `umount` 呼叫改用 list-form `system()`
  避免 shell injection。
- 修正 `_backup_vm_config` 在錯誤路徑上漏掉 `cleanup_lun_devices`,
  造成備份失敗後留下殘留 SCSI 裝置。
- 修正 API cache 的 fork 安全性，加入 PID 檢查避免在 fork 出來的
  PVE daemon worker 中使用過期的 session token。
- 修正 `deactivate_storage` 在 disconnect 之前先檢查 `is_device_in_use`,
  避免清除其他 VM 仍在使用的 volume。
- 修正 `alloc_image` 的 orphan 清理漏掉 `skip_eradicate`，過去在配置
  重試時可能永久清除 volume。
- 將臨時的 `multipathd reconfigure` shell 呼叫統一改為使用
  `multipath_reload()`。
- 修正 `Multipath.pm` 中的 `SG_INVERT` 拼錯為 `SG_INQ`。
- 修正 `encode_config_volume_name` 的長度檢查，當總長超過 63 字元時
  截斷 `snapname`。
- 將 `IO::Select` import 移到 `ISCSI.pm` 與 `Multipath.pm` 的檔案層級。
- 修正 `pve-pure-config-get` restore 模式的 config 寫入錯誤清理
  (`umount` 與 `disconnect` 現在一定會執行）。
- 移除 `pve-pure-config-get` restore 模式中的死碼。

## [1.0.48] - 2026-02-12

### 安全性與可靠性稽核修正 （跨所有模組）

- 修正 `path()` 在 API 失敗時返回 `/dev/null` 或合成路徑，改為正確 die
  以避免沉默資料損毀 (CRITICAL）。
- 修正 `get_multipath_device` 使用子字串 WWID 比對可能傳回錯裝置，
  改為精確比對 (HIGH）。
- 修正 `get_device_by_wwid` 的 glob pattern 改用精確後綴比對，避免
  裝置碰撞 (HIGH）。
- 修正 ISCSI 的 `_find_multipath_device` 與 `wait_for_device` 改用
  精確序號後綴比對 (HIGH）。
- 修正 `_cleanup_orphaned_temp_clones` 對 API 2.x ISO 8601 時間戳的
  解析 （過去比較字串對 epoch，永遠不會清理）。
- 修正 `clone_image` 磁碟 ID 配置的競態，改用 `_find_free_diskid` 而非
  手動 `max+1` 邏輯。
- 修正 `_find_free_diskid` 在 `decode_volume_name` 之前先剝除 pod 前綴。
- 修正 `pve-pure-config-get` restore 模式的布林邏輯錯誤，過去在 restore
  模式總是 die。
- 修正 `pve-pure-config-get` 的 `san_storage` 改用 `sanitize_for_pure`。
- 修正 `is_device_in_use` 的 `fuser` 呼叫與 `_backup_vm_config` 的
  `system` 呼叫的 shell injection （改用 list 形式）。
- 修正 `_backup_vm_config` 錯誤路徑的 mount 清理。
- 在 `cleanup_lun_devices` 加入 in-use 守衛，避免清掉仍掛載或被持有的
  裝置。
- 修正 `ISCSI.pm` 與 `Multipath.pm` 的 `_run_cmd` 使用 `IO::Select`
  同時讀取 stdout / stderr （避免 deadlock）。
- 修正 `_run_cmd` timeout 時 kill 子行程 （避免 orphan）。

---

## [1.0.0] – [1.0.47]

更早的開發歷史。完整 per-release 詳細請參考 `debian/changelog`。重點：

- **1.0.0** — 初始版本，基本 iSCSI Pure Storage 支援。
- **1.0.x** — 漸進式新增：FC 支援、API 1.x 與 2.x 雙 client、snapshot /
  clone / template / linked-clone、cloudinit 與 state 與 TPM volume、
  LXC 支援、ActiveCluster pod 支援、VM config 備份 Volume、
  `pve-pure-config-get` CLI、multipath helper 模組、命名模組、
  host get-or-create with race handling、`list_images` 批次 snapshot
  query。

任何 1.0.48 之前的版本應視為已被取代 — 正式環境請安裝 1.1.1 或更新版本。

---

## 作者

Jason Cheng (Jason Tools) — jason@jason.tools — MIT 授權
