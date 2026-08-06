Correctness release. Three of these are silent: the plugin and Proxmox VE disagreed about something, and nothing in either reported an error.

正確性釋出。其中三項是無聲的：外掛與 Proxmox VE 對某件事的認知不一致，而兩邊都不會報錯。

---

## CRITICAL — Linked clones could gain a phantom "unused" disk pointing at the live volume

`clone_image()` returns `base-102-disk-0/vm-104-disk-0` for a linked clone, and that is what the guest config stores. `list_images()` reported the bare `vm-104-disk-0`.

`PVE::QemuServer::update_disk_config` — the code `qm rescan` drives — marks a volume referenced using the volid from the config, then checks that set against the volids the plugin reports. With the two forms disagreeing, the volume looked unreferenced and Proxmox VE called `add_unused_volume()`. The guest ended up with an `unusedN` entry pointing at **the same Pure volume its `scsi0` was running on**, and removing that "unused disk" in the GUI destroys the live disk.

`list_images()` now derives the base from Pure's `source` field and emits the `base/clone` form. Only a `.pve-base` snapshot source is accepted, so full clones and clones taken from user snapshots keep their bare name — matching on anything else would invent a dependency that does not exist and produce the mirror image of this bug. When the array does not report `source` the behaviour is unchanged. `RBDPlugin::list_images` does the equivalent from the rbd parent snapshot.

`clone_image()` 對 linked clone 回傳 `base-102-disk-0/vm-104-disk-0`，guest 設定存的也是這個，但 `list_images()` 回報的是單純的 `vm-104-disk-0`。

`PVE::QemuServer::update_disk_config`——`qm rescan` 實際執行的程式——會用設定檔裡的 volid 標記「已被引用」，再拿這組去比對外掛回報的 volid。兩種形式不一致時，該 Volume 看起來就是沒被引用，Proxmox VE 於是呼叫 `add_unused_volume()`。guest 因此多出一個 `unusedN`，**指向它 `scsi0` 正在使用的同一顆 Pure Volume**；操作者在 GUI 移除這個「未使用磁碟」，就會銷毀使用中的磁碟。

`list_images()` 現在會從 Pure 的 `source` 欄位推導 base，並輸出 `base/clone` 形式。只接受 `.pve-base` 快照作為來源，因此 full clone 與從使用者快照建立的複製仍維持單純名稱。當陣列未回報 `source` 時，行為與先前相同。

> **If you have linked clones**, run `qm rescan --vmid <id> --dryrun` after upgrading and confirm it no longer proposes an `unusedN` entry. If a phantom entry was already added by an earlier `qm rescan`, remove it from the guest config with `qm set <id> --delete unusedN` — do **not** use the GUI's "Remove" button on it, which would destroy the volume.
>
> **若你有 linked clone**，升級後請執行 `qm rescan --vmid <id> --dryrun`，確認它不再提議新增 `unusedN`。若先前的 `qm rescan` 已經加進了幽靈項目，請用 `qm set <id> --delete unusedN` 從設定檔移除——**不要**在 GUI 上按該項目的「移除」，那會銷毀 Volume。

---

## HIGH — Container backups leaked a Pure volume per mountpoint, indefinitely

`PVE::VZDump::LXC` calls `activate_volumes($cfg, $volids, 'vzdump')`, which lands in our `path()` and creates a snapshot-access clone on the array, connects it to the host and waits for its multipath device. It then mounts, rsyncs, umounts and deletes the `vzdump` snapshot — and never calls `deactivate_volume` at all (`grep -c deactivate_volume VZDump/LXC.pm` returns zero), so the plugin's own cleanup was never invoked.

That is one leaked Pure volume, one host connection and one local multipath device per container mountpoint per backup run. The one-hour orphan reaper was the only backstop, and per the millisecond-timestamp bug fixed in v1.1.22 it never ran at all on an API 2.x array — so sites with scheduled container backups have been accumulating these since the plugin was installed.

Cleanup is now triggered from `volume_snapshot_delete()`, which Proxmox VE does reliably call, with the same ownership, age and in-use gates as the background reaper.

