Host-side stability release. Removes a standing SAN-rescan load that Proxmox VE triggered on every status poll, fixes a hang inside the command timeout handler, reworks device discovery, and corrects Pure REST 2.x timestamp handling.

主機端穩定性釋出。移除 Proxmox VE 每次狀態輪詢都會觸發的常態 SAN 重新掃描負載，修正指令逾時處理器內部的卡死，重寫裝置探索流程，並修正 Pure REST 2.x 的時間戳記處理。

---

## Highlights / 重點

### 1. No more full SAN rescan on every pvestatd poll (CRITICAL)

Proxmox VE calls `activate_storage()` from `PVE::Storage::storage_info()` on every pvestatd poll (~10s), sequentially for every configured storage. `activate_storage()` unconditionally performed an iSCSI session rescan, a SCSI host scan, a host-wide `multipathd reconfigure`, and `udevadm trigger --subsystem-match=block` + `udevadm settle` on each of those calls — a full multipath rebuild and a re-trigger of every block device on the node, six times a minute, on every node.

Beyond the standing cost, it competed directly with device discovery: a VM start or backup waiting for a newly mapped LUN was racing a reconfigure that repeatedly tore the map table down and rebuilt it.

Rescans now run immediately when the node logs in to a new iSCSI portal, and otherwise at most once per `pure-rescan-interval` (default 300s). `multipathd reconfigure` is throttled process-wide to once per 30s on all discovery paths. Discovery of new LUNs is unaffected — `activate_volume()`, `path()` and `alloc_image()` each run their own targeted rescan and wait.

Proxmox VE 每次 pvestatd 輪詢（約 10 秒）都會由 `PVE::Storage::storage_info()` 對每個已設定的 storage 循序呼叫 `activate_storage()`，而 `activate_storage()` 在每一次呼叫中都無條件執行 iSCSI session 重新掃描、SCSI host 掃描、全主機 `multipathd reconfigure`，以及 `udevadm trigger --subsystem-match=block` 與 `udevadm settle`——等於每個節點每分鐘做六次完整 multipath 重建與全系統區塊裝置重新觸發。

除了常態成本之外，它更直接與裝置探索互相競爭：正在等待新對應 LUN 的 VM 啟動或備份作業，等於在跟一個不斷拆除並重建對應表的 reconfigure 賽跑。

現在只有在本節點登入新的 iSCSI portal 時才會立即重新掃描，其餘情況最多每 `pure-rescan-interval`（預設 300 秒）一次；`multipathd reconfigure` 在所有探索路徑上以行程範圍限流為每 30 秒一次。新 LUN 的探索不受影響——`activate_volume()`、`path()` 與 `alloc_image()` 各自會針對所需的 WWID 執行專屬的重新掃描與等待。

### 2. Hang inside the command timeout handler (HIGH)

The `_run_cmd` timeout handler in `Multipath.pm` and `ISCSI.pm` ran `kill('TERM', $pid)` followed by a **blocking** `waitpid($pid, 0)`. A child in uninterruptible sleep — precisely the case these timeouts exist to survive — cannot be killed by `TERM` or `KILL`, so the blocking `waitpid` never returned, and the alarm that would have broken us out had already fired and been cleared. The timeout handler itself became the hang.

It now escalates `TERM` to `KILL` and reaps only with `WNOHANG` on a bounded poll, leaving an unreapable child to init rather than joining it in D state.

`Multipath.pm` 與 `ISCSI.pm` 的 `_run_cmd` 逾時處理器原本執行 `kill('TERM', $pid)` 之後接一個**會阻塞的** `waitpid($pid, 0)`。處於不可中斷睡眠（D state）的子行程——正是這些逾時機制存在的理由——無法被 `TERM` 或 `KILL` 終結，因此阻塞的 `waitpid` 永遠不會返回，而原本能救我們出來的 alarm 早已觸發並被清除。逾時處理器本身變成了卡死點。

現在改為由 `TERM` 升級到 `KILL`，並只以 `WNOHANG` 在有限次數的輪詢中回收，若仍無法回收則交由 init 處理。

### 3. Device discovery wait loop reworked (HIGH, #13)

`wait_for_multipath_device()` probed for the device only at the **end** of a loop body that could consume the entire timeout budget on a degraded fabric. With a 60s budget and a 45s pass, the caller got a single look at the device — taken at the worst possible moment, immediately after a host-wide reconfigure churned the map table. A LUN that surfaced two seconds later was reported missing. It also never probed *before* rescanning, so the common case (the device is already present) paid the full cost anyway.

The loop is now an escalation ladder: probe first, then transport rescan, then SCSI host scan, then udev, and only from the second round a throttled reconfigure — with a cheap probe after every step and a ~1s poll between steps, deadline-aware at every stage.

The failure message now reports the host state **captured at failure time**: what `multipathd` currently sees (map count, Pure map count, whether a map exists for the WWID, whether its `/dev/mapper` node was created), other Pure WWIDs multipathd does see when ours is absent, matching `/dev/disk/by-id` links, and per-session iSCSI state read from sysfs — with an explicit note when sessions are not `LOGGED_IN`, since LUN rescan is only issued on `LOGGED_IN` sessions.

`wait_for_multipath_device()` 原本只在迴圈本體的**最後**才檢查裝置，而該本體在劣化的 fabric 上可能耗盡整個逾時預算。在 60 秒預算而單趟耗時 45 秒的情況下，呼叫端只會看到裝置一次——而且是在最糟的時間點，剛好在全主機 reconfigure 攪動對應表之後。晚兩秒才出現的 LUN 就會被判定為不存在。它也從不在重新掃描**之前**先檢查，因此最常見的情況（裝置其實已經在了）仍然要付出完整成本。

