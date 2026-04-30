# 設定指南

語言 / Language: [English](CONFIGURATION.md) | [繁體中文](CONFIGURATION_zh-TW.md)

## 儲存模型（快速回顧）

本外掛採 **direct volume provisioning（直接 Volume 供應）**：每一
顆 VM 磁碟都是 Pure Storage 上一個獨立的 Volume，大小即為當下要求
的容量。陣列上沒有任何「預先建立的大 LUN」或儲存集區在主機端被切
片。

```
Traditional pool-based SAN              This plugin
=========================               ===========

   1x big LUN on array                  Pure FlashArray
            |                              Volume   pve-...-100-d0
            v                              Volume   pve-...-100-d1
   LVM / LVM-thin on host                  Volume   pve-...-101-d0
   +------+ +------+ +-----+               Volume   pve-...-102-d0
   | LV   | | LV   | | ... |                    ...
   | -d0  | | -d1  | |     |
   +------+ +------+ +-----+
                                        one volume per VM disk;
   snapshots / clones at LVM            snapshots / clones / replication
   (array sees one LUN always           happen natively on the array
    "in use")
```

**對設定的影響：**
- 主機上不需要 `vgcreate` / `lvcreate` 步驟。
- `pure-host-mode`（下方）控制外掛如何把每顆 disk 的 volume 對應到
  host 連線 — `per-node` 將每個 volume 連到每個節點的 host（建議用
  於 Live Migration）；`shared` 整個叢集共用一個 host 物件。
- `pure-pod`（下方）把每顆 disk 的 volume 放進 ActiveCluster Pod，
  volume 名稱前綴為 `<pod>::`。

