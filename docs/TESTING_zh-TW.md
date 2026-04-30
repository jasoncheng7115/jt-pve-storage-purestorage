# Pure Storage Plugin 測試計畫

語言 / Language: [English](TESTING.md) | [繁體中文](TESTING_zh-TW.md)

本測試計畫用於驗證 jt-pve-storage-purestorage Proxmox VE 外掛在實體 Pure
Storage FlashArray 上的行為。每次發版前以及部署到正式環境前都應執行。

本計畫**針對 Pure Storage 特性**設計：每個章節都會點出 Pure 與其他廠商
不同之處，以及本外掛架構獨有的失敗模式。

## 作者
Jason Cheng (Jason Tools) — jason@jason.tools

---

## 0. 測試環境需求

必要：

- Proxmox VE 9.1+ 叢集 （建議 3 節點；最少 2 節點以驗證叢集行為；1 節點足以
  跑基本生命週期測試）
- Pure Storage FlashArray,REST API 可達 (1.x 或 2.x 任一版本，本外掛
  皆支援 — 兩條程式碼路徑都應分別測試）
- 每個 PVE 節點至少有 iSCSI **或** FC 連線到陣列。雙協定測試需執行兩次
- Pure host 物件預先清乾淨：沒有上一輪測試殘留的 `pve-*` host 物件
  （外掛會自動建立，但殘餘狀態可能掩蓋 bug)
- multipath 服務正在運作，且採用 postinst 建議的 Pure-friendly 設定
  (`no_path_retry 30`、`dev_loss_tmo 60`、`fast_io_fail_tmo 5`)

強烈建議：

- 同一節點上掛載非 Pure 儲存 （例如手動建立的 iSCSI LUN + LVM-thin、
  NFS、ZFS pool）。Section 6 多項測試會明確驗證外掛**不會**碰觸這些
  非 Pure 儲存
- 若要測 pod 模式，需要 ActiveCluster pod 測試陣列 (Section 11)
- 陣列上有權限可以停用/啟用 host port 的管理員帳號 — Section 8 失敗
  注入測試需要

測試資料慣例：

- `STOREID=pure1` （或你 `pvesm add` 用的任意名稱）
- `VMID=9001` 為主測試 VM，衍生 VM 編號遞增
- `WWID=3624a9370...` (Pure WWID 前綴為 `3624a9370`)

---

## 1. 基本連線與儲存啟動

| # | 測試 | 預期 | Pure 特性檢查 |
|---|------|------|---------------|
| 1.1 | `pvesm add purestorage pure1 ...` 使用 API token | 儲存新增成功 | `pvesm status` 顯示 pure1 active |
| 1.2 | 健康陣列上 `pvesm status pure1` 5 秒內返回 | Active,total/used/avail 有值 | 讀取 `arrays?space=true` (API 2.x) 或 `array?space=true` (1.x) |
| 1.3 | **無法連線**陣列上 `pvesm status pure1` 35 秒內返回 | Inactive (0,0,0,0),PVE daemon 不掛 | Section 4 的逾時上限 (15s × 2 retries ≈ 34s) 有被遵守 |
| 1.4 | iSCSI:`iscsiadm -m session` 顯示 N 個 session,N == Pure iSCSI portal 數 | 所有 portal 都已登入 | 測試 Section 2.1 的 per-portal 登入 (Pure 控制器共用 IQN) |
| 1.5 | iSCSI：重複執行 `pvesm status` 不會重新 discovery 已登入的 portal | 沒有新的 `iscsiadm -m discovery` 呼叫 | 驗證 activate_storage 的 skip-if-logged-in 最佳化 |
| 1.6 | FC:`cat /sys/class/fc_host/host*/port_state` 顯示 Online | 所有 HBA port 都 Online | FC HBA 透過 `is_fc_available()` 偵測 |
| 1.7 | 陣列上自動建立 Pure host 物件，包含本節點的 IQN/WWPNs | Pure UI 顯示 host 名為 `pve-<cluster>-<node>` | 驗證 `_ensure_host` 的 create-if-missing |
| 1.8 | 3 個節點同時 `pvesm status` 對全新陣列 | 全部成功，無 409 Conflict 失敗 | 測試 host_get_or_create 的競態處理 (Section 2.5) |
| 1.9 | 外部輪換 API token 後 `pvesm status` 下次呼叫 | 第一次可能 warn 401，第二次成功 (re-auth) | 測試 Section 4.1 的 401 retry with re-auth |

