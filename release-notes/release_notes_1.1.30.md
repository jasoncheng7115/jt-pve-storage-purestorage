Consistency release for LXC containers. QEMU guests are not affected.

容器一致性釋出。QEMU guest 不受影響。

---

## HIGH — A running container's snapshot was quiesced by nothing at all

Proxmox VE takes a guest snapshot as freeze → snapshot → thaw. For LXC the freeze has two layers, and only one of them ran:

| Layer | Who decides | What we got |
|---|---|---|
| Processes (cgroup freeze) | Proxmox VE, unconditional | ran |
| **Filesystem (`FIFREEZE`)** | **the storage, via `volume_snapshot_needs_fsfreeze()`** | **did not run** |

This plugin did not implement `volume_snapshot_needs_fsfreeze()`, so it inherited the base `0`. Freezing the container's processes stops new writes, but it does not push out the dirty pages the host kernel is already holding — and a container's filesystem is mounted by the **host** kernel, so those pages are real. Our snapshot is then taken by the array over REST, entirely out of band from this host's block layer, and copies only what the array has actually received.

The plugin's own second line of defence did not run either. `volume_snapshot()` does a `sync` and a `blockdev --flushbufs`, but they were guarded by:

```perl
if ($device && -b $device && !is_device_in_use($device)) {   # before
```

so they were skipped **precisely when a container was running on the device** — the one case with dirty pages to flush.

Both mechanisms therefore failed in the same scenario. Running container snapshots — **including vzdump backups in snapshot mode**, which go through the same path — were crash-consistent rather than filesystem-consistent. On restore, the filesystem needs journal recovery and recently written application data can be missing.

`PVE::Storage::RBDPlugin` returns 1 from the same method for the same reason: a snapshot taken by a remote system cannot see this host's cache. Local-snapshot storages such as LVM-thin and ZFS correctly inherit 0, because there the same kernel owns both the filesystem and the snapshot.

**QEMU guests were never affected.** Their filesystem quiescing is done by the guest agent from `PVE::QemuConfig`, which never consults this method.

Proxmox VE 取得 guest 快照的流程是「凍結 → 快照 → 解凍」。LXC 的凍結分兩層，而只有一層有作用（見上表）：行程層的 cgroup freeze 是 Proxmox VE 無條件執行的；**檔案系統層**只有在 storage 透過 `volume_snapshot_needs_fsfreeze()` 要求時才會執行，而本外掛沒有實作，繼承了 base 的 `0`。

凍結行程只能停止新的寫入，不會把主機核心已經持有的 dirty page 寫出去——而容器的檔案系統是由**主機**核心掛載的，那些 page 是真實存在的。接著陣列透過 REST 取得快照，與本機的 block layer 完全無關，只會複製到陣列實際收到的內容。

外掛自己的第二道防線同樣沒有作用。`volume_snapshot()` 裡的 `sync` 與 `blockdev --flushbufs` 被 `!is_device_in_use($device)` 包住，因此**正好在容器執行於該裝置上時被跳過**——那正是有 dirty page 需要寫出的情況。

兩道機制在同一個情境下同時失效。執行中容器的快照——**包含 snapshot 模式的 vzdump 備份**，走的是同一條路徑——都只是 crash-consistent，而非檔案系統一致。還原時檔案系統需要 journal 復原，最近寫入的應用資料可能遺失。

`PVE::Storage::RBDPlugin` 基於相同理由也回傳 1：遠端系統取得的快照看不到本機的 cache。LVM-thin、ZFS 這類本機快照的 storage 則正確地繼承 0，因為那裡的檔案系統與快照由同一個核心掌管。

**QEMU guest 從來不受影響**：它們的檔案系統一致性由 `PVE::QemuConfig` 的 guest agent 處理，完全不會用到這個方法。

> **Existing snapshots and backups are not retroactively fixed.** Container snapshots taken before this release remain crash-consistent. They are still usable — a journalling filesystem recovers on mount — but if you have a container running a database and you keep long-lived snapshots as a recovery point, consider taking a fresh one after upgrading.
>
> **既有的快照與備份不會被追溯修正。** 本次釋出之前取得的容器快照仍然是 crash-consistent。它們仍然可用（日誌式檔案系統掛載時會自行復原），但若你的容器內執行資料庫、而且長期保留某個快照作為復原點，建議升級後重新取得一份。

---

## Also / 其他

- `rename_snapshot()` and `volume_snapshot_info()` are now refused explicitly. The inherited implementations route through `filesystem_path()`, which this plugin cannot implement (Pure volume names are derived from the storage id, which Proxmox VE does not pass to that method), and the base `rename_snapshot()` would additionally have attempted a filesystem `rename()`. Neither is reachable today — every base call site is gated on `snapshot-as-volume-chain`, which this plugin does not offer, and the `QemuServer` sites need `do_snapshots_type()` to return `external`, which raw volumes never produce. The explicit refusal means a future caller gets a straight answer instead of an error naming a method it never called.

- `rename_snapshot()` 與 `volume_snapshot_info()` 改為明確拒絕。繼承來的實作會走 `filesystem_path()`，而本外掛無法實作該方法（Pure 的 Volume 名稱由 storage id 推導，但 Proxmox VE 不會把它傳給該方法）；base 的 `rename_snapshot()` 還會試圖對檔案系統執行 `rename()`。目前兩者都不可達，明確拒絕是為了讓未來的呼叫端得到直接的答案，而不是一個提到它從未呼叫過的方法的錯誤。

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.30-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node / 在**每一個**叢集節點執行：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
