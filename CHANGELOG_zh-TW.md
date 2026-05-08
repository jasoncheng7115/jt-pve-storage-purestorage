# 變更紀錄

**jt-pve-storage-purestorage** 所有重要變更皆紀錄於此檔案。
格式參考 [Keep a Changelog](https://keepachangelog.com/),
版本號採用 `MAJOR.MINOR.PATCH-DEBIAN` 規則。

語言 / Language: [English](CHANGELOG.md) | [繁體中文](CHANGELOG_zh-TW.md)

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
  孤兒 host 連線永遠留著，而每個 `volume_delete` 清理都走 Bug E
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
  → 陣列上孤兒 host 連線。修法：在 connect-fail 分支與
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
  Pure （與 ONTAP 不同） 會直接銷毀仍在連線中的 Volume，但**孤兒 host 連線
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