`PVE::VZDump::LXC` 透過我們的 `path()` 建立快照存取用的複製，卻**完全不會呼叫 `deactivate_volume`**，因此外掛自己的清理從未被觸發。每個容器 mountpoint、每次備份，洩漏一顆 Pure Volume、一條主機連線、一個本機 multipath 裝置。唯一的後備是一小時的殘留回收器，而依 v1.1.22 修正的毫秒時間戳記問題，它在 API 2.x 陣列上根本從未執行過——因此有排程容器備份的站點，從安裝外掛以來就一直在累積這些。

**Check for a backlog after upgrading / 升級後檢查是否已有累積：**

```bash
journalctl -t pvestatd | grep temp-clone
```

or look for volumes matching `pve-<storage>-*-temp-snap-access-*` in the Pure UI. The reaper releases them (soft-destroy, recoverable within the array's eradication delay) on its own schedule.

或在 Pure UI 搜尋符合 `pve-<storage>-*-temp-snap-access-*` 的 Volume。回收器會依自己的排程釋放它們（軟銷毀，在陣列的 eradication delay 內可復原）。

---

## HIGH — Resizing a disk did not reach the local device

The local refresh in `volume_resize()` was gated on `$running`. Resize a stopped VM's disk and the local multipath map keeps the old size; start the guest and qemu presents the old capacity to it, with no error anywhere. The same applied to resizing on one node and starting the guest on another, which no amount of gating could have covered.

**This also fixes container resize, which had never worked on this plugin.** `PVE::API2::LXC` always calls `volume_resize(..., $running = 0)` — its own comment says the parameter only makes sense for QEMU — so the gated refresh never ran for a container at all. Proxmox VE then maps the volume and runs `resize2fs` against a device still reporting the old capacity, and the failure surfaces only as a `warn`. The array volume grew, the CT config recorded the new size, and the filesystem did not change.

The refresh now runs unconditionally — it is a no-op when this node has no local device for the volume — and `activate_volume()` reconciles the array size it has already fetched against `blockdev --getsize64`, rescanning only when they disagree. The whole refresh is best-effort: the array-side resize has already succeeded by then, so a local failure must not be reported as a failed resize.

`volume_resize()` 的本機刷新被 `$running` 判斷包住。在 VM 停機時調整大小，本機 multipath map 仍維持舊容量；啟動 guest 後 qemu 交給它的就是舊容量，而且任何地方都不會報錯。在某個節點調整、在另一個節點啟動也是同樣結果。

**這同時修好了容器的 resize——它在本外掛上從來沒有真正生效過。** `PVE::API2::LXC` 呼叫 `volume_resize(..., $running = 0)` 時 `$running` 恆為 0（它自己的註解說明該參數只對 QEMU 有意義），因此被判斷式包住的刷新對容器完全不會執行。Proxmox VE 接著對應該 Volume 並執行 `resize2fs`，面對的是仍回報舊容量的裝置，而失敗只會以一行 `warn` 呈現。陣列上的 Volume 變大了、CT 設定記下了新大小，檔案系統卻沒有任何改變。

> **If you previously resized a container** and it did not gain space, re-running `pct resize <id> rootfs +0G` will not help (Proxmox VE rejects a zero/shrinking change). Resize it again by any positive amount after upgrading, or run `resize2fs` manually against the mapped device.
>
> **若你先前調整過容器大小**而它沒有變大，升級後再調整一次（任意正值增量）即可，或手動對已對應的裝置執行 `resize2fs`。

---

## MEDIUM — `$vollist` was matched by prefix

`$vollist` holds complete volids and the base plugin compares them exactly. A prefix match returned `vm-10-disk-10` and `vm-10-disk-11` when asked for `vm-10-disk-1`. No current Proxmox VE caller passes a vollist, but returning volumes the caller did not ask for is how "the migration moved a disk I did not select" happens.

`$vollist` 裝的是完整 volid，base plugin 是精確比對。前綴比對在查詢 `vm-10-disk-1` 時會一併回傳 `vm-10-disk-10` 與 `vm-10-disk-11`。目前 Proxmox VE 沒有呼叫者會傳 vollist，但回傳呼叫端沒有要求的 Volume，正是「遷移搬走了我沒選的磁碟」的成因。

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.24-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node / 在**每一個**叢集節點執行：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
