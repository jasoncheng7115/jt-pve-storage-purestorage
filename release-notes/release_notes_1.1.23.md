Data-safety release. Every finding here is one variant of the same design mistake: a safety check that, when it could not complete, answered "safe to proceed" instead of "I do not know". Nothing in this release changes behaviour on a healthy node — it changes what happens on an unhealthy one.

**Recommended for everyone, and particularly urgent if you are on 1.1.22 or use Fibre Channel.**

資料安全釋出。本次每一項發現都是同一個設計錯誤的變形：安全檢查在自己無法完成時，回答的是「可以繼續」而不是「我不知道」。在健康的節點上，本次變更不影響任何正常操作；它改變的是節點不健康時會發生什麼事。

**建議所有人升級；若你目前是 1.1.22，或使用 Fibre Channel，尤其建議儘快。**

---

## Why upgrade urgently / 為什麼建議儘快升級

- **From 1.1.22**: that release fixed a millisecond/second timestamp bug which, as a side effect, started a background reaper that had never actually run before — and that reaper performed **unrecoverable** volume eradications. 1.1.23 makes every automated deletion recoverable.
- **Fibre Channel users**: up to and including 1.1.22 the plugin issued a **LIP (link reset)** from loops running every 2–3 seconds. See below.

- **從 1.1.22 升級**：該版修正了毫秒／秒的時間戳記錯誤，副作用是讓一個從未真正執行過的背景回收器開始運作——而那個回收器執行的是**不可復原**的 Volume 清除。1.1.23 讓所有自動刪除都可復原。
- **使用 Fibre Channel 者**：直到 1.1.22 為止，外掛會在每 2 至 3 秒執行一次的迴圈裡發送 **LIP（鏈路重置）**。詳見下方。

---

## CRITICAL — The in-use guard now fails closed / 使用中檢查改為 fail-closed

`is_device_in_use()` collapsed "I could not determine the answer" into "not in use". A `/proc/mounts` read that timed out, a `fuser` call killed by its own 5-second watchdog, or a device path that would not resolve all fell through to `return 0`.

For a raw Pure LUN attached to a running VM there is no mount point and no real holder — the kpartx partitions are deliberately ignored since v1.1.7 — so **`fuser` is the only positive signal that a guest has the device open**. A timed-out `fuser` therefore turned "a VM is using this disk" into "nothing is using this disk", precisely when the node was unhealthy enough for that watchdog to fire, and `free_image()` would go on to disconnect the volume from every host and destroy it.

New `device_usage_state()` returns `in-use` / `idle` / `unknown` with a human-readable reason. `is_device_in_use()` now treats `unknown` as in use, and callers report the reason so an operator sees *why* the plugin refused.

`is_device_in_use()` 把「我無法判斷」歸類成「沒有在使用」。`/proc/mounts` 讀取逾時、`fuser` 被自己的 5 秒看門狗殺掉、裝置路徑無法解析——全都會落到 `return 0`。

對一顆交給執行中 VM 使用的 raw Pure LUN 而言，沒有掛載點也沒有真正的 holder（kpartx 分割自 v1.1.7 起就被刻意忽略），因此 **`fuser` 是唯一會回報 guest 正持有該裝置的訊號**。`fuser` 一旦逾時，「有 VM 正在使用這顆磁碟」就變成「沒有任何東西在用」——而且恰好發生在節點不健康到足以觸發該看門狗的時候——接著 `free_image()` 會把該 Volume 從所有主機斷線並銷毀。

新增的 `device_usage_state()` 回傳 `in-use`／`idle`／`unknown` 並附上可讀的理由。`is_device_in_use()` 現在把 `unknown` 視為使用中，呼叫端也會回報理由，讓操作者看得到外掛「為什麼」拒絕。

## CRITICAL — A failed WWID lookup no longer disables the guard / WWID 查詢失敗不再讓保護失效

`free_image()`, `volume_snapshot_rollback()` and `create_base()` each did:

```perl
my $wwid = eval { $api->volume_get_wwid($pure_volname); };
if ($wwid) { ... the entire in-use check ... }
... destroy / overwrite anyway ...
```

so a single transient REST error skipped the check and ran the destructive operation unprotected. **Rollback was the worst case**: `volume_overwrite()` replaces the volume's contents outright and, unlike a destroy, has no eradication-delay recovery window. All three now retry once and then refuse with an actionable message.