現在改為逐級升高的流程：先檢查，接著是傳輸層重新掃描、SCSI host 掃描、udev，只有從第二輪起才動用受限流的 reconfigure——每個步驟後都會再檢查一次，步驟之間以約 1 秒間隔輕量輪詢，且每個階段都會檢查截止時間。

失敗訊息現在會回報**在失敗當下擷取**的主機狀態：`multipathd` 當下看到的內容（對應總數、Pure 對應數、此 WWID 是否有對應、其 `/dev/mapper` 節點是否已建立）、找不到我們的 WWID 時 multipathd 確實看得到的其他 Pure WWID、相符的 `/dev/disk/by-id` 連結，以及直接自 sysfs 讀取的逐 session iSCSI 狀態——並在 session 非 `LOGGED_IN` 時明確標註，因為 LUN 重新掃描只會對 `LOGGED_IN` 的 session 發出。

### 4. Pod capacity reporting (MEDIUM, #10)

Pure volumes are thin, so a pod holding one 32 GiB volume reports 32 GiB provisioned with almost nothing written. A 3 GiB quota set afterwards therefore reads as 100% full immediately — while writing into the existing volume keeps working. Both halves are correct: the array **will** refuse the next volume create or grow in the pod, and it will **not** refuse writes to volumes that already exist. Nothing in the numbers said so.

`used` is now clamped to the quota so Proxmox VE is never handed `used > total`, and a pod at or over its quota logs an explanation once per hour including the raw `space` figures the array returned. New option `pure-pod-usage-metric` selects `provisioned` (default) / `virtual` / `physical`.

Pure 的 Volume 是精簡配置，因此一個內含 32 GiB Volume 的 pod 即使幾乎沒有寫入資料，其 provisioned 仍為 32 GiB。之後才設定的 3 GiB 配額會立刻顯示為 100% 已滿——而寫入既有 Volume 卻仍然正常。兩者都是正確的：陣列**會**拒絕該 pod 內的下一次 Volume 建立或擴充，但**不會**拒絕對既有 Volume 的寫入。過去這些數字並未說明這一點。

`used` 現在會被限制在配額之內，Proxmox VE 不會再拿到 `used > total`；達到或超過配額的 pod 每小時會記錄一次說明，內含陣列回傳的原始 `space` 數值。新增選項 `pure-pod-usage-metric` 可選 `provisioned`（預設）／`virtual`／`physical`。

---

## Also fixed / 其他修正

- **Pure REST 2.x timestamps are milliseconds** (1.x is ISO 8601, and the code assumed the opposite). Snapshot dates rendered ~53000 years out in the Web UI, and the orphaned temp-clone reaper's "older than one hour" test could never be true on a 2.x array, so orphaned temporary snapshot clones were never cleaned up — each holding a volume slot, a host connection on every node, and a stale multipath device.
- **Orphaned temp-clone cleanup removed from `activate_storage`.** It disconnects and destroys volumes on the array; that belongs in the background reaper `status()` already forks, not on a path polled every ~10s with the short-timeout health client.
- **API 2.x host lookup.** `names` does not accept wildcards, so `host_list("pve-<cluster>-*")` always returned empty and new volumes were pre-connected to the local node only. Wildcards now use the `filter` parameter.
- **N+1 REST lookup removed from `deactivate_storage`** — the WWID is derived from the serial the volume list already returned.
- **API client cache key** no longer collapses to the portal address, which made two storages on one array share a single client.
- **`filesystem_path()`** fails with an actionable message instead of a bare "storage is required"; it passed `$scfg->{storage}`, which Proxmox VE never sets.
- **`activate_volume()` tracks the volume WWID**, closing a gap where a volume activated without `path()` was invisible to cluster residual-device cleanup.
- **postinst** no longer reports another vendor's `device`-scoped multipath settings as a Pure hazard; the check is now scope-aware.

---

## New storage options / 新增選項

| Option | Default | Purpose |
|---|---|---|
| `pure-rescan-interval` | `300` | Minimum seconds between the periodic SAN rescans in `activate_storage`. Set to `0` for pre-1.1.22 behaviour. |
| `pure-pod-usage-metric` | `provisioned` | Which pod space figure is reported as `used`: `provisioned` / `virtual` / `physical`. |

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.22-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node — the package uses `systemctl reload` to avoid the stop-phase hang on D-state children, but reload does not reload Perl modules on many Proxmox VE versions, so pvestatd would keep running the old plugin code from memory:

在**每一個**叢集節點執行——套件採用 `systemctl reload` 以避免 D state 子行程造成的 stop 階段卡死，但在許多 Proxmox VE 版本上 reload 不會重新載入 Perl 模組，pvestatd 會繼續執行記憶體中的舊程式碼：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

---

## Compatibility / 相容性

Verified against Proxmox VE 9.0 / 9.1 / 9.2 (`pve-manager 9.2.5`, `libpve-storage-perl 9.1.2`, kernel 7.0). Plugin `APIVERSION` 13 matches the storage `APIVER` exactly; no bump required.

已對 Proxmox VE 9.0／9.1／9.2 驗證（`pve-manager 9.2.5`、`libpve-storage-perl 9.1.2`、kernel 7.0）。外掛 `APIVERSION` 13 與 storage `APIVER` 完全相符，無需調整。

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)

Reported by @pulipulichen (#13, #10)