**Pure 關鍵特性：**Pure 控制器透過多個 portal IP 提供 iSCSI 但每個陣列
只共用一個 IQN。若 `is_target_logged_in()` 只檢查 IQN，在第一個 portal
登入成功後就會跳過後續所有 portal。測試 1.4 直接驗證 `is_portal_logged_in()`。

---

## 2. VM 磁碟生命週期 （單節點）

| # | 測試 | 預期 |
|---|------|------|
| 2.1 | 在 pure1 上建立有 10G 磁碟的 VM | 磁碟建立，Pure 上看到 `pve-pure1-9001-disk0` Volume |
| 2.2 | `qm start 9001`，然後 guest 內 `dd if=/dev/zero of=/dev/sdX bs=1M count=100` | I/O 成功，Pure UI 顯示 100MB 用量 |
| 2.3 | `qm shutdown 9001` → `qm destroy 9001` | Volume 在 Pure 上標記為 **destroyed** （不是 eradicated) |
| 2.4 | destroy 後：`multipath -ll \| grep <wwid>` | 該 Volume 沒有殘留項目 |
| 2.5 | destroy 後：`cat /var/lib/pve-storage-purestorage/pure1-wwids.json` | WWID 項目已移除 |
| 2.6 | destroy 後：開啟 Pure UI → Destroyed Volumes | Volume 在那邊，24h 內可救回 |
| 2.7 | 24h 內透過 Pure UI 手動救回 | Volume 恢復，`list_images` 再次看到 |

**Pure 特性 — soft delete:**Pure 在 `volume_delete` 時並不會真正銷毀 Volume，
而是移到 "destroyed" 狀態，有可設定的清除延遲 （預設 24h）。測試 2.6/2.7
確認外掛使用 `skip_eradicate => 1`，讓管理員可以從誤刪救回。

---

## 3. VM 操作：快照、調整大小、移動、複製

| # | 測試 | 預期 | Pure 特性 |
|---|------|------|---------|
| 3.1 | `qm snapshot 9001 snap1` | Pure 上建立快照 `<vol>.pve-snap-snap1` | 後綴只用 Pure 允許的字元 （英數 + 連字號） |
| 3.2 | 包含底線的快照名 (`my_snap`) | 編碼後綴 （例如 `my-snap` 或 `pve-snap-my-snap`)，無 API 錯誤 | 測試 `encode_snapshot_name` |
| 3.3 | 很長的快照名 (>30 chars) | 編碼後的名稱 + 後綴總長維持在 Pure 63 字元 Volume 名上限內 | 測試 `encode_config_volume_name` 的 config volume name 截斷 |
| 3.4 | `qm rollback 9001 snap1` | Volume 回滾，VM 從快照狀態啟動 | Pure 是 copy-on-write,rollback 應在 5 秒內完成 |
| 3.5 | `qm delsnapshot 9001 snap1` | 快照移除 (skip_eradicate) | 快照在 Pure 上為 "destroyed" 狀態 |
| 3.6 | VM 停機時 `qm resize 9001 scsi0 +5G` | Volume 在 Pure 上 resize | Pure 支援 online resize，但 PVE 在這裡走 offline 路徑 |
| 3.7 | VM 執行中時 `qm resize 9001 scsi0 +5G` | Online resize,rescan 後 guest 看到新大小 | 測試 volume_resize 中的 rescan |
| 3.8 | `qm resize 9001 scsi0 -1G` （縮小） | **拒絕**並有清楚錯誤訊息 | Pure 不允許縮小 |
| 3.9 | `qm move-disk 9001 scsi0 local-zfs` (Pure → 其他） | 磁碟搬移，Pure Volume 釋放，無殘留裝置 | 驗證搬移結束時 free_image 的清理 |
| 3.10 | `qm move-disk 9001 scsi0 pure1` （其他 → Pure) | 磁碟搬到 Pure,qemu-img 完成 | 透過 alloc_image 配置，然後寫入 path() 回傳的裝置 |
| 3.11 | 對執行中的 VM 做完整複製 (`qm clone 9001 9002`) | 新 VM 建立，qemu-img 透過 PVE 複製內容 | Pure 完整複製走 PVE — 比 linked clone 慢 |
| 3.12 | 將 VM 標記為範本 (`qm template 9001`) | Volume 上建立 `pve-base` 快照 | 驗證 clone_image 的範本路徑 |
| 3.13 | 從範本做 linked clone (`qm clone 9001 9003`) | 透過 Pure volume_clone 即時複製 | 應在 2 秒內完成 — Pure 是 copy-on-write |
| 3.14 | Linked clone 名稱格式檢查 | 回傳的 volname 是 `base-9001-disk-0/vm-9003-disk-0` | 驗證 linked clone 命名 |
| 3.15 | Cloud-init 磁碟掛載 (`qm set 9001 --ide2 pure1:cloudinit`) | 建立 4MB cloudinit Volume | alloc_image 中的特殊 case |
| 3.16 | EFI 磁碟在 Pure 上 (`qm set 9001 --efidisk0 pure1:1`) | 建立 4MB EFI vars Volume | 同 |
| 3.17 | TPM 狀態在 Pure 上 (`qm set 9001 --tpmstate0 pure1:4`) | 建立 4MB TPM Volume | 同 |
| 3.18 | LXC 容器磁碟在 Pure 上 (`pct create 9100 ... --rootfs pure1:8`) | rootfs 配置，容器啟動 | 外掛宣告支援 rootdir + images content |