三者原本都把查詢包在 `eval` 裡，失敗就跳過整段安全檢查，然後照樣銷毀或覆寫。**rollback 是最糟的情況**：`volume_overwrite()` 直接取代 Volume 的全部內容，且與銷毀不同，沒有 eradication delay 的復原窗口。現在都改為重試一次後拒絕，並給出可據以行動的訊息。

## HIGH — No automated path eradicates any more / 不再有任何自動路徑執行不可復原的刪除

The orphaned temp-clone reaper and the per-session temp-clone cleanup called `volume_delete()` without `skip_eradicate` — permanent deletion, no recovery window, from a background process. Both now soft-destroy, so **all 15 delete call sites in the plugin are recoverable** within the array's eradication delay.

The reaper additionally re-matches every candidate against the exact name `path()` generates (`pve-<storage>-...-temp-snap-access-<unix-ts>-<pid>`) rather than trusting the unanchored array-side glob, and requires **two independent age sources** to agree — the array's `created` timestamp and the unix timestamp baked into the name — before deleting.

殘留暫存複製回收與逐 session 的暫存複製清理，原本呼叫 `volume_delete()` 未帶 `skip_eradicate`——永久刪除、沒有復原窗口，而且是由背景程序發出的。兩者現在都改為軟銷毀，因此**外掛中全部 15 個刪除呼叫點都可復原**。

回收器另外會把每個候選對象重新比對 `path()` 產生的精確格式，不再信任陣列端沒有錨定的 glob；刪除前還要求**兩個互相獨立的年齡來源**都同意。

## HIGH — Fibre Channel: no more LIP on every rescan / 不再每次 rescan 都發 LIP

A Loop Initialization Primitive is a **link reset**, not a lookup. It forces every device behind that HBA port to re-login, **including LUNs belonging to other storage on the same HBA**. It contributes nothing to discovering a newly mapped LUN — the SCSI host scan does that via `REPORT_LUNS` on the existing session.

`rescan_fc_hosts()` issued one unconditionally, and it is called from `path()`'s retry loop (every 2s), `alloc_image()`'s wait loop (every 3s), `wait_for_multipath_device()`'s FC callback (every round) and — before v1.1.22 — `activate_storage()` on every pvestatd poll. LIP is now opt-in and unused by default. `FC.pm` also reads sysfs with a bounded timeout instead of a bare `open()`.

LIP 是**鏈路重置**，不是查詢。它會強迫該 HBA port 後面所有裝置重新登入，**包含同一張 HBA 上屬於其他儲存的 LUN**。而探索新對應的 LUN 根本不需要它——SCSI host 掃描透過既有 session 的 `REPORT_LUNS` 就能做到。

`rescan_fc_hosts()` 原本無條件發送，而呼叫它的都是緊密迴圈。LIP 現在改為選用，預設不使用。`FC.pm` 也改用有逾時保護的 sysfs 讀取。

## HIGH — The temp-clone reaper respects ownership / 暫存複製回收器尊重歸屬

A temp clone is connected only to the node that created it, but **every** node runs the reaper. Node A's own reaper is stopped by `is_device_in_use()`; node B has no local device, sails past that check, disconnects the clone from all hosts and destroys it. A snapshot-source operation running longer than an hour on node A — a `qemu-img convert` of a large disk routinely is — had its device pulled out from under it. The reaper now skips any temp clone still connected to another node.

暫存複製只連線到建立它的節點，但**每個**節點都在跑回收器。節點 A 自己的回收器會被 `is_device_in_use()` 擋下；節點 B 本機沒有裝置，直接越過該檢查，把它從所有主機斷線並銷毀。回收器現在會跳過仍連線到其他節點的暫存複製。

## HIGH — `alloc_image()` checks before replacing a state/cloudinit volume

This was the only destructive path in the plugin with no in-use check at all: on finding an existing `vm-<id>-state-<snap>` or `vm-<id>-cloudinit` volume it disconnected and destroyed it, with a `warn()` as the only trace. A volume holding a live suspended guest's RAM image would be discarded.

這是外掛中唯一完全沒有使用中檢查的破壞性路徑：發現同名 Volume 就直接斷線並銷毀，唯一的痕跡只有一行 `warn()`。若該 Volume 保存的是執行中暫停 guest 的 RAM 映像，就會被丟棄。

## HIGH — Two mirrored `volume_list()` calls that cancelled each other out

`volume_list()` takes one positional argument, but two call sites passed named arguments, so the pattern bound to the literal string `"pattern"`. `_cleanup_vm_config_volumes()` therefore never deleted anything, and `free_image()`'s "is this the VM's last disk?" test was always true. Together they presented merely as "config backup volumes leak". **Fixing either side alone would have started destroying config backups on the first disk deletion of a multi-disk VM**, while snapshots of the remaining disks still referenced them — so both are fixed together.

