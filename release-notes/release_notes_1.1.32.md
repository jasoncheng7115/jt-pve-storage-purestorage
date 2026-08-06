Follow-up to v1.1.31, from the same question: what happens when a name stops identifying what the code thinks it identifies.

---

## HIGH — A node could destroy another node's snapshot clone in shared host mode

Reading from a snapshot — backing up from one, `qemu-img convert` out of one, a container backup — makes a temp clone on the array and connects it to the node doing the reading. That clone is connected to **only** that node, which is how the reapers decide whether they may remove it:

```perl
next if grep { ($_->{name} // '') ne $my_host } @$conns;   # someone else's, leave it
```

The guard exists because of a real incident: the creating node is protected by its own in-use check, and every *other* node has no local device to check, so without this it would sail past and destroy a clone that was being read.

With `pure-host-mode = shared`, every node reports the same Pure host name. The question "is this connected to a host other than mine?" then answers "no" for a clone created anywhere in the cluster, and the guard passes on every node. The fast sweep runs at 60 seconds and the background reaper at one hour — both far shorter than a large backup.

Demonstrated with the reaper driven against a stubbed array:

| Host mode | Another node's clone, 2 hours old |
|---|---|
| `per-node` | protected |
| `shared` (before) | **destroyed** |
| `shared` (now) | protected |

Where ownership cannot be established, the reapers no longer guess — they wait out any plausible operation. In shared mode both now require **24 hours** of age, from two independent sources (the array's `created` and the timestamp embedded in the clone name). A clone genuinely left behind by a crashed node is still collected; one being read right now is not. `per-node` mode is unchanged and keeps its 60-second sweep.

Putting the node name into the clone name would be the definitive fix rather than a conservative one. It is not in this release because the name is already over the array's length budget — see below — and that has to be solved first.

---

## Snapshot-access clone names can exceed the array's 63-character limit

The clone name is the volume name plus 36 characters, and nothing checks the total against the 63 the array allows, even though the plugin already applies that limit to ordinary volumes:

| Storage id | Volume name | Clone name |
|---|---|---|
| `pure1` | 19 | 54 |
| `pure-prod-array1` | 30 | **65** |
| `pure-production-cluster-a` | 38 | **73** |

A storage id longer than about 13 characters puts every snapshot-access clone over the limit, even though the disk volumes themselves fit comfortably. If the array enforces it, the clone is rejected and snapshot access fails — with an error that never mentions the storage id, which is the hard part to diagnose.

This release **warns** with a message naming the cause. It does not change the naming scheme: that would rename objects on the array, and the exact behaviour of a real array at the boundary is worth confirming on hardware first.

If you see this warning and snapshot-based backups are failing, a storage with a shorter id is the workaround; the disk volumes are unaffected.

---

## Also

- The host-name collision check added in v1.1.31 ran ahead of the host-verification cache, so it repeated on every `pvestatd` poll rather than once per cache interval. The measured cost was negligible, but `activate_storage()` is a hot path and that cache exists precisely to keep it doing nothing.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.32-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
