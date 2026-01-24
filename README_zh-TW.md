# Pure Storage FlashArray Storage Plugin for Proxmox VE

**Language / 語言：** [English](README.md) | [繁體中文](README_zh-TW.md)

此 Plugin 讓 Proxmox VE 9.1 以上版本可以透過 iSCSI 或 Fibre Channel 協定使用 Pure Storage FlashArray 作為 VM 和 Container 的磁碟儲存。

> **⚠️ 免責聲明**
>
> 本專案為新開發項目，尚未經過大規模生產環境驗證。
>
> - **iSCSI**：基本功能已測試，但尚未進行大規模驗證
> - **Fibre Channel**：尚未完整驗證，可能存在未發現的問題
>
> **使用風險自負。** 作者不對因使用本 Plugin 而造成的任何資料遺失、系統停機或其他損害承擔責任。請務必在非生產環境中充分測試後，再部署到生產系統。使用前請確保已有適當的備份。

## 功能特色

### 儲存操作
- 直接 Volume 配置（無需傳統 SAN 的 LUN 間接層）
- 線上磁碟擴充（不需重啟 VM）
- 自動配置 Pure Storage 裝置的 Multipath

### Snapshot 與 Clone
- 透過 Pure Storage 原生 snapshot 實現瞬間建立/刪除/還原
- 從 Template 進行 Linked Clone（瞬間完成，使用 Pure Storage snapshot clone）
- RAM Snapshot 支援（Include RAM 選項）
- Clone 依賴保護（Pure Storage 會防止刪除有 clone 依賴的 snapshot）

### 高可用性
- 叢集感知，支援 Live Migration（Volume 會連接到所有節點）
- ActiveCluster Pod 支援同步複製
- 自動在 Pure Storage 上註冊 Host

### 協定支援
- iSCSI 自動 Target 探索與登入
- Fibre Channel WWN 自動偵測
- Multipath I/O 自動配置

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
dpkg -i jt-pve-storage-purestorage_1.0.35-1_all.deb
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

### 使用 ActiveCluster Pod 設定

```bash
pvesm add purestorage pure1 \
    --pure-portal 192.168.1.100 \
    --pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    --pure-protocol iscsi \
    --pure-pod prod-pod \
    --content images,rootdir
```

### 設定選項

| 選項 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `pure-portal` | 是 | - | Pure Storage 陣列管理 IP 或主機名稱 |
| `pure-api-token` | 否* | - | API Token 認證 |
| `pure-username` | 否* | - | API 使用者名稱 |
| `pure-password` | 否* | - | API 密碼 |
| `pure-ssl-verify` | 否 | 0 | 驗證 SSL 憑證（0=否, 1=是） |
| `pure-protocol` | 否 | iscsi | SAN 協定：`iscsi` 或 `fc` |
| `pure-host-mode` | 否 | per-node | Host 模式：`per-node` 或 `shared` |
| `pure-cluster-name` | 否 | pve | 用於 Host 命名的叢集名稱 |
| `pure-device-timeout` | 否 | 60 | 裝置探索逾時秒數 |
| `pure-pod` | 否 | - | ActiveCluster Pod 名稱（用於同步複製） |
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

# 查看磁碟大小
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
2. Pod 配置使用 `pod.name` 過濾器提升效率
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
