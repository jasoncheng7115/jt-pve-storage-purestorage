# 快速入門指南

語言 / Language: [English](QUICKSTART.md) | [繁體中文](QUICKSTART_zh-TW.md)

## 前置需求

1. Proxmox VE 9.1 或更新版本已安裝
2. Pure Storage FlashArray 已連線至網路
3. Pure Storage 的 API Token （建議） 或使用者憑證
4. 已安裝多路徑工具：`apt install multipath-tools open-iscsi sg3-utils psmisc`

## 請先閱讀：Multipath 安全規則

安裝前請務必先讀 `README_zh-TW.md` 中的「**重要：Multipath 安全規則**」
段落。最簡短的摘要：

- 絕對不要執行 `multipath -F` （大寫 F）。
- 使用 `systemctl restart multipathd`，而非 `reload`。
- 確認 `/etc/multipath.conf` 的 `defaults` 區塊**沒有**
  `no_path_retry queue` 或 `dev_loss_tmo infinity`。外掛在安裝時若偵測到
  會發出警告，但**不會**自動修正。

## 安裝步驟

### 步驟 1：安裝外掛

```bash
dpkg -i jt-pve-storage-purestorage_1.1.18-1_all.deb
```

請仔細閱讀 postinst 輸出。它會在你的 `/etc/multipath.conf` 含有危險設定
時警告，或在節點上偵測到既有的殘留 Pure multipath 裝置時警告。

### 步驟 2：確認相依服務

```bash
systemctl status iscsid
systemctl status multipathd
```

### 步驟 3：從 Pure Storage 取得 API Token

1. 登入 Pure Storage Web UI
2. 進入 Settings > API Tokens
3. 為 PVE 建立新的 API token
4. 複製該 token 字串

### 步驟 4：在 PVE 中加入儲存

```bash
pvesm add purestorage pure1 \
    --pure-portal <PURE_IP> \
    --pure-api-token <API_TOKEN> \
    --content images
```

若使用 Fibre Channel，加上 `--pure-protocol fc`。

### 步驟 5：確認儲存

```bash
pvesm status
```

你應該會在列表中看到 `pure1` 與其容量資訊，**回應時間應在 5 秒內**。
若超過 30 秒，請檢查 API 連線。

第一次啟用時也會建立
`/etc/multipath/conf.d/pure-storage.conf`，內含 Pure-friendly 設定
(`no_path_retry 30`、`fast_io_fail_tmo 5`、`dev_loss_tmo 60`) 與版本標記。
請確認：

```bash
head -3 /etc/multipath/conf.d/pure-storage.conf
# 應該看到一行 `# pure-multipath-config-version: 2`
```

### 步驟 6：建立測試 VM

1. 在 PVE Web UI 建立新 VM
2. 選擇 `pure1` 作為磁碟儲存
3. 完成 VM 建立
4. 啟動 VM，在 guest 內跑一個小 `dd`，停機，銷毀
5. 確認 `multipath -ll | grep <wwid>` 為空 （無殘留裝置）

## 後續步驟

- 進階選項請見 [CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md)
- 常見問題請見 [TROUBLESHOOTING_zh-TW.md](TROUBLESHOOTING_zh-TW.md)
- 完整測試計畫請見 [TESTING_zh-TW.md](TESTING_zh-TW.md)，正式環境部署前
  必須先跑過。Section 16 （資料遺失與 ghost-LUN bug 類別的迴歸測試） 是
  正式環境部署的**必要**項目。
