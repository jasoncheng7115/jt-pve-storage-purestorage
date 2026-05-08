# Pure Storage FlashArray Storage Plugin for Proxmox VE

**[English](README.md)** | **[繁體中文](README_zh-TW.md)** | **[線上文件](https://jasoncheng7115.github.io/jt-pve-storage-purestorage/?lang=zh)**

此 Plugin 讓 Proxmox VE 9.1 以上版本可以透過 iSCSI 或 Fibre Channel 協定使用 Pure Storage FlashArray 作為 VM 和 Container 的磁碟儲存。

> **免責聲明**
>
> 本專案仍在初期開發階段，尚未經過大規模正式環境驗證。
>
> - **iSCSI**：基本功能已測試，但尚未進行大規模驗證
> - **Fibre Channel**：基本功能已測試，包含 FC 網路連線驗證與診斷日誌
>
> **使用風險自負。** 作者不對因使用本 Plugin 而造成的任何資料遺失、系統停機或其他損害承擔責任。請務必在測試環境中充分測試後，再部署到正式環境。使用前請確保已有適當的備份。

## 重要：Multipath 安全規則

以下規則對 Linux 上**任何** SAN 儲存皆適用，但若在使用 Pure Storage 配上
典型 PVE multipath 設定時忽略，曾經實際造成 PVE daemon 進入不可中斷
睡眠 (D state) — 只能透過重新啟動節點復原。安裝外掛前請務必先讀。

1. **絕對不要執行 `multipath -F`** （大寫 F）。它會 flush 主機上**所有**
   未使用的 multipath map，包含當下剛好閒置的非 Pure 儲存。請一律使用
   小寫 `multipath -f /dev/mapper/<wwid>` 來 flush 特定裝置。

2. **使用 `systemctl restart multipathd`，而非 `systemctl reload`。**
   Reload 只重新讀取設定檔。Restart 才會真正重新套用 device-mapper 狀態。
   外掛內部 helper 也是用 restart，理由相同。

3. **避免危險的預設值。** `no_path_retry queue` 加上外掛正在嘗試清理
   的殘留裝置會掛住 `multipath -f`、`sync`、`blockdev --flushbufs`,
   以及任何開啟該裝置的 process。建議的 Pure-friendly 設定：

   ```
   defaults {
       polling_interval        10
       no_path_retry           30
       fast_io_fail_tmo        5
       dev_loss_tmo            60
   }
   devices {
       device {
           vendor               "PURE"
           product              "FlashArray"
           path_selector        "queue-length 0"
           path_grouping_policy group_by_prio
           prio                 alua
           hardware_handler     "1 alua"
           failback             immediate
           no_path_retry        30
       }
   }
   ```

4. **外掛 (v1.1.0+) 自動處理叢集範圍的清理。**
   每個節點維護一個 WWID 追蹤檔
   (`/var/lib/pve-storage-purestorage/<storeid>-wwids.json`),
   `pvesm status` 會在 backgrounded grandchild 中跑 orphan 清理，
   定期清理永遠不會阻擋 storage daemon。設計理念請參考
   `docs/TESTING_zh-TW.md` Section 6。

## 升級 SOP

> **⚠️ 升級前務必先讀 — `/etc/multipath/conf.d/pure-storage.conf` 升級行為**
>
> 自 1.1.1 起，外掛在自己產生的 `pure-storage.conf` 內寫入版本標記
> (`# pure-multipath-config-version: N`),`_ensure_multipath_config`
> 在標記版本變動時會重寫該檔案。**沒有標記的檔案會被刻意保留不動** —
> 因為外掛會假設這類檔案是由更早版本建立後被操作員修改過，或是由
> 第三方產生。
>
> **這對 1.0.x → 1.1.2 升級代表什麼：**
>
> | 你目前的檔案狀態 | 1.1.2 的行為 | 你必須做的事 |
> |---|---|---|
> | 沒有 `pure-storage.conf` | 外掛寫入新檔，含 `no_path_retry 30` / `fast_io_fail_tmo 5` | 不用做任何事 |
> | `pure-storage.conf` 存在，有新版標記 (1.1.1+) | 下次 `activate_storage` 會自動升級到 v2 | 不用做任何事 |
> | `pure-storage.conf` 存在，**沒有**標記 (1.0.x 或手改過） | 外掛**完全不動該檔** | **必須手動對齊**新版的 device 區塊 — 見下方 |
>
> **若你的檔案落在最後一列，你必須手動更新它** — 否則新的安全設定
> (`no_path_retry 30`、`fast_io_fail_tmo 5`) 不會生效，在 `defaults`
> 區塊有 `no_path_retry queue` 的主機上，殘留裝置仍然會掛住 PVE。
>
> 建議的替換 device 區塊：
>
> ```
> devices {
>     device {
>         vendor               "PURE"
>         product              "FlashArray"
>         path_selector        "queue-length 0"
>         path_grouping_policy group_by_prio
>         prio                 alua
>         hardware_handler     "1 alua"
>         failback             immediate
>         no_path_retry        30
>         fast_io_fail_tmo     5
>         dev_loss_tmo         60
>     }
> }
> ```
>
> 編輯後執行 `systemctl restart multipathd` (**不要**用 `reload`）。
>
> **要回到讓外掛自動管理最簡單的方式**:
> `rm /etc/multipath/conf.d/pure-storage.conf`。下次
> `pvesm status pure1` 會用正確設定重建檔案並寫入標記，從此之後的
> 升級就會全自動。

從任何更早版本 (1.0.x) 升級到 1.1.0 以上時請依下列步驟執行。
**一次只升一個節點**。

1. **備份每個節點的 `/etc/multipath.conf`** 與
   `/etc/multipath/conf.d/pure-storage.conf`。
2. **停機或遷移**執行中的 VM 離開要升級的節點 （建議；非強制）。
3. **安裝新套件**:
   ```
   dpkg -i jt-pve-storage-purestorage_1.1.12-1_all.deb
   ```
4. **仔細閱讀 postinst 輸出**。它會警告：
   - 危險的 multipath.conf 設定 （上一節）
   - 節點上既有的殘留 Pure 裝置
   - multipathd 用 `restart` 與 `reload` 的差別
5. **若 postinst 對 multipath.conf 警告**，請依指示編輯檔案，然後
   `systemctl restart multipathd`。
6. **若 postinst 對殘留 Pure 裝置警告**，請依警告中的手動清理指令處理。
   **不要**用 `multipath -F`。
6a. **檢查 `pure-storage.conf` 升級狀態**:
    ```
    head -3 /etc/multipath/conf.d/pure-storage.conf
    ```
    若該檔案存在但**沒有** `# pure-multipath-config-version:` 開頭的
    那一行,請參考上方警告框 — 你必須手動對齊新版 device 區塊範本,
    或是 `rm` 掉該檔讓外掛重新建立。
7. **驗證**:
   ```
   pvesm status pure1                                # < 5s, active
   cat /var/lib/pve-storage-purestorage/*-wwids.json # 已自動匯入
   multipath -ll | grep -c PURE                      # 路徑數正確
   ```
8. **下個節點**，僅在當前節點通過第 7 步後再進行。

## 儲存模型

本外掛採 **direct volume provisioning（直接 Volume 供應）** — 每
一顆 VM 磁碟在 Pure FlashArray 上對應一個獨立的 Volume，大小即為當
下要求的容量。陣列上沒有任何「預先建立的大 LUN」或儲存集區在主機端
被切片。

當 Proxmox VE 要求 50 GiB 磁碟時，外掛對陣列呼叫 `volume_create`
建立一顆 50 GiB 的 volume；要求快照時，外掛對該 volume 呼叫
`snapshot_create`。語意 1:1 對齊 — Pure 的資料服務（重複資料刪除、
壓縮、快照、ActiveCluster、非同步複寫）全部以「一顆 VM 磁碟」為自然
單位作用。

### 直接 Volume 供應 vs 儲存集區式 SAN 模型

```
Traditional pool-based SAN model
=================================

  +----------------------------+
  |  1x big LUN on array       |    admin pre-allocates one
  |  (e.g. 10 TB)              |    giant LUN
  +----------------------------+
                |
                v
  +----------------------------+
  |  LVM / LVM-thin on host    |
  |  +------+ +------+ +-----+ |
  |  | LV   | | LV   | | ... | |    each VM disk is an LV
  |  | vm   | | vm   | |     | |    inside the host's LVM
  |  | -100 | | -100 | |     | |
  |  | -d0  | | -d1  | |     | |
  |  +------+ +------+ +-----+ |
  +----------------------------+

  Snapshots / clones / replication happen at the LVM layer.
  Array sees ONE LUN that is always "in use".


This plugin (direct volume provisioning)
========================================

  +-----------------------------+
  | Pure FlashArray             |
  |                             |
  |   Volume   pve-...-100-d0   |    each VM disk is its own
  |   Volume   pve-...-100-d1   |    volume on the array, sized
  |   Volume   pve-...-101-d0   |    exactly to the request
  |   Volume   pve-...-102-d0   |
  |        ...                  |
  +-----------------------------+

  No host-side LVM. Every volume has its own WWID, snapshot chain,
  and host connections. Snapshots / clones / replication happen on
  the array, natively.
```

儲存集區式模型在陣列與 Proxmox VE 之間插入一層 LVM（或 LVM-thin）。
快照、複製、複寫都發生在 LVM 層 — 陣列只看到一顆永遠「使用中」的大
LUN，無法針對單一 VM 磁碟做 dedup ratio、replication policy、
snapshot retention。本外掛完全移除這層中介。

### 層級堆疊

一個 Proxmox VE volname 如何在主機端變成可用的區塊裝置：

```
Proxmox VE level                vm-100-disk-0            (PVE volname)
        |
        v
Plugin encoding                 pve-pure1-100-disk0      (Naming.pm)
        |
        v
Pure FlashArray volume          50 GiB, WWID 624a9370... (REST API)
        |
        v
Host connections                connected to every       (per-node mode)
                                "pve-<cluster>-*" host
        |
        v
SCSI / FC transport             iSCSI sessions OR        (multiple paths
                                FC fabric                  per host)
        |
        v
Linux SCSI paths                /dev/sdc /dev/sdd ...    (one per portal /
                                                          fabric link)
        |
        v
multipath aggregation           /dev/mapper/3624a9370... (DM-multipath,
                                = /dev/dm-N                ALUA, queue-length 0)
        |
        v
QEMU block device               passed to qemu           (raw, no FS layer
                                                          between)
```

### 對使用者的意義

- **快照即陣列原生** — `volume_snapshot` 呼叫 Pure 的
  `snapshot_create`；倒回使用 `volume_overwrite`。沒有 LVM
  copy-on-write 成本。
- **連結複製即陣列複製** — 瞬間完成；新 volume 與來源共享資料區塊
  直到被寫入。Proxmox VE 的「完整複製」是 Proxmox VE 設計選擇
  （透過 `qemu-img` 逐區塊複製），不是外掛限制。
- **線上擴充僅一次 API 呼叫** — 對陣列下 `volume_resize`，主機端再
  進行每路徑 SCSI rescan 與 `multipath_resize_map`。沒有上層儲存集
  區的檔案系統擴充步驟。
- **Live Migration 隱含完成** — 在 per-node 模式下，每個 volume
  都連到每個節點的 host，相同的 multipath 裝置同時存在於叢集所有
  節點。Proxmox VE 只是切換哪個節點開啟它，無需儲存遷移步驟。
- **逐 VM 的陣列資料服務** — dedup 比、複寫政策、快照保留、QoS 與
  ActiveCluster Pod 成員資格都可以針對單一 VM 磁碟設定，因為每顆
  磁碟在陣列上都是獨立物件。

## 功能特色

### 儲存操作
- 直接 Volume 建置（無需傳統 SAN 的 LUN 間接層）
- 線上磁碟擴充（不需重新啟動 VM）
- 自動設定 Pure Storage 裝置的 Multipath

### Snapshot 與 Clone
- 透過 Pure Storage 原生 snapshot 實現瞬間建立/刪除/還原
- 從 Template 進行 Linked Clone（瞬間完成，使用 Pure Storage snapshot clone）
- RAM Snapshot 支援（Include RAM 選項）
- Clone 依賴保護（Pure Storage 會防止刪除有 clone 依賴的 snapshot）
- **自動 VM 設定備份** - 每次建立 snapshot 時自動將 VM 設定檔備份到 Pure Storage

### 高可用性
- 叢集感知，支援 Live Migration（Volume 會連接到所有節點）
- ActiveCluster Pod 支援同步複製
- 自動在 Pure Storage 上註冊 Host

### 協定支援
- iSCSI 自動 Target 探索與登入
- Fibre Channel WWN 自動偵測
- Multipath I/O 自動設定

### 內容類型
- VM 磁碟映像（`images`）
- Container 根檔案系統（`rootdir`）

## 系統需求

- Proxmox VE 9.1 或更新版本
- Pure Storage FlashArray，Purity//FA 2.26 或更新版本（REST API 2.x）
- Pure Storage API Token 或使用者帳號密碼
- 可連線至 Pure Storage 管理介面

### iSCSI 需求
- `open-iscsi` 套件
- `multipath-tools` 套件
- 可連線至 iSCSI 資料介面

### Fibre Channel 需求
- 已安裝驅動程式的 FC HBA
- `multipath-tools` 套件
- 已設定主機與 Pure Storage 之間的 FC Zoning

## 安裝

### 從 .deb 套件安裝（建議）

```bash
dpkg -i jt-pve-storage-purestorage_1.1.12-1_all.deb
apt-get install -f  # 如需安裝相依套件
```

### 從原始碼安裝

```bash
cd /root/jt-pve-storage-purestorage
make install
```

## 設定

### 使用 API Token 設定（建議）

```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    --pure-protocol iscsi \
    --content images,rootdir
```

### 使用帳號密碼設定

```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-username pureuser \
    --pure-password secretpassword \
    --pure-protocol iscsi \
    --content images,rootdir
```

### 容量與權限隔離：Pod 與 Realm

外掛透過 REST API 連接陣列，並依需求動態建立 Volume。預設情況下，
外掛使用整台陣列的容量，且 API Token 為陣列層級權限。若要限制外掛
可動用的範圍——無論是出於容量上限或 API 影響範圍隔離考量——
Pure 提供兩種外掛能識別的機制。

**Volume 名稱永遠採用 `pve-<storeid>-` 前綴**，因此既有陣列上不符合
此前綴的 Volume，即使未啟用以下任何隔離選項，也不會被外掛讀取或
寫入。

#### 方案 A——Pod 加配額（任何 Purity 版本）

Pod 是陣列上的命名空間。在 Pod 設定 `quota_limit` 並讓外掛指向
此 Pod，外掛便會以 Pod 配額取代陣列總容量進行回報。Volume 名稱
會自動加上 `pod::` 前綴，與 Pod 外的物件不會撞名。

> ⚠ **重要：Pod 配額一定要用對的方式設定**
>
> Pod block-level 配額是 Pod 物件本身的 `Pod.quota_limit` 欄位。
> 用以下任一方式設定：
>
> - **Pure CLI**：`purepod create --quota-limit 2T pve-pod`（或建好
>   後 `purepod setattr --quota-limit 2T pve-pod`）
> - **Pure REST API**：`PATCH /api/2.x/pods?names=pve-pod` body
>   `{"quota_limit": 2199023255552}`
> - **Pure GUI**：Storage > Pods > `<pod>` > 編輯 Quota Limit ——
>   **只有 Purity 6.6+ 才有此 UI**。較早版本（含 6.5.x）GUI 完全
>   沒有此欄位，必須走 CLI 或 REST。
>
> **絕對不要**用 Storage > Policies > Quota 來設定 Pod 配額。
> 那個面板是 FlashArray Files／managed-directory 的配額機制——
> 雖然 GUI 在建立 policy 時讓你選一個 Pod，但對 block volume
> 來說那是錯的機制。任何 Storage > Policies 建出來的 policy 一旦
> 掛到 Pod 上，Pod 就會被標記為「附掛了 file-services policy」，
> 之後所有 block volume create 都會被 Pure 拒絕並回傳誤導性的
> `Pod contains file systems or policies. (context: <podname>)`
> 錯誤。如果遇到這個錯誤：用 `purepolicy quota destroy <policy-name>`
> （或 REST `DELETE /api/2.x/policies/quota?names=<policy-name>`）
> 把 policy 砍掉，再改用 `Pod.quota_limit`。

Proxmox VE 端：
```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    --pure-protocol iscsi \
    --pure-pod pve-pod \
    --content images,rootdir
```

設定後，Status 面板顯示 Pod 配額。Volume 名稱變為
`pve-pod::pve-<storeid>-<vmid>-disk<N>`。單陣列 local Pod
**不需要** ActiveCluster 授權；ActiveCluster 僅用於跨陣列的
stretched Pod。

#### 方案 B——Realm 加配額（Purity 6.6+）

Realm 是陣列上的租戶層級隔離邊界。Volume、Snapshot、Host、
甚至 API 看到的容量視圖都被限定在 realm 內。在 realm 內建立的
使用者所產生的 API Token，完全看不到 realm 之外的任何東西。

Pure 端：
1. Settings > Access > Realms > Create——名稱例如 `pve-realm`，
   設定 Quota Limit（例如 `2T`）
2. Settings > Access > Users > Create——使用者 `pve-plugin`、
   Realm `pve-realm`、Role `storage_admin`
3. 點 `pve-plugin` > API Tokens > Create

Proxmox VE 端：直接使用此 realm-scoped Token，**外掛沒有任何
選項要設**——範圍由 Token 本身強制執行。

```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-api-token <realm-scoped-token> \
    --pure-protocol iscsi \
    --content images,rootdir
```

#### 兩者比較

| 比較項目 | Pod | Realm |
|---------|-----|-------|
| 容量限制 | 有（Pod 上的 `quota_limit`） | 有（Realm 上的 `quota_limit`） |
| 命名隔離 | 有（`pod::` 前綴） | 有（不同 realm 之間名稱獨立） |
| 權限隔離 | 無——Token 仍看得到其他 Pod | 有——Token 只看得到自己的 realm |
| 外掛需設定的選項 | `--pure-pod <name>` | 無（Token 本身就限定了） |
| Volume 名稱格式 | `pve-pod::pve-...` | `pve-...` |
| Purity 版本需求 | 任意版本 | 6.6+ |

若版本支援，Realm 是比較乾淨的選擇——它在單一機制中同時隔離容量
與權限。在較舊的 Purity 上，Pod 是唯一外掛能識別的容量機制；
Pod 的 `quota_limit` 仍會給你硬上限，雖然 API Token 本身仍是
陣列層級的權限。

如果兩種都不設定，外掛就會使用整台陣列、Status 面板回報陣列總容量。
外掛只會讀寫名稱以 `pve-<storeid>-` 開頭的 Volume，因此不符合此
命名規則的既有 Volume 在任何設定下都不會被動到。

### 設定選項

| 選項 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `pure-portal` | 是 | - | Pure Storage 陣列管理 IP 或主機名稱 |
| `pure-api-token` | 否* | - | API Token 認證 |
| `pure-username` | 否* | - | API 使用者名稱 |
| `pure-password` | 否* | - | API 密碼 |
| `pure-ssl-verify` | 否 | 0 | 驗證 SSL 憑證（0=否， 1=是） |
| `pure-protocol` | 否 | iscsi | SAN 協定：`iscsi` 或 `fc` |
| `pure-host-mode` | 否 | per-node | Host 模式：`per-node` 或 `shared` |
| `pure-cluster-name` | 否 | pve | 用於 Host 命名的叢集名稱 |
| `pure-device-timeout` | 否 | 60 | 裝置探索逾時秒數 |
| `pure-portal-probe-timeout` | 否 | 2 | iscsiadm 之前對每個 portal 的 TCP 預探測逾時秒數，設為 0 停用 |
| `pure-pod` | 否 | - | Pod 名稱（見「容量與權限隔離」一節）。設定後容量回報以 Pod 配額為準，所有 Volume 名稱進入 Pod 命名空間 |
| `content` | 是 | - | 內容類型：`images`、`rootdir` |

\* 需提供 `pure-api-token` 或同時提供 `pure-username` 和 `pure-password`。

### storage.cfg 範例

```ini
purestorage: pure1
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-protocol iscsi
    pure-host-mode per-node
    pure-cluster-name mycluster
    content images,rootdir
    shared 1
```

## 使用方式

### VM 磁碟操作

```bash
# 建立磁碟
pvesm alloc pure1 100 vm-100-disk-0 10G

# 列出磁碟
pvesm list pure1

# 檢視磁碟大小
pvesm volume-size pure1:vm-100-disk-0

# 擴充磁碟（支援線上擴充）
qm resize 100 scsi0 +10G

# 刪除磁碟
pvesm free pure1:vm-100-disk-0
```

### VM 操作

```bash
# 建立使用 Pure Storage 磁碟的 VM
qm create 100 --name myvm --memory 2048 --cores 2 \
    --scsi0 pure1:20,iothread=1 --scsihw virtio-scsi-single

# 啟動 VM
qm start 100

# 停止 VM
qm stop 100
```

### Snapshot 操作

```bash
# 建立 Snapshot
qm snapshot 100 snap1

# 建立包含記憶體的 Snapshot（Include RAM）
qm snapshot 100 snap1 --vmstate

# 列出 Snapshots
qm listsnapshot 100

# 還原 Snapshot
qm rollback 100 snap1

# 刪除 Snapshot
qm delsnapshot 100 snap1
```

### Template 與 Clone 操作

```bash
# 將 VM 轉為 Template
qm template 100

# Linked Clone（建議，瞬間完成）
qm clone 100 200 --name cloned-vm --full 0

# Full Clone（較慢，因 PVE 限制會進行資料複製）
qm clone 100 200 --name cloned-vm --full 1
```

### Container 操作

```bash
# 建立使用 Pure Storage 的 Container
pct create 300 local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
    --rootfs pure1:10 --hostname myct --memory 512

# 啟動 Container
pct start 300
```

### Live Migration

```bash
# 將 VM 遷移到其他節點（線上）
qm migrate 100 pve2 --online
```

## 命名規則

| PVE 物件 | Pure Storage 物件 | 格式 |
|----------|-------------------|------|
| VM 磁碟 | Volume | `pve-{storage}-{vmid}-disk{diskid}` |
| Container rootfs | Volume | `pve-{storage}-{vmid}-disk{diskid}` |
| Cloud-init | Volume | `pve-{storage}-{vmid}-cloudinit` |
| RAM 狀態 | Volume | `pve-{storage}-{vmid}-state-{snapname}` |
| VM 設定備份 | Volume | `pve-{storage}-{vmid}-vmconf-{snapname}` |
| Snapshot | Volume Snapshot | `{volume}.pve-snap-{snapname}` |
| Template 標記 | Volume Snapshot | `{volume}.pve-base` |
| PVE 節點 | Host | `pve-{cluster}-{node}` |
| 共用 Host | Host | `pve-{cluster}-shared` |

### Linked Clone Volume 格式

Linked Clone 使用特殊命名格式來追蹤父子關係：
```
base-{basevmid}-disk-{n}/vm-{vmid}-disk-{n}
```

範例：`base-100-disk-0/vm-200-disk-0` 表示 VM 200 的磁碟是從 VM 100 的 Template Clone 而來。

## Host 模式

### per-node（預設）

為每個 PVE 節點在 Pure Storage 上建立獨立的 Host 物件。

```
pve-mycluster-pve1
pve-mycluster-pve2
pve-mycluster-pve3
```

適用於：
- 多節點叢集
- 需要在 Pure Storage 上區分各節點
- 精細的存取控制

### shared

所有 PVE 節點共用一個 Host 物件。

```
pve-mycluster-shared
```

適用於：
- 小型叢集（2-3 節點）
- 簡化管理
- 所有節點共用相同的 initiator

## Pod 支援（ActiveCluster）

設定 `pure-pod` 後，所有 Volume 會建立在指定 Pod 內，實現兩個 FlashArray 之間的同步複製。

```
無 Pod 的 Volume：pve-pure1-100-disk0
有 Pod 的 Volume：prod-pod::pve-pure1-100-disk0
```

功能：
- RPO = 0（同步複製）
- 雙活存取（兩邊陣列都可讀寫）
- 自動容錯
- Pod 配額顯示為儲存容量

## VM 設定備份

建立 snapshot 時，Plugin 會自動將 VM 設定檔備份到 Pure Storage。這讓您不僅可以還原磁碟資料，也可以還原該時間點的 VM 設定。

### 運作方式

- **自動執行**：建立任何 snapshot 時自動備份設定
- **獨立儲存**：每個 snapshot 都有獨立的設定備份
- **儲存格式**：1MB ext4 volume，內含 `{vmid}.conf` 和 `metadata.txt`
- **隱藏顯示**：設定備份 volume 不會出現在 PVE 磁碟列表中

### 自動清理

設定備份 volume 會自動清理：
- 刪除 snapshot 時，對應的設定備份 volume 也會被刪除
- 刪除 VM（最後一個磁碟被刪除）時，該 VM 所有的設定備份 volume 都會被刪除

### 取回設定備份

使用 `pve-pure-config-get` 命令列工具輕鬆取回設定備份。

**使用方式：**
```
pve-pure-config-get -s <storage> -v <vmid> [-n <snap>] [-o <output_dir>] [-l] [-r]
```

**選項：**

| 選項 | 說明 |
|------|------|
| `-s, --storage <name>` | Pure Storage 儲存區 ID（必填） |
| `-v, --vmid <id>` | 要取回設定的 VM ID（必填） |
| `-n, --snap <name>` | 指定要取回的 snapshot 名稱（跳過互動選擇） |
| `-o, --output <dir>` | 輸出目錄（預設：`/tmp`） |
| `-l, --list` | 僅列出可用的 snapshot，不取回 |
| `-r, --restore` | 災難復原模式（詳見下方說明） |
| `-h, --help` | 顯示說明訊息 |

**輸出檔案：**
```
/tmp/vm-{vmid}-{snapname}-{vmid}.conf      # VM 設定檔
/tmp/vm-{vmid}-{snapname}-metadata.txt     # 備份中繼資料（時間戳記、來源資訊）
```

**範例：**

```bash
# 列出 VM 100 可用的設定備份
pve-pure-config-get -s pure1 -v 100 -l

# 互動式取回設定（會提示選擇）
pve-pure-config-get -s pure1 -v 100

# 直接取回指定 snapshot 的設定
pve-pure-config-get -s pure1 -v 100 -n snap1

# 取回到指定目錄
pve-pure-config-get -s pure1 -v 100 -n snap1 -o /root/configs
```

**操作範例：**
```
$ pve-pure-config-get -s pure1 -v 100

Searching for config backups for VM 100...

Available config backups:
-----------------------------------------------------------
  No.  Snapshot Name  Volume
-----------------------------------------------------------
     1  backup1        pve1::pve-pure1-100-vmconf-backup1
     2  daily-0126     pve1::pve-pure1-100-vmconf-daily-0126
-----------------------------------------------------------

Enter number to retrieve (1-2), or 'q' to quit: 1

Retrieving config from: pve1::pve-pure1-100-vmconf-backup1
Connecting volume to host 'pve-mycluster-pve1'...
Volume WWID: 624a9370...
Scanning for device...
Found device: /dev/mapper/3624a9370...
Mounting to /tmp/...
Saved: /tmp/vm-100-backup1-100.conf
Saved: /tmp/vm-100-backup1-metadata.txt
Cleaning up...

Done! Config file saved to: /tmp/vm-100-backup1-100.conf
To restore: cp /tmp/vm-100-backup1-100.conf /etc/pve/qemu-server/100.conf
```

### 災難復原 (-r / --restore)

復原模式可從 Pure Storage 的已刪除 volumes 完整還原 VM。當 VM 被意外刪除，但 volumes 仍在 Pure Storage 的「Destroyed Volumes」中（尚未被 eradicate），即可使用此功能。

**功能：**
- 搜尋包含 active 和 destroyed 的 volumes
- 顯示 volume 狀態（`[active]` 或 `[DESTROYED]`）
- 自動恢復已刪除的 config 和 disk volumes
- 將設定檔放到正確的 PVE 位置（`/etc/pve/qemu-server/` 或 `/etc/pve/lxc/`）
- 連接 disk volumes 到 host
- 安全檢查：如 VM 設定已存在則拒絕覆蓋

**使用方式：**

```bash
# 列出可用備份（包含已刪除的 volumes）
pve-pure-config-get -s pure1 -v 100 -r -l

# 完整還原 VM（從已刪除的 volumes 恢復）
pve-pure-config-get -s pure1 -v 100 -n snap1 -r
```

**還原操作範例：**
```
$ pve-pure-config-get -s pure1 -v 100 -n snap1 -r

Restore mode: Will recover destroyed volumes and place config in PVE

Searching for config backups for VM 100...

Available config backups:
-------------------------------------------------------------------------
  No.  Snapshot Name  Volume                                  Status
-------------------------------------------------------------------------
     1  snap1          pve1::pve-pure1-100-vmconf-snap1        [DESTROYED]
-------------------------------------------------------------------------

Retrieving config from: pve1::pve-pure1-100-vmconf-snap1
Recovering destroyed config volume...
Config volume recovered.
Connecting volume to host 'pve-mycluster-pve1'...
...

=== Starting VM Restore ===
Found 1 disk volume(s) in config
Recovering destroyed volume: pve1::pve-pure1-100-disk0 ... OK

Connecting disk volumes to host 'pve-mycluster-pve1'...
Rescanning for devices...

Placing config in /etc/pve/qemu-server/100.conf...
Cleaning up config volume...

============================================================
VM 100 restored successfully!
============================================================
Config file: /etc/pve/qemu-server/100.conf
Recovered volumes: 1

You can now start the VM from PVE web UI or CLI:
  qm start 100
```

**重要說明：**
- 即使 VM 已完全從 PVE 刪除也能運作
- Volumes 必須尚未從 Pure Storage 被 eradicate（仍在「Destroyed Volumes」中）
- 如果 PVE 中已存在該 VM 設定，還原會被拒絕（請先刪除或使用其他 VMID）

## 已知限制

### Full Clone 限制

PVE 的 Full Clone 設計上會使用資料複製（`alloc_image` + `qemu-img`），而非呼叫 storage plugin 的 `clone_image`。這是 PVE 的架構設計，不是 Plugin 的限制。

**解決方案**：使用 Linked Clone。Pure Storage 會透過 snapshot 瞬間完成克隆。如果需要完全獨立的 Volume（不依賴 snapshot），可在 clone 後刪除 source snapshot。

### Snapshot 命名限制

Pure Storage snapshot 後綴只允許英數字元和連字號（`-`）。PVE snapshot 名稱中的底線和點號會自動轉換為連字號。

### 已刪除 Volume 的顯示

在 Pure Storage 上已刪除但尚未清除（eradicate）的 Volume 會自動從 PVE 列表中過濾掉。

## 疑難排解

### 建立 Volume 後裝置未出現

1. 檢查 iSCSI Session：
   ```bash
   iscsiadm -m session
   ```

2. 重新掃描裝置：
   ```bash
   iscsiadm -m session --rescan
   ```

3. 觸發 udev 更新：
   ```bash
   udevadm trigger
   ```

4. 檢查 Multipath：
   ```bash
   multipathd show maps
   multipath -ll
   ```

5. 重載 Multipath：
   ```bash
   multipathd reconfigure
   ```

### FC 裝置未出現

1. 檢查 FC HBA Port 是否為 Online：
   ```bash
   cat /sys/class/fc_host/host*/port_state
   ```

2. 檢查 FC Target Port 是否可見：
   ```bash
   ls /sys/class/fc_remote_ports/
   ```

3. 驗證 FC Zoning - 確認主機 WWPN 可以看到 Pure Storage Target WWPN：
   ```bash
   cat /sys/class/fc_host/host*/port_name
   cat /sys/class/fc_remote_ports/rport-*/port_name
   ```

4. 發送 LIP（Loop Initialization Primitive）重新掃描 Fabric：
   ```bash
   echo 1 > /sys/class/fc_host/host0/issue_lip
   ```

5. 重新掃描 SCSI Host 以發現新 LUN：
   ```bash
   echo "- - -" > /sys/class/scsi_host/host0/scan
   ```

6. 檢查 Multipath：
   ```bash
   multipathd show maps
   multipath -ll
   ```

### 認證失敗

1. 確認 API Token 正確且未過期
2. 檢查使用者在 Pure Storage 上是否有足夠權限
3. 測試 API 連線：
   ```bash
   curl -k -H "api-token: YOUR_TOKEN" https://PURE_IP/api/2.x/arrays
   ```

### 找不到 Volume

1. 確認 Volume 存在於 Pure Storage
2. 檢查 Volume 命名（應以 `pve-` 開頭）
3. 如使用 Pod，確認 Pod 名稱正確
4. 檢查 Volume 是否已刪除但尚未清除

### 列表效能緩慢

1. 確保使用最新版本的 Plugin（已優化 API 查詢）
2. Pod 設定使用 `pod.name` 過濾器提升效率
3. 檢查與 Pure Storage 管理介面的網路延遲

### Linked Clone 未顯示父子關係

如果 VM config 顯示 `vm-X-disk-Y` 而非 `base-X-disk-Y/vm-Z-disk-W`：
- Clone 是使用舊版 Plugin 建立的
- 需使用最新版本 Plugin 重新建立 Clone

## Pure Storage API 權限需求

API 使用者需要以下最低權限：

| 物件 | 權限 |
|------|------|
| Volume | 建立、刪除、列表、修改 |
| Host | 建立、刪除、列表、修改 |
| Host Group | 建立、刪除、列表、修改（使用 shared 模式時） |
| Snapshot | 建立、刪除、列表 |
| Pod | 列表（使用 ActiveCluster 時） |

## 從原始碼建置

```bash
cd /root/jt-pve-storage-purestorage

# 執行語法檢查
make test

# 建置 .deb 套件
make deb

# 本機安裝
make install
```

## 檔案位置

| 檔案 | 路徑 |
|------|------|
| Plugin 模組 | `/usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm` |
| API 模組 | `/usr/share/perl5/PVE/Storage/Custom/PureStorage/API.pm` |
| 設定取回工具 | `/usr/bin/pve-pure-config-get` |
| Storage 設定 | `/etc/pve/storage.cfg` |
| Multipath 設定 | `/etc/multipath/conf.d/pure-storage.conf` |

## 授權

MIT License

## 作者

Jason Cheng (Jason Tools)

## 特別致謝

特別感謝：
- **Pure Storage 原廠** - 提供優秀的儲存技術與完善的 REST API
- **MetaAge 邁達特（代理商）** - 協助提供測試設備與環境進行開發測試

## 相關連結

- [Pure Storage REST API 文件](https://support.purestorage.com/Solutions/FlashArray/Products/FlashArray/REST_API)
- [Proxmox VE Storage Plugin 文件](https://pve.proxmox.com/wiki/Storage)
