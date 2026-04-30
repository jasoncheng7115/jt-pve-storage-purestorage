# 疑難排解指南

語言 / Language: [English](TROUBLESHOOTING.md) | [繁體中文](TROUBLESHOOTING_zh-TW.md)

## 請先閱讀：Multipath 安全規則

在使用 Pure 的 PVE 節點上做任何 `multipath` 操作之前，請務必記得：

1. **絕對不要使用 `multipath -F`** （大寫 F）。它會 flush 主機上**所有**
   未使用的 multipath map，包含當下剛好閒置的非 Pure 儲存。請一律使用
   小寫 `multipath -f /dev/mapper/<wwid>` 對特定裝置操作。
2. **使用 `systemctl restart multipathd`，而非 `reload`。** Reload 只會
   重新讀取設定檔。Restart 才會真正重新套用 device-mapper 狀態，這才是
   改變 per-device 參數時你想要的行為。
3. 若一個殘留 multipath 裝置因為 `queue_if_no_path` 排隊死亡 I/O 而無法
   flush，請使用以下序列 — **絕對不要**用 `-F`:
   ```bash
   multipathd disablequeueing map <wwid>
   dmsetup message <wwid> 0 fail_if_no_path
   multipath -f /dev/mapper/<wwid>
   # 若仍卡住：
   dmsetup remove --force --retry <wwid>
   ```
4. 外掛 (1.1.0+) 透過位於 `/var/lib/pve-storage-purestorage/<storeid>-wwids.json`
   的 WWID 追蹤檔，以及 `pvesm status` 中執行的 orphan 清理，**自動處理
   叢集範圍的清理**。多數情況下不應需要手動清理。

## 常見問題

### 1. 儲存沒有出現在 PVE

**症狀：**
- PVE Web UI 看不到儲存
- `pvesm status` 顯示儲存為 unavailable
- `pvesm status` 要 30+ 秒才回應

**解決方法：**

1. 檢查到 Pure Storage 管理介面的連線：
   ```bash
   curl -k https://<PURE_IP>/api/api_version
   ```

2. 確認 API token 正確：
   ```bash
   curl -k -X POST https://<PURE_IP>/api/2.26/login \
       -H "api-token: YOUR_TOKEN" -i
   ```
   應該得到 HTTP 200 並有 `x-auth-token` response header。

3. 檢查 PVE 日誌：
   ```bash
   journalctl -u pvedaemon -f
   ```

