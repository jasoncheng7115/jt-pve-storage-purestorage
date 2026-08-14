Four defects reported by @DLTKdevopsmaconomy, each with a reproduction and a root cause: [#15](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/15), [#16](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/16), [#17](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/17), [#18](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/issues/18).

**If you are on 1.1.36, upgrade.** Deleting a volume and migrating a disk fail on that release.

---

## HIGH — Deleting a volume and migrating a disk failed on 1.1.36 (#15)

The argument guard added in v1.1.35 refused `%n %w` — the format string this plugin itself passes to `multipathd show maps`, at four call sites. The allowlist had no space in it.

The first caller to reach that guard is the WWID lookup `free_image()` uses for its in-use check, so the refusal surfaced as:

```
Refusing to delete volume 'vm-100-disk-0': could not look up the local device
for WWID 3624a9370..., so the in-use safety check cannot run
```

and a storage migration failed *after* allocating its target volume — which, because the failing code is the cleanup path, left that volume behind on the array.

Scanning every literal argument the tree passes against its own guard found a second one: `^has_journal`, the mkfs option for the config-backup volume. Refused since v1.1.35, and silent, because a failed config backup is non-fatal.

Both are now matched **exactly**, rather than by widening the character class. That distinction matters: a value arriving from the array or from `multipathd` output still cannot contain a space or a caret, so the licence extends only to the two fixed strings this plugin chooses.

| Argument | Before | Now |
|---|---|---|
| `%n %w` | refused | accepted |
| `^has_journal` | refused | accepted |
| `a b` — any other string with a space | refused | **still refused** |
| `x; rm -rf /`, backticks, `$(...)`, newline | refused | still refused |

`make test` now fails if any literal argument the tree passes is refused by the guard.

---

## Realm-scoped accounts (#16, #17)

A Purity account scoped to a realm names its pod `realm::pod`, so a volume in it is `realm::pod::name`, and the array requires every object name — hosts included — to carry the `realm::` prefix.

- **Pod prefixes were split on the first `::`**, taking the realm as the pod and the pod as part of the name, so listings came back empty. Split on the last `::` instead. With a single separator both forms are identical, so a pod without a realm is unaffected.
- **The host object name carried no realm prefix**, so the array answered `Host does not exist` for a host this plugin had just created. The realm is taken from `pure-pod`; a pod without one changes nothing.

---

## An OVMF `efidisk0` could not be created (#18)

Proxmox VE sizes it at 528 KiB and the array refuses anything under 1 MiB:

```
Failed to create volume '...': Pure Storage API: Volume size must be between 1 MB and 4 PB
```

so any VM with UEFI firmware failed at allocation, and any migration carrying one failed with it. Volumes are now clamped to that floor — which this plugin already applied to its own config-backup volume. Proxmox VE keeps the logical size in the guest configuration, so this only pads unused space.

---

## Also

- `multipathd` was invoked by bare name in one place. A Proxmox VE daemon has no `PATH` and `multipathd` lives in `/usr/sbin`, so that call could not execute from the web interface.
- The message when a RAM snapshot's device never appears now names what to check and which setting to raise.

## The tests are in the repository now

`t/` carries thirty behaviour suites, each reproducing a defect this plugin actually shipped, and `make test` runs them. Every suite names the audit-register entries it guards, so coverage can be recomputed rather than believed — it currently stands at 54 of 57 entries, with the three exceptions written down and explained.

Two suites run under `perl -T`, because `pvedaemon` and `pveproxy` do. A test that does not use the same shebang cannot see that class of defect at all.

Static checks went from eighteen to twenty-one: the version agreeing across every file that carries it, the Pure WWID prefix agreeing across its three sites, `activate_storage()` staying off the expensive paths, and the argument guard accepting what this plugin passes.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.37-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
