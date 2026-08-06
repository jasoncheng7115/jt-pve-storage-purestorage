Management-plane load release, continuing the work started in v1.1.21, plus a retry defect that could strand a volume on the array permanently.

管理平面負載釋出，延續 v1.1.21 開始的工作，另外修正一個會讓 Volume 永久滯留在陣列上的重試缺陷。

---

## MEDIUM — Roughly half the steady-state REST calls were avoidable

v1.1.21 went through this code once for management-plane load. Counting again — by stubbing the API with a counter and running three consecutive `activate_storage()` + `status()` cycles — found four more calls that did not need to be made:

- **The pod was fetched twice per poll.** `get_managed_capacity()` fetched the pod object and then called `pod_get_quota_limit()`, which fetched the same pod object again. The already-fetched object is now passed in.
- **Every new client re-detected the REST version.** `_detect_api_version()` costs at least one unauthenticated `GET /api/api_version`, and up to nine more probes if that fails. It ran for every client object: the plugin's client cache expires after 300s, and the background reaper forks and so always builds a fresh one. The result is now cached per array for the life of the process. A fallback guess made because the array did not answer is deliberately **not** cached — the next client should detect properly rather than inherit the guess.
- **Every forked reaper pass logged in again.** A Pure `x-auth-token` is a bearer token, so a new client can be seeded with a session another client already established. What must not be shared across a fork is the keep-alive socket, and each client still builds its own UA. A stale token costs exactly one 401, after which the existing retry path re-logs in.
- **`activate_storage()` re-asked for things that do not change.** It fetched the iSCSI port list and re-verified the host object on every poll. Both are now cached per process for 300s. The host entry is recorded only *after* the check actually succeeds, so a transient failure cannot silence the check for a whole TTL; and if the host object is removed on the array mid-window, `volume_connect_host()` still fails with a clear error.

Measured with a counting stub over three consecutive polls: **15 calls before, 8 after.** For a five-node cluster with two Pure storages that is a drop from roughly nine REST calls per second at complete idle to under four.

v1.1.21 已經為了管理平面負載檢視過這段程式一次。這次改用「數」的方式重測——把 API 換成計數器 stub，跑三次連續的 `activate_storage()` 加 `status()` 輪詢——又找出四個不必要的呼叫：

- **同一顆 pod 每次輪詢被抓兩次。** `get_managed_capacity()` 取得 pod 物件後，`pod_get_quota_limit()` 又把同一顆抓一次。現在改為傳入已取得的物件。
- **每個新用戶端都重新偵測 REST 版本。** `_detect_api_version()` 至少要付出一次未認證的 `GET /api/api_version`，失敗時最多再探測九次。而它對每個用戶端物件都會執行：外掛的用戶端快取 300 秒過期，背景回收又因為 fork 必然建立新的。結果現在以陣列為鍵、在行程生命週期內快取。若是因為陣列沒有回應而採用的預設猜測值，則刻意**不**快取。
- **每次 fork 出來的回收都重新登入一次。** Pure 的 `x-auth-token` 是 bearer token，因此新用戶端可以沿用其他用戶端已建立的 session。跨 fork **不能**共用的是 keep-alive 連線，而每個用戶端仍會建立自己的 UA。失效的 token 只會換來一次 401，既有的重試路徑會重新登入。
- **`activate_storage()` 重複詢問不會變的東西。** 它每次輪詢都取得 iSCSI 埠清單並重新驗證 Host 物件。兩者現在都以行程為範圍快取 300 秒。Host 的紀錄只在檢查**確實成功之後**才寫入，因此短暫失敗不會讓檢查沉默整個 TTL。

實測：**修正前 15 次呼叫，修正後 8 次。** 以五節點、兩個 Pure storage 的叢集換算，等於完全閒置時從每秒約九次 REST 降到四次以下。

---

## MEDIUM — A rename could be retried, stranding a volume forever

`volume_rename()` and `snapshot_rename()` are `PATCH` requests, and `_request()` excluded only `POST` from its 5xx retry — while LWP reports a read timeout as a synthetic 500. So a rename whose response was lost got retried, the retry addressed a name that no longer existed, it came back 404, and the caller concluded the rename had failed.