---

## 4. 對既有 VM 增減磁碟 （熱插拔壓力）

這些是最容易在錯誤節點上殘留狀態的操作，也是促成叢集清理架構的元凶。

| # | 測試 | 預期 |
|---|------|------|
| 4.1 | `qm set 9001 --scsi1 pure1:8` （冷加） | 新 Volume 建立，對應到所有節點 |
| 4.2 | `qm set --delete scsi1 9001` （冷刪） | Volume 銷毀，**任何**節點都無殘留裝置 |
| 4.3 | VM 執行中時：`qm set 9001 --scsi1 pure1:8` （熱加） | guest 內看到磁碟，無節點掛起 |
| 4.4 | VM 執行中時：`qm set --delete scsi1 9001` （熱拔） | guest 內磁碟移除，無殘留裝置 |
| 4.5 | 4.4 後：**每個**節點 `multipath -ll` | 任何地方都沒有該 WWID 的殘留 |
| 4.6 | 4.4 後：**每個**節點的 WWID JSON 檔 | 項目已移除 |
| 4.7 | `qm unlink 9001 --idlist scsi1 --force` | Volume 從 VM config 取消連結，然後釋放 |

---

## 5. 快照存取 （臨時 clone 路徑）

Pure 快照無法直接掛載 — 外掛會建立臨時 Volume clone 來讀取快照內容。這是
Pure 獨特的行為。