完整的儲存模型（含層級堆疊與逐 VM 資料服務影響），請參閱
[README_zh-TW.md → 儲存模型](../README_zh-TW.md#儲存模型)。

## 儲存設定選項

### 必要選項

| 選項 | 說明 |
|--------|-------------|
| `pure-portal` | Pure Storage 管理介面的 IP 位址或主機名稱 |

### 認證 （擇一）

| 選項 | 說明 |
|--------|-------------|
| `pure-api-token` | API token 認證 （建議） |
| `pure-username` + `pure-password` | API 認證的使用者名稱與密碼 |

### 選用選項

| 選項 | 預設 | 說明 |
|--------|---------|-------------|
| `pure-ssl-verify` | 0 | 驗證 SSL 憑證 (0=否， 1=是） |
| `pure-protocol` | iscsi | SAN 通訊協定： `iscsi` 或 `fc` |
| `pure-host-mode` | per-node | Host 模式： `per-node` 或 `shared` |
| `pure-cluster-name` | pve | 用於 host 命名的叢集名稱 |
| `pure-device-timeout` | 60 | 裝置探索逾時 （秒） |
| `pure-pod` | （無） | ActiveCluster pod 名稱。設定後，所有 Volume 都會以 `<pod>::` 為前綴建立 |

### Host 模式

- **per-node** （預設，基於安全性建議使用）：每個 PVE 節點對應一個 Pure
  host 物件，命名為 `pve-<cluster-name>-<nodename>`。每個 Volume 都會連線到所有
  節點的 host 以支援即時遷移。
- **shared**：單一 Pure host 物件包含所有節點的 WWPN/IQN，命名為
  `pve-<cluster-name>-shared`。對應較簡單但隔離性較差。

在 per-node 模式下，當 `_connect_to_all_hosts` 列舉叢集 host 時，
它會向陣列查詢 `pve-<cluster-name>-*` 的 host 物件。若你的叢集名稱包含
特殊字元，外掛會自動消毒，但建議用 `pvesm status` 驗證一下。

## 範例設定

### 基本 iSCSI 設定

```ini
purestorage: pure1
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    content images
    shared 1
```

### Fibre Channel 設定

```ini
purestorage: pure-fc
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-protocol fc
    content images
    shared 1
```

### Shared Host 模式

```ini
purestorage: pure-shared
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-host-mode shared
    pure-cluster-name production
    content images
    shared 1
```

### 啟用 SSL 驗證

```ini
purestorage: pure-secure
    pure-portal pure.example.com
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-ssl-verify 1
    content images
    shared 1
```

### ActiveCluster Pod

```ini
purestorage: pure-pod1
    pure-portal 192.168.1.100
    pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pure-pod testpod
    content images
    shared 1
```

此儲存上的所有 Volume 都會建立為 `testpod::pve-...`。外掛在透過 PVE 列出 Volume 時
會自動剝除前綴。

## Pure Storage API 使用者設定

### 建立 API 使用者

1. 登入 Pure Storage Web UI
2. 進入 Settings > Users
3. 為 PVE 整合建立新使用者
4. 指派適當的角色 (Storage Admin 或自訂）

### 建立 API Token

1. 以 API 使用者身分登入
2. 進入 Settings > API Tokens
3. 點選 "Create API Token"
4. 複製並安全保存該 token

### 必要權限

API 使用者所需的最低權限：
- Volumes: Create、Delete、Read、Update
- Hosts: Create、Delete、Read、Update
- Connections: Create、Delete、Read
- Snapshots: Create、Delete、Read

## Multipath 設定

外掛在第一次呼叫 `activate_storage` 時會自動建立
`/etc/multipath/conf.d/pure-storage.conf`。自動產生的檔案會帶有版本標記
(`# pure-multipath-config-version: 2`)；後續外掛升級時，標記版本變動會
自動重寫該檔案。**沒有標記行的檔案會被保留不動**，所以客戶手改的設定不會
被覆寫。

若你偏好自行管理 multipath.conf，請將下列 device 區塊放入
`/etc/multipath/conf.d/` 或 `/etc/multipath.conf`:

```
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
        fast_io_fail_tmo     5
        dev_loss_tmo         60
    }
}
```

修改後，**重新啟動** multipathd (**不要**用 `reload`):

```bash
systemctl restart multipathd
```

`reload` 只重新讀取設定檔。`restart` 才會真正重新套用 device-mapper 狀態，
這才是改變 per-device 參數時你想要的行為。

### 為什麼要這些特定設定?

| 設定 | 危險值 | 良好值 | 原因 |
|---------|-----------|------------|-----|
| `no_path_retry` | `queue` | `30` | `queue` = 無限佇列 → 殘留裝置上的 I/O 永遠卡住，把 PVE daemon 拖進 D state |
| `dev_loss_tmo` | `infinity` | `60` | `infinity` = 殘留 SCSI 裝置永遠不被移除 |
| `fast_io_fail_tmo` | 未設定 | `5` | 加速路徑失敗的偵測 |
| `failback` | `manual` | `immediate` | Pure 控制器是 active/active；自動再平衡 |
| `path_selector` | `round-robin` | `queue-length 0` | 對 Pure 的平行架構較佳 |

外掛自動產生的檔案會明確設定這些值，以覆蓋 `/etc/multipath.conf` 的
`defaults` 區塊中的任何危險值。

## iSCSI 設定

### 確認 iSCSI Initiator 名稱

```bash
cat /etc/iscsi/initiatorname.iscsi
```

外掛在每次登入時會把 `node.session.timeo.replacement_timeout` 設為 120
（必要時覆寫 `iscsid.conf`)，讓 Pure 控制器 failover 能順利恢復。

### 手動 iSCSI 探索 （僅供除錯）

外掛會自動處理探索與登入。手動操作只有在除錯時才需要：

```bash
iscsiadm -m discovery -t sendtargets -p <PURE_IP>
iscsiadm -m session
```

## Fibre Channel 設定

### 確認 FC HBA

```bash
cat /sys/class/fc_host/host*/port_name
cat /sys/class/fc_host/host*/port_state
```

所有 port 都應該是 `Online`。

### 確認對 Pure 的 FC zoning

```bash
cat /sys/class/fc_remote_ports/rport-*/port_state
```

你應該看到對應 Pure 目標 port 的 `Online` 項目。若沒有，請檢查此主機與
Pure 陣列之間的 FC switch zoning。

外掛的 `activate_storage` 會自動執行 FC rescan，鮮少需要手動 LIP/scan。

## 狀態與鎖檔目錄

外掛建立並使用兩個目錄 (mode 0700, root 擁有）:

| 路徑 | 用途 |
|------|---------|
| `/var/lib/pve-storage-purestorage/` | 持久化的 WWID 追蹤 JSON 檔 （每個儲存一份） |
| `/var/run/pve-storage-purestorage/` | 鎖檔 (tmpfs，重新啟動時清除） |

狀態檔 `<storeid>-wwids.json` 是叢集 orphan 清理機制用來在沒有執行刪除
操作的節點上找到殘留 multipath 裝置的依據。**不要手動編輯此檔。** 若需要
重置，請停用該儲存並刪除檔案；下次 `activate_storage` 會自動匯入陣列當前
的 WWID。
