Follow-up to the credential change in v1.1.25. No functional change; it adds a warning at the one point where that change can bite.

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

---

> The general rule: a change to **where** data is read from is not dangerous at the upgrade. It is dangerous at the first write after the upgrade, because that write lands on nodes that have not been upgraded yet. Put the warning at the write, not in the installer. And verify "upgrading is safe" by running the old code's read path against the new on-disk state, rather than by reasoning about it.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.28-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