兩處以具名參數呼叫只吃位置參數的函式，導致 pattern 綁到字串常值 `"pattern"`。兩個 bug 互相抵消，只表現為「config 備份 Volume 洩漏」。**只修好其中一邊，多磁碟 VM 刪除第一顆磁碟時就會開始銷毀 config 備份**，因此兩者一併修正。

## HIGH — `pve-pure-config-get` cannot hang any more / 災難復原工具不會再卡死

The disaster-recovery tool used bare `system('mount', ...)` / `system('umount', ...)` with no timeout. A mount against a multipath device whose paths are gone enters uninterruptible sleep and never returns — and this tool only ever runs when storage is already in trouble, so that is the expected state, not an edge case. Ctrl-C does not help.

It also now picks the **newest** destroyed generation when a disk has been deleted and recreated several times (lexical sort picked the oldest, and the newer generations then aborted the restore on a name conflict), uses `PVE::INotify::nodename()` so it connects to the host object the plugin actually registered, and cannot abort a restore whose config has already been written.

這支工具原本用裸 `system('mount'/'umount')`，完全沒有逾時。對路徑已全斷的 multipath 裝置做 mount 會進入不可中斷睡眠而永遠不返回——而它本來就只在儲存已經出問題時才會被執行，連 Ctrl-C 都沒用。

它同時改為在磁碟被刪除重建多次時挑選**最新**的一代，改用 `PVE::INotify::nodename()`，並且不會在設定檔已寫入之後才中止。

## MEDIUM — Other hardening / 其他強化

- `remove_scsi_device()` verifies the device still carries the expected WWID before deleting it. The kernel reuses `/dev/sdX` names, so a concurrent rescan could hand the same name to an unrelated LUN whose path would then be removed.
- `volume_get_connections()` distinguishes "no connections" from "the query failed". Returning an empty list for both made `free_image()` skip the disconnect and destroy anyway, leaving orphaned host connections — the ghost LUNs behind the v1.1.3/v1.1.4 incident. `free_image()` now refuses to delete when connections cannot be listed.
- The last unbounded waits are gone; `_run_cmd()` and `sysfs_read_with_timeout()` preserve any alarm the caller had armed instead of clearing it with a bare `alarm(0)`.
- `postinst` adds `fuser` to its required-binary check.

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.23-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node. The package uses `systemctl reload` to avoid the stop-phase hang on D-state children, but reload does not reload Perl modules on many Proxmox VE versions, so pvestatd would keep running the old plugin code from memory:

在**每一個**叢集節點執行。套件採用 `systemctl reload` 以避免 D state 子行程造成的 stop 階段卡死，但在許多 Proxmox VE 版本上 reload 不會重新載入 Perl 模組：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

## Behaviour change to be aware of / 需要留意的行為變化

Destructive operations now **refuse** rather than proceed when the plugin cannot establish that a device is idle. On a node with a wedged device or an unreachable array you may see a disk deletion, snapshot rollback or template conversion fail with a message explaining exactly what could not be determined. That is intentional: retry once the underlying condition is resolved. Normal operation on a healthy node is unchanged.

破壞性操作在外掛無法確認裝置閒置時，現在會**拒絕執行**而不是繼續。在裝置卡住或陣列不可達的節點上，你可能會看到刪除磁碟、快照倒回或轉為範本失敗，並附上「究竟哪一項無法判定」的說明。這是刻意的：排除底層狀況後重試即可。健康節點上的正常操作不受影響。

---

## Compatibility / 相容性

Verified against Proxmox VE 9.0 / 9.1 / 9.2. Note that `APIVER` / `APIAGE` live in `libpve-storage-perl`, which versions independently of `pve-manager`: 9.1.2 reports 13/4 and 9.1.6 reports 15/6. The plugin continues to declare `APIVERSION 13` deliberately — it is the only value loadable on both, since a node whose `APIVER` is 13 **refuses** any plugin claiming a higher number.

已對 Proxmox VE 9.0／9.1／9.2 驗證。請注意 `APIVER`／`APIAGE` 位於 `libpve-storage-perl`，其版本與 `pve-manager` 各自獨立：9.1.2 為 13/4，9.1.6 為 15/6。外掛刻意維持宣告 `APIVERSION 13`——這是兩者都能載入的唯一值，因為 `APIVER` 為 13 的節點會**拒絕**任何宣告更高版本的外掛。

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)

Reported by @pulipulichen (#13, #10)
