Follow-up to the credential change in v1.1.25. No functional change; it adds a warning at the one point where that change can bite.

v1.1.25 憑證變更的後續。沒有功能變更，只是在該變更唯一會出問題的地方加上警告。

---

## Installing the package is safe. Migrating in a mixed-version cluster is not.

**Installing this package needs no coordination.** It does not touch storage configuration, so `on_add_hook` / `on_update_hook_full` never run, no secret file is written, and an un-migrated storage keeps authenticating from the value still in `storage.cfg` — on upgraded and un-upgraded nodes alike. That was verified by running the pre-1.1.25 read path, which looks only at `$scfg`, against the post-upgrade on-disk state.

The hazard is the **migration command**:

```bash
pvesm set <storeid> --pure-api-token <token>
```

`/etc/pve` is replicated, so the secret file reaches every node immediately — but a node still running a pre-1.1.25 plugin does not know to look there, and the cleartext copy it *was* reading has just been removed by the same command. That node's storage stops authenticating until its package is upgraded.

So: **upgrade every node first, then migrate.**

```bash
# on any node: list the cluster's nodes
pvesh get /nodes --output-format json | grep -o '"node":"[^"]*"'
# on each of them: confirm >= 1.1.25
dpkg -l jt-pve-storage-purestorage
```

The plugin now says this from `on_update_hook_full()` — at the moment the operator takes the risk, rather than at install time when the decision is not yet in front of them. Both READMEs gained the same ordering requirement.

**There is no time pressure to migrate.** An un-migrated storage works indefinitely; the token is simply still in cleartext, which is the situation every version before 1.1.25 was in.

**安裝這個套件不需要任何協調。** 它不會動到 storage 設定，因此 `on_add_hook`／`on_update_hook_full` 完全不會執行，不會寫入任何機密檔，尚未遷移的 storage 也會繼續使用 `storage.cfg` 裡原本的值認證——已升級與未升級的節點都一樣。這一點是用 1.1.25 之前的讀取路徑（只看 `$scfg`）去讀升級後的實際磁碟狀態驗證出來的，不是推論的。

有風險的是**遷移指令**。`/etc/pve` 會同步，機密檔立刻散佈到每個節點，但仍在執行 1.1.25 之前版本的節點不知道要去那裡讀，而它原本在讀的明文副本，剛好被同一道指令移除了。該節點的 storage 會一直無法認證，直到它的套件也升級為止。

所以順序是：**先把所有節點升級完，再執行遷移。**

外掛現在會在 `on_update_hook_full()` 印出這段說明——也就是操作者實際承擔風險的當下，而不是安裝當時（那時候這個決定還沒擺在他面前）。兩份 README 也補上了相同的順序要求。

**遷移沒有時間壓力。** 尚未遷移的 storage 可以無限期正常運作，只是 token 仍以明文存放——那正是 1.1.25 之前每一個版本的狀態。

---

> The general rule: a change to **where** data is read from is not dangerous at the upgrade. It is dangerous at the first write after the upgrade, because that write lands on nodes that have not been upgraded yet. Put the warning at the write, not in the installer. And verify "upgrading is safe" by running the old code's read path against the new on-disk state, rather than by reasoning about it.
>
> 通則：改變資料**從哪裡讀**的變更，危險點不在升級，而在升級後的第一次寫入——因為那次寫入會落到還沒升級的節點上。警告要放在寫入處，不是安裝程式裡。而且「升級是安全的」這個宣稱，要用舊程式碼的讀取路徑去跑新的磁碟狀態來驗證，不要用推理的。

---

## Install / 安裝

```bash
apt install ./jt-pve-storage-purestorage_1.1.28-1_all.deb
```

## Action required after upgrade / 升級後必要動作

Run on **every** cluster node / 在**每一個**叢集節點執行：

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change / PID 必須改變
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