| # | 測試 | 預期 |
|---|------|------|
| 5.1 | `pvesm extractconfig pure1:vm-9001-disk-0/snap1` | 從臨時 clone 讀取，回傳 config |
| 5.2 | 5.1 後：Pure 上看到臨時 clone | 名稱為 `<vol>-temp-snap-access-<ts>-<pid>` |
| 5.3 | 5.1 後 + 30s + `pvesm status` | 背景清理會跳過該臨時 clone (1 小時內） |
| 5.4 | 5.1 後 + 1 小時+ 手動執行 `_cleanup_orphaned_temp_clones` | 臨時 clone 銷毀 |
| 5.5 | 備份 VM (`vzdump 9001 --storage pure1` 或 local) | 透過快照路徑讀取，成功完成 |
| 5.6 | 從 vzdump 備份還原 VM 到 Pure | 配置新 Volume，內容還原 |
| 5.7 | `snapshot` 模式備份 | 外掛建立 Pure 快照，透過臨時 clone 讀取，清理 |
| 5.8 | `stop` 模式備份 | 不需要快照路徑 |
| 5.9 | VM config 備份 Volume (`pve-pure1-9001-vmconf-snap1`) 在 Pure 快照建立時產生 | 1MB ext4 Volume，內含 VM config 與 metadata |
| 5.10 | `pve-pure-config-get pure1 9001 snap1` | CLI 工具透過備份 Volume 取回 config |
| 5.11 | `pve-pure-config-get --restore pure1 9001 snap1` | 將 VM config 還原到 /etc/pve/qemu-server/9001.conf |

---

## 6. 叢集殘留 / Orphan 清理 （這個外掛存在的核心理由）

這是**最重要的章節**。外掛之所以維護 WWID 追蹤檔並在 `status()` 中執行
orphan 清理，正是因為 Pure Volume 會在每個叢集節點被 iSCSI rescan 自動發現，
而某節點上的刪除動作會在其他節點留下殘留裝置。

### 6.1 叢集啟動時自動匯入

| # | 測試 | 預期 |
|---|------|------|
| 6.1.1 | 新節點加入叢集：`pvesm status pure1` | 約一分鐘後 `<storeid>-wwids.json` 包含該節點可看到的所有 Pure Volume WWID |
| 6.1.2 | WWID 檔案符合陣列上的 `pve_*` LUN 列表 | 所有陣列 LUN 都自動匯入 |
| 6.1.3 | 在節點 A 建立 Volume → 節點 B `pvesm status` 後 | 節點 B 的 WWID 檔有新項目 （來自自動匯入） |

### 6.2 叢集 orphan 清理

| # | 測試 | 預期 |
|---|------|------|
| 6.2.1 | 在**節點 A** 建立 VM 9001 磁碟 | Volume + multipath 裝置在所有節點上 |
| 6.2.2 | 在 A/B/C 上驗證 `multipath -ll \| grep <wwid>` | 三個節點都看到該裝置 |
| 6.2.3 | 在 A/B/C 上驗證 WWID 檔包含該 wwid | 是 (A 來自 path(),B/C 來自自動匯入） |
| 6.2.4 | 在節點 A 上 destroy VM | Volume 從陣列消失，A 的本地裝置清掉，A 的 WWID 移除追蹤 |
| 6.2.5 | 立即在 B 上：`multipath -ll \| grep <wwid>` | 殘留項目**仍然存在** （還沒有事件觸發清理） |
| 6.2.6 | 在 B 上：`pvesm status pure1` （觸發 double-fork 清理） | 約 5 秒內 orphan 清理就會清掉殘留裝置 |
| 6.2.7 | 6.2.6 後：B 與 C 的 `multipath -ll` | 任何地方都無殘留 |
| 6.2.8 | 6.2.6 後：B 與 C 的 WWID 檔 | 項目已移除 |
| 6.2.9 | 模擬清理失敗的情況下重複 6.2.4 | WWID 維持追蹤狀態，下次 `pvesm status` 重試清理 |

### 6.3 混合環境安全 (`multipath -F` 教訓）

| # | 測試 | 預期 |
|---|------|------|
| 6.3.1 | 掛載手動非 Pure iSCSI LUN，無 I/O | Multipath 看到非 `PURE` 裝置 |
| 6.3.2 | 跑數次 `pvesm status pure1` 循環 | 該非 Pure 裝置**完全不會**被碰觸、列出或警告 |
| 6.3.3 | 掛載手動 Pure LUN （這個外掛之外） → Pure 顯示它 | 外掛 orphan 清理記錄 Phase 3 警告但**不會**自動清 |
| 6.3.4 | 在程式碼/postinst 中 grep `multipath -F` | 只在安全警告中出現；從未作為可執行的指令 |
| 6.3.5 | 用一行語法呼叫 `multipath_flush()` 不傳引數 | 用安全訊息 croak |

---

## 7. PVE 工作流程操作

| # | 測試 | 預期 |
|---|------|------|
| 7.1 | 對同一 VM 跑 10 次 `qm start/stop` 循環 | 無檔案洩漏、無 session 洩漏、無殘留裝置 |
| 7.2 | `qm reboot` | Volume 維持連線 |
| 7.3 | `qm migrate 9001 nodeB` （線上遷移） | Volume 已對應到 nodeB，遷移成功不需重新加 LUN |
| 7.4 | `qm migrate 9001 nodeB --online --with-local-disks` （儲存遷移到 B 上的 Pure) | B 上建立新 Volume，內容搬移，來源 Volume 釋放 |
| 7.5 | `vzdump 9001 --storage local --mode snapshot` | 透過 Pure 快照臨時 clone 讀取，無殘留臨時 clone |
| 7.6 | `qmrestore <backup> 9050 -storage pure1` | 磁碟還原到 Pure |
| 7.7 | 多磁碟 VM (4× Pure 磁碟）：建立、快照、回滾、銷毀 | 所有磁碟處理，無 orphan，共用單一 config 備份 Volume |
| 7.8 | 帶 vmstate 的 VM (`qm snapshot --vmstate`) | 狀態 Volume `vm-9001-state-snap1` 在 Pure 上配置、寫入，delsnapshot 時清理 |

---

## 8. 失敗注入 (Pure-specific)

這些測試需要陣列管理員配合啟用/停用 port，或用 iptables 替代。

### 8.1 單一 iSCSI LIF 阻斷

```
# 在 PVE 主機上用 iptables 阻擋一個 Pure 控制器 iSCSI port:
iptables -I OUTPUT -d <pure_ct0_iscsi_ip> -j DROP
```

| # | 測試 | 預期 |
|---|------|------|
| 8.1.1 | guest 內跑 `dd` 時 | I/O 透過剩餘路徑繼續 |
| 8.1.2 | `multipath -ll` 顯示路徑 failed | 其他路徑仍 active |
| 8.1.3 | `pvesm status pure1` | 仍在 35s 內返回，無 D-state |
| 8.1.4 | 移除 iptables 規則，等待 `replacement_timeout` | 路徑自動恢復 |

### 8.2 所有 iSCSI portal 都阻斷

```
iptables -I OUTPUT -d <pure_mgmt_ip> -j DROP
iptables -I OUTPUT -d <pure_ct0_iscsi_ip> -j DROP
iptables -I OUTPUT -d <pure_ct1_iscsi_ip> -j DROP
```

| # | 測試 | 預期 |
|---|------|------|
| 8.2.1 | `pvesm status pure1` | 約 35s 內回傳 inactive |
| 8.2.2 | 沒有 PVE daemon 掛起，`pveproxy` web UI 仍可回應 | 是 |
| 8.2.3 | 任何 D state process?`ps -eo state,pid,cmd \| grep '^D'` | 無 |
| 8.2.4 | 解除阻擋後，`pvesm status pure1` | 恢復為 active |

### 8.3 API 不可達

```
iptables -I OUTPUT -d <pure_mgmt_ip> -p tcp --dport 443 -j DROP
```

| # | 測試 | 預期 |
|---|------|------|
| 8.3.1 | `pvesm status pure1` | 約 35s 內回傳 (0,0,0,0) |
| 8.3.2 | 既有 VM 操作 (start/stop) 仍可運作 | 是 — 只有依賴 API 的操作快速失敗 |
| 8.3.3 | Web UI 顯示儲存為 inactive 但不會凍結 | 是 |

### 8.4 Pure 控制器 failover

| # | 測試 | 預期 |
|---|------|------|
| 8.4.1 | guest 內跑 `dd` 時請 Pure 管理員把 CT0 → CT1 failover | I/O 短暫暫停 (replacement_timeout 視窗），然後恢復 |
| 8.4.2 | `multipath -ll` 顯示原本 active 的路徑變 failed | 是 |
| 8.4.3 | failback 後：`multipath -ll` 顯示所有路徑 active | 是 |

### 8.5 「queue_if_no_path」+ 殘留裝置掛起情境

這是促使整個殘留清理設計誕生的 bug。修復前必須可重現，修復後不得發生。

| # | 測試 | 預期 |
|---|------|------|
| 8.5.1 | 在 /etc/multipath.conf 中設 `no_path_retry queue`，重新啟動 multipathd | 設定生效 |
| 8.5.2 | 在本節點配置 Pure Volume，取得其 multipath 裝置 | 裝置存在 |
| 8.5.3 | 在陣列上 (Pure UI / API) **手動刪除**該 Volume，**不**透過外掛 | Volume 從陣列消失 |
| 8.5.4 | `pvesm status pure1` → 觸發 orphan 清理 | 殘留裝置被清理，**且**沒有任何 process 進入 D state |
| 8.5.5 | 測試後 `ps -eo state \| grep '^D'` | 無 D-state process |
| 8.5.6 | 與舊版本 (1.0.x) 比對：重複 8.5.3 然後 `vgs` | 舊版本會把 `vgs` 卡在 D state — 證明這是迴歸測試 |

### 8.6 並行 free_image 競態

| # | 測試 | 預期 |
|---|------|------|
| 8.6.1 | 兩個節點同時 destroy 同一 VM | 都成功 （一個贏在 volume_delete；另一個拿到 "not found" → no-op) |
| 8.6.2 | 兩個 PVE worker 同時對同一 VM 加磁碟 | 一個成功，另一個 catch collision 並 bump disk-id (Section 7.1 重試迴圈） |

---

## 9. API 版本覆蓋

外掛同時支援 Pure REST API 1.x 與 2.x。兩條程式碼路徑都必須測試。

| # | 測試 | 預期 |
|---|------|------|
| 9.1 | 強制 API 1.x：儲存 config 中 `--api-version 1.19` | 對同一陣列以 1.x 跑 sections 1–8 全過 |
| 9.2 | 強制 API 2.x:`--api-version 2.26` | 對同一陣列以 2.x 跑 sections 1–8 全過 |
| 9.3 | 自動偵測：省略 api-version | 外掛選 2.x,activate 時記錄 |
| 9.4 | API 2.x 從第二節點 PATCH host 的 WWN | 驗證 host 的 wwns 陣列**同時**包含兩節點 WWPN （測試 fetch-merge-patch 修正） |
| 9.5 | API 2.x Volume 名在 query string 帶 `pod::` 前綴 | 外掛正確 URL-encode `::`，無 400 |

---

## 10. 命名邊界情境

| # | 測試 | 預期 |
|---|------|------|
| 10.1 | 快照名 `my-snap` （已合法） | 直接使用 |
| 10.2 | 快照名 `my_snap` （底線） | 編碼 — 驗證 decode round-trip |
| 10.3 | 大小寫混合的快照名 | 維持原樣編碼，正確解碼 |
| 10.4 | 帶連字號的儲存名 (`pure-prod`) | Volume 名用底線 (`pve_pure_prod_*`) |
| 10.5 | VM ID > 9999 | Volume 名仍在 Pure 63 字元上限內 |
| 10.6 | 強制截斷的長快照名做 config volume | `_backup_vm_config` 截斷 snapname 讓總長 ≤ 63 |
| 10.7 | 包含點的叢集名 | host name `pve-<cluster>-<node>` 經過 sanitize |

---

## 11. Pod (ActiveCluster) 模式 — 僅在有設定 pod 時測

| # | 測試 | 預期 |
|---|------|------|
| 11.1 | `pvesm add purestorage pure-pod1 --pure-pod testpod ...` | 儲存 active，所有 Volume 有 `testpod::` 前綴 |
| 11.2 | 建立 VM 磁碟 → 陣列上 Volume 名 `testpod::pve-...` | 是 |
| 11.3 | `list_images` 在 PVE 顯示時剝除 `testpod::` | 是 |
| 11.4 | `parse_volname` 處理 pod 內的 state/cloudinit Volume | 測試 1.0.49 修正 — 過去 decode 前未剝除 pod 前綴 |
| 11.5 | Pod failover （管理員動作） → 在 stretched cluster 上 I/O 持續 | 是 |
| 11.6 | Pod 對陣列遷移：更改 pod 設定，重新啟動儲存 | Volume 仍正確列出 |

---

## 12. Per-Node 對 Shared host 模式

| # | 測試 | 預期 |
|---|------|------|
| 12.1 | `pure-host-mode per-node` （預設）：每節點各自的 Pure host | 一節點一 host,host name `pve-<cluster>-<nodename>` |
| 12.2 | `pure-host-mode shared`：單一共用 host 包含所有 WWPN | 一個 host `pve-<cluster>-shared` 包含所有節點 WWPN |
| 12.3 | shared 模式 + `_connect_to_all_hosts` | 只連線到單一共用 host （不迭代） |
| 12.4 | per-node + `_connect_to_all_hosts` | 連線到 `host_list` 回傳的每個 `pve-<cluster>-*` host |

---

## 13. 效能 / sanity

| # | 測試 | 可接受 |
|---|------|--------|
| 13.1 | `pvesm status pure1` p50 latency | < 1s |
| 13.2 | `pvesm status pure1` p99 latency | < 5s |
| 13.3 | 不健康陣列上 `pvesm status pure1` 最差情況 | < 35s |
| 13.4 | `qm clone` linked clone 牆鐘時間 | < 5s |
| 13.5 | `qm clone` 對 10G Volume 做完整 clone 牆鐘時間 | 受 qemu-img 複製速度限制 (PVE 限制） |
| 13.6 | 對含 200 Volume 的儲存執行 `pvesm list pure1` | < 10s (template 偵測 deadline 必要時觸發） |
| 13.7 | 在迴圈中 10 個並行 alloc_image | 全部成功，無洩漏 Volume 或裝置 |

---

## 14. 升級路徑

| # | 測試 | 預期 |
|---|------|------|
| 14.1 | 安裝 1.0.49 → 跑 sections 1-3 → 升級到 1.1.0 → 重跑 sections 1-3 | 全部通過 |
| 14.2 | 升級後 postinst 對既有殘留 Pure 裝置警告 （若有） | 是 (postinst Section 6.2) |
| 14.3 | 升級後 postinst 對危險的 multipath.conf 設定警告 （若有） | 是 |
| 14.4 | 升級後第一次 `pvesm status` 建立 `<storeid>-wwids.json` | 是 （自動匯入） |
| 14.5 | 既有執行中的 VM 不需重新啟動 | 是 |

---

## 15. 測試結果記錄

每次發版時，將以下範本複製到 `docs/RELEASE_NOTES.md` （或附在 release):

```
外掛版本: 1.x.y-1
測試環境: PVE 9.1.x, kernel 6.x.x
Pure FlashArray 型號: //X70R3 (或實際型號)
Pure Purity//FA 版本: 6.x.x
測試的 API 版本: [1.19] [2.26]
測試的協定: [iSCSI] [FC]
叢集大小: 3 節點
測試者: <名字>
測試日期: YYYY-MM-DD

通過的章節: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
跳過的章節: <清單與原因>
失敗的章節: <預期為無>

關鍵情境驗證:
[ ] Section 8.5 (queue_if_no_path + 殘留裝置，無 D-state 掛起)
[ ] Section 6.2 (叢集 orphan 清理 E2E)
[ ] Section 4 (熱插拔殘留預防)
[ ] Section 1.4 (Pure 共用 IQN 上的 per-portal iSCSI 登入)
```

---

## 16. Symlink 解析迴歸測試 (1.1.2)

這些測試防範 1.1.2 修正的 4 個 bug。每個測試直接驗證其中一個。任何
觸動 `is_device_in_use`、`get_multipath_slaves`、`volume_resize`、
或 `volume_snapshot_rollback` 的版本發佈前，這些測試**必須**全通過。

### 16.1 對執行中 VM 做 resize (Bug A 迴歸）

```bash
qm create 8000 --name resize-test --memory 256 --cores 1 \
  --scsi0 pure1:1 --kvm 0
qm start 8000
sleep 5

# 應成功，不可出現 "Cannot grow device files"
qm resize 8000 scsi0 +1G

# 驗證主機真的看到新大小
DEV=$(pvesm path pure1:vm-8000-disk-0)
blockdev --getsize64 $DEV   # 預期: 2147483648 (2 GB)

qm stop 8000
qm destroy 8000 --purge
```

**通過條件：** `qm resize` 回傳 0、沒有 `Cannot grow device files`、
`blockdev --getsize64` 對 multipath 裝置顯示新大小。

### 16.2 LVM-on-Pure 資料遺失防護 (Bug D 迴歸 — 重大）

```bash
# 配置 Pure Volume
pvesm alloc pure1 8000 vm-8000-disk-0 1G
DEV=$(pvesm path pure1:vm-8000-disk-0)

# 在上面放 LVM — 模擬客戶把 Pure Volume 當成 PV 使用
pvcreate $DEV
vgcreate test_vg $DEV
lvcreate -L 100M -n test_lv test_vg
mkfs.ext4 /dev/test_vg/test_lv
mkdir -p /mnt/test
mount /dev/test_vg/test_lv /mnt/test

# is_device_in_use 此時必須回傳 true
perl -Ilib -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::PureStorage::Multipath qw(is_device_in_use);
my $r = is_device_in_use($ARGV[0]);
print "in_use=$r\n";
exit($r ? 0 : 1);
' "$DEV"

# 在 in-use 狀態下嘗試 free_image 必須拒絕，不可沉默刪除
pvesm free pure1:vm-8000-disk-0 2>&1 | grep -i "in use"

# 清理
umount /mnt/test
lvremove -f test_vg/test_lv
vgremove test_vg
pvremove $DEV
pvesm free pure1:vm-8000-disk-0
```

**通過條件：**
- `is_device_in_use` 回傳 1
- `pvesm free` 用 in-use 錯誤訊息拒絕
- 失敗的 free 之後，Volume 上的 LVM 資料完整無損

**失敗模式 （資料遺失 bug):** 若 `is_device_in_use` 回傳 0,`pvesm free`
會沉默地銷毀該 Volume，客戶的 LVM 資料就消失了。這正是 1.1.2 修正所防範
的正式環境情境。

### 16.3 對 /dev/mapper/<wwid> 呼叫 get_multipath_slaves (Bug C 迴歸）

```bash
DEV=$(pvesm path pure1:vm-8000-disk-0)   # /dev/mapper/3624a9370...
perl -Ilib -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::PureStorage::Multipath qw(get_multipath_slaves);
my $s = get_multipath_slaves($ARGV[0]);
print "slaves=", scalar(@$s), "\n";
print "  $_\n" for @$s;
exit(@$s > 0 ? 0 : 1);
' "$DEV"
```

**通過條件：** 回傳 N 個 slave,N 等於 `multipath -ll` 顯示的活躍路徑數。
修正前此函式對 `/dev/mapper/<wwid>` 路徑回傳 0 個 slave。

### 16.4 快照 rollback 後快取失效 (Bug B 迴歸）

```bash
# 建立 Volume，寫入已知 pattern
qm create 8000 --memory 256 --scsi0 pure1:1 --kvm 0
DEV=$(pvesm path pure1:vm-8000-disk-0)
dd if=/dev/zero of=$DEV bs=1M count=1 conv=fsync

# 快照
qm snapshot 8000 snap1

# 用不同 pattern 覆寫
dd if=/dev/urandom of=$DEV bs=1M count=1 conv=fsync

# 讀第一個位元組 （應該是亂數，不是 0)
HEX_BEFORE=$(dd if=$DEV bs=1 count=4 2>/dev/null | xxd | head -1)

# Rollback
qm rollback 8000 snap1

# 再讀第一個位元組 — 必須是 0 （快照 pattern），不是 page cache 中
# 殘留的亂數 pattern
HEX_AFTER=$(dd if=$DEV bs=1 count=4 iflag=direct 2>/dev/null | xxd | head -1)
echo "rollback 前: $HEX_BEFORE"
echo "rollback 後: $HEX_AFTER"

qm destroy 8000 --purge
```

**通過條件：** rollback 之後的讀取回傳快照內容 （零值），而不是 rollback
之後的亂數 pattern。修正前 page cache 仍持有 post-snapshot 的頁面，
讀取會沉默地回傳過期資料。

---

## 17. iSCSI Host 過濾迴歸測試 (1.1.5)

此測試防範 Bug 1 迴歸：`rescan_scsi_hosts()` **絕對不可**寫入非
iSCSI 的 scsi_host。任何具有混合 scsi_host 傳輸層的主機都應跑此
測試 （幾乎任何真實伺服器都至少有主機板上的 SATA 控制器作為
`host0`）。

```bash
# 顯示 host 清單
echo "所有 scsi_host:"
ls /sys/class/scsi_host/
echo "僅 iSCSI:"
ls /sys/class/iscsi_host/ 2>/dev/null || echo "(無 iSCSI 活動)"

# 用 strace 追蹤 rescan，看實際寫入哪些 scan 檔
strace -f -e trace=openat 2>&1 \
  perl -I/usr/share/perl5 \
       -e 'use PVE::Storage::Custom::PureStorage::Multipath qw(rescan_scsi_hosts);
           rescan_scsi_hosts(delay => 0)' \
  | grep -oE "/sys/class/scsi_host/host[0-9]+/scan" \
  | sort -u
```

**通過條件：** strace 輸出**只**能包含 `/sys/class/iscsi_host/` 內出現
的 host 編號。若看到任何不在 iSCSI 清單中的 host （例如 `host0/scan`
而 `host0` 是 SATA 控制器），代表修正失效，bug 已回退。

**為什麼這很重要：** 對 HPE smartpqi / Dell PERC / LSI HBA 的非 iSCSI
host scan 檔案寫入，會在 kernel 中造成 600+ 秒的 D-state 掛起。
`sysfs_write_with_timeout` **無法**防範此問題 — D-state 子行程無法被
SIGKILL 收回。唯一安全的防護是「一開始就不執行該操作」。

---

## 快速 smoke test (5 分鐘，單節點）

如果完整測試計畫太長，絕對最低限度的 smoke test 是：

1. `pvesm status pure1` 5 秒內回 active
2. 在測試 VM 上建立 1GB 磁碟，啟動，寫 100MB，停機，銷毀
3. destroy 後 `multipath -ll | grep <wwid>` → 空
4. destroy 後 `cat /var/lib/pve-storage-purestorage/pure1-wwids.json` → 項目已移除
5. 再次 `pvesm status pure1` → 仍在 5 秒內回應

五項全過，代表外掛至少基本可用。任何正式部署或發版前都應跑完整計畫。