In `volume_delete()`'s tombstone path that meant:

```
rename issued -> array performs it -> response times out -> retry
  -> PATCH against the old name -> 404 -> "rename failed"
  -> destroy under the ORIGINAL name -> 404 -> "delete failed"
  -> renamed-but-alive volume left on the array
  -> operator retries -> original name not found
  -> "may have been already deleted" -> volume stranded permanently
```

The stranded volume keeps consuming capacity and the array's volume count, and nothing is left that would ever find it again.

Both renames now use a new `no_retry` option, and on failure verify against the array whether the rename actually took effect before believing the error. Idempotent operations keep their retry resilience.

> The general rule this produced: **"is it idempotent?" is a question about the operation, not the HTTP method.** `PATCH` is idempotent for `destroyed=true` and for `provisioned=N`, and not for `name=X`. And a timeout is indistinguishable from a 5xx at the LWP layer, so anything retried on 5xx is retried on timeout.

`volume_rename()` 與 `snapshot_rename()` 是 `PATCH` 請求，而 `_request()` 只把 `POST` 排除在 5xx 重試之外——但 LWP 會把讀取逾時回報為合成的 500。因此回應遺失的 rename 會被重試，重試針對的是已經不存在的名稱，回來 404，呼叫端於是判定 rename 失敗。

在 `volume_delete()` 的 tombstone 路徑上，這代表：改用**原始**名稱 destroy → 404 → 回報刪除失敗 → 陣列上留下一顆已改名但仍存活的 Volume。操作者重試時以原始名稱找不到東西，回報「可能已經被刪除」，該 Volume 就此永久滯留——持續佔用容量與陣列的 Volume 數量上限，而且再也沒有任何機制會找到它。

兩個 rename 現在都使用新的 `no_retry` 選項，並在失敗時先向陣列查證 rename 是否其實已經生效，再決定要不要相信那個錯誤。冪等的操作則保留原本的重試韌性。

> 由此得到的通則：**「這個操作冪等嗎」是針對操作問的，不是針對 HTTP method。** `PATCH` 對 `destroyed=true` 與 `provisioned=N` 冪等，對 `name=X` 不冪等。而且在 LWP 這一層，逾時與 5xx 無法區分，所以「5xx 會重試」等於「逾時會重試」。

---

## MEDIUM — A `pure-pod` that does not exist is now a hard error

The capacity lookup fell back to the array total, so a typo in `pure-pod` made the storage advertise the **whole array** as free while every volume create failed because the pod was missing — two symptoms that contradict each other, joined only by a generic warning in the pvestatd log. A 404 on the pod now fails with a message naming the setting to check.

容量查詢原本會回退到整台陣列的數字，因此一個打錯的 `pure-pod` 會讓 storage 回報**整台陣列**都可用，而每次建立 Volume 卻都因為 Pod 不存在而失敗——兩個互相矛盾的症狀，中間只有 pvestatd 日誌裡一行泛用警告可以串起來。現在 pod 回 404 會直接失敗，並在訊息中指名該檢查哪個設定。

---

## Documentation / 文件

Two storages sharing one Pod double-count capacity in Proxmox VE: each reports the Pod's quota as its own total and the Pod's provisioned size as its own used. Volume names stay correctly isolated (each storage only ever sees `pve-<its own storage>-*`), so nothing breaks — but "available" is wrong on both, and provisioning against it over-commits the Pod. Give each storage its own Pod, or read the figures as per-Pod rather than per-storage. Documented in the Pod section of both READMEs.

兩個 storage 共用同一個 Pod 時，Proxmox VE 會重複計算容量：每個 storage 都把該 Pod 的配額回報為自己的 total、Pod 的 provisioned 回報為自己的 used。Volume 名稱仍正確隔離（每個 storage 只會看到 `pve-<自己的 storage>-*`），功能不會壞，但兩邊的「可用空間」都是錯的，據此配置會超額使用該 Pod。請讓每個 storage 各用一個 Pod，或者把那些數字理解為「每個 Pod」而非「每個 storage」的。已寫入兩份 README 的 Pod 章節。

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.26-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node / 在**每一個**叢集節點執行：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