4. 若 `pvesm status` 回應緩慢 (10-35 秒），代表 API 不可達。外掛在
   15s × 2 retries ≈ 34s 內快速失敗。比這還久代表請求層出問題 — 檢查
   防火牆、DNS、MTU。

### 2. Volume 建立失敗

**症狀：**
- 建立 VM 磁碟時報錯
- "Failed to create volume" 訊息

**解決方法：**

1. 檢查 Pure Storage 容量 (Web UI > Storage > Array space）。

2. 確認 Pure host 物件存在 （檢查 Web UI > Storage > Hosts):
   - per-node 模式：應看到 `pve-<cluster>-<nodename>`
   - shared 模式：應看到 `pve-<cluster>-shared`

3. 在 Pure UI Storage > Volumes 下檢查命名衝突。

4. 對同一 VM 並行配置可能會碰到 disk-id 衝突；外掛會重試最多 5 次。
   若你遇到持續性的衝突，代表其中一個 worker 可能留下了部分 Volume — 請在
   Pure UI 檢查孤兒 `pve-*` Volume。

### 3. Volume 建立後裝置沒有出現

**症狀：**
- VM 磁碟在陣列上已建立但本機找不到裝置路徑
- VM 啟動失敗並報 "cannot find device"

**解決方法：**

1. 確認該 Volume 已連線到此節點的 host (Pure UI > Volumes > 該 Volume >
   Connected Hosts）。

2. 檢查 iSCSI session （每個 Pure portal 一個 session):
   ```bash
   iscsiadm -m session
   ```
   Pure 控制器在多個 LIF 之間共用一個 IQN，所以你應該看到 N 個 session,
   N 是 Pure iSCSI portal 的數量。

3. 強制 rescan （外掛會自動做，只有手動除錯時才需要）:
   ```bash
   iscsiadm -m session --rescan
   for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h"; done
   multipathd reconfigure
   udevadm trigger --subsystem-match=block
   udevadm settle --timeout=5
   ```

4. 檢查 multipath 狀態：
   ```bash
   multipathd show maps
   multipathd show paths
   multipath -ll | grep -A4 "PURE"
   ```

5. 外掛的 `path()` 重試迴圈執行最多 `pure-device-timeout` 秒 （預設 30,
   可以針對個別儲存設定）。若仍找不到裝置，你會看到清楚的錯誤訊息，內含
   `multipath -ll` 等除錯提示。

### 4. `qm resize` 失敗並回報 "Cannot grow device files"

**症狀：** Pure 顯示新的 Volume 大小，但 PVE / QEMU 回報 `Cannot grow device files`。

**原因：** 這是 1.1.2 修正的 resize bug — `volume_resize` 之後的 host
scan 沒有重新整理既有裝置的容量。若你在 1.1.2 或更新版本，不應該再發生。

**若升級到 1.1.2+ 之後仍發生：**

```bash
# 手動執行外掛應該做的事:
WWID=$(... 查出該 Volume 的 WWID ...)
DEV=/dev/mapper/$WWID
SLAVES=$(ls /sys/block/$(basename $(readlink $DEV))/slaves/)
for s in $SLAVES; do echo 1 > /sys/block/$s/device/rescan; done
multipathd resize map $(basename $DEV)
blockdev --getsize64 $DEV   # 應該顯示新的大小
```

### 5. 快照 rollback 後讀到過期資料

**症狀：** `qm rollback` 之後，VM 讀到 rollback 之前的資料。

**原因：** 這是 1.1.2 修正的 rollback cache bug — rollback 之後沒有讓
kernel page cache 失效。若你在 1.1.2 或更新版本，不應該再發生。

**若升級之後仍發生**，請停機 VM 再啟動以清除 qemu 自身的 cache。

### 6. 叢集節點上的殘留 multipath 裝置

**症狀：** 節點 B 的 `multipath -ll` 顯示一個陣列上已不存在的 Pure 裝置
（因為節點 A 刪除了該 Volume）。

**解決方法：** 這正是 orphan 清理機制要解決的問題。在節點 B 上執行
`pvesm status pure1`；清理會在 backgrounded grandchild 中執行，在數秒內
就會清掉殘留裝置。

若沒有清掉 （例如清理本身因為 hang 而失敗），請檢查 WWID 追蹤檔：

```bash
cat /var/lib/pve-storage-purestorage/<storeid>-wwids.json
```

若殘留 WWID 在裡面但裝置仍存在，代表清理失敗。檢查
`journalctl -u pvedaemon` 中 `_cleanup_orphaned_devices` 的錯誤訊息。
最後手段請使用上方安全規則中的手動清理序列。

若殘留 WWID **不**在追蹤檔中但 `multipath -ll` 看得到它，代表它不是
Pure 管理的 — 可能是舊版外掛的殘留或手動建立的 LUN。外掛會印 Phase 3
警告但不會自動清理。

### 7. iSCSI session 數量不對

**症狀：** `iscsiadm -m session` 顯示的 session 數量少於 Pure iSCSI
portal 的數量。

**原因 (1.0.x bug):** 1.1.0 之前的 `is_target_logged_in()` 只檢查 IQN,
但 Pure 控制器在多個 LIF 之間共用一個 IQN，所以第二與後續 portal 的登入
會 silent 變成 no-op。

**1.1.0+ 修正：** 登入改用 `is_portal_logged_in($portal_addr, $target)`,
正確檢查 (portal, target) 配對。

**若你在 1.1.0+ 仍看到此症狀：** 確認 Pure portal 從此節點可達
(`ping`、`nc -vz <portal_ip> 3260`)，並檢查 `/etc/iscsi/iscsid.conf` 中
的 `node.startup = automatic`。

### 8. 認證錯誤

**症狀：**
- 每個 API 呼叫都回 "401 Unauthorized"
- "Authentication failed" 訊息

**解決方法：**

1. 外掛會在 401 時自動 re-auth 重試 (1.1.0+）。若你看到持續性 401,
   代表 API token 真的無效。
2. 在 Pure Storage Web UI 重新產生 API token (Settings > API Tokens）。
3. 更新儲存設定：`pvesm set pure1 --pure-api-token <NEW_TOKEN>`。
4. 確認使用者有 Volumes/Hosts/Connections 的 create+delete+read+update 權限。

### 9. `pvesm status` 緩慢或卡住

**症狀：** `pvesm status` 超過 35 秒，或永遠卡住。

**原因：** API 或網路問題，**或**清理 background fork 中有 wedged
multipath 裝置造成 kernel D-state hang。

**解決方法：**

1. 檢查 `ps -eo state,pid,cmd | grep '^D'`。若看到 D state 行程，
   代表你有 wedged 裝置 — 參考上方「殘留 multipath 裝置」。
2. 用 `curl` 檢查 API 可達性 （參考問題 1）。
3. 外掛的 `pvesm status` 最差情況是約 35 秒 (15s × 2 API retries）。
   若超過，代表 background fork 中有東西 hang 住，而它不應該擋住父行程。

### 10. 外掛警告 "DANGEROUS MULTIPATH SETTINGS"

**症狀：** 在 `dpkg -i ...purestorage...deb` 期間，postinst 印出紅色警告
框，提到 `/etc/multipath.conf` 中有 `no_path_retry queue` 或
`dev_loss_tmo infinity`。

**這是正確行為。** 那些設定加上殘留 Pure 裝置會把 PVE daemon 拖進不可
中斷睡眠，需要重新啟動節點。外掛**不會**自動修改你的設定；你必須手動
修正。

編輯 `/etc/multipath.conf`，修改 `defaults` 區塊：

```
defaults {
    polling_interval        10
    no_path_retry           30      # 原本: queue
    fast_io_fail_tmo        5
    dev_loss_tmo            60      # 原本: infinity
}
```

然後 `systemctl restart multipathd` (**不要**用 `reload`）。

### 11. 外掛警告 "STALE PURE MULTIPATH DEVICES"

**症狀：** Postinst 印出黃色警告，列出所有路徑都失敗的 Pure multipath
裝置。

**這是來自舊版外掛或手動連接的 LUN 的殘留。** 外掛**不會**自動清理。
請對列出的每個裝置使用上方安全規則中的手動清理序列。

清理之後，下次 `pvesm status pure1` 的 orphan 清理會自動防止它們再次
出現。

## 診斷指令

### 外掛狀態

```bash
# 確認外掛已載入
pvesm pluginlist

# 檢查儲存狀態 (健康陣列上應 < 5s 回應)
time pvesm status

# 列出 Volume
pvesm list <storage-id>

# 顯示 WWID 追蹤狀態
cat /var/lib/pve-storage-purestorage/<storeid>-wwids.json | python3 -m json.tool
```

### Pure Storage 連線

```bash
# API 可達性
curl -k https://<PURE_IP>/api/api_version

# 認證
curl -k -X POST https://<PURE_IP>/api/2.26/login -H "api-token: TOKEN" -i

# 列出 Volume (將 SESSION_TOKEN 替換為 login 回應的 x-auth-token)
curl -k -H "x-auth-token: SESSION_TOKEN" https://<PURE_IP>/api/2.26/volumes
```

### 區塊裝置狀態

```bash
# 此節點上的 Pure multipath 裝置
multipath -ll | grep -A6 "PURE"

# 特定裝置
multipath -ll <wwid>

# multipath 裝置的 slave 裝置
ls /sys/block/$(basename $(readlink /dev/mapper/<wwid>))/slaves/

# multipath 裝置的 holder (LVM、dm-crypt 等)
ls /sys/block/$(basename $(readlink /dev/mapper/<wwid>))/holders/
```

### iSCSI

```bash
# 所有 session (應該每個 Pure portal 一個)
iscsiadm -m session

# 詳細 session 檢視 (含 LUN)
iscsiadm -m session -P 3

# Targets (探索後)
iscsiadm -m node
```

### Fibre Channel

```bash
# HBA port 狀態 (全部 Online?)
cat /sys/class/fc_host/host*/port_state

# 透過 fabric 看到的 Pure target port
cat /sys/class/fc_remote_ports/rport-*/port_state
```

### 日誌

```bash
# PVE daemon (大多數外掛 warn() 輸出在這裡)
journalctl -u pvedaemon -f

# Kernel multipath / SCSI 訊息
dmesg | grep -E "multipath|scsi|sd|dm-" | tail -50

# iSCSI daemon
journalctl -u iscsid -f

# Postinst 警告 (下次安裝時)
dpkg -i jt-pve-storage-purestorage_*.deb 2>&1 | tee /tmp/postinst.log
```

## 取得協助

若仍有問題：

1. 跑 `docs/TESTING_zh-TW.md` Section 16 的 smoke test — 那 4 個迴歸
   測試直接驗證最容易咬人的 bug 類別。
2. 從本指南收集診斷輸出。
3. 檢查專案 README 的疑難排解段落。
4. 在 GitHub 開 issue，並附上：
   - 外掛版本 (`dpkg -l jt-pve-storage-purestorage`)
   - PVE 版本 (`pveversion`)
   - Pure 型號與 Purity//FA 版本
   - 錯誤訊息與相關日誌
   - `multipath -ll` 與 `iscsiadm -m session` 輸出
   - `/var/lib/pve-storage-purestorage/<storeid>-wwids.json` 內容
