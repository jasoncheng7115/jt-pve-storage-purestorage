Housekeeping release from a full sweep of the tree. No behaviour change for any storage operation.

---

## Removed: six exported functions nobody called

`is_config_volume`, `is_pve_managed_volume`, `is_valid_pure_volume_name`, `is_target_logged_in`, `set_initiator_name` and `wait_for_device` were exported from `Naming.pm` and `ISCSI.pm` with zero call sites anywhere in the plugin or the recovery tool. Three of them were still named in the plugin's `qw()` import list — removing the exports broke the import, which proved those entries were decorative too.

One of them mattered. `set_initiator_name()` contained:

```perl
system('systemctl', 'restart', 'iscsid');
```

A bare `system()` has no timeout, and it was restarting a daemon whose stop phase can block while iSCSI sessions are active — the exact failure mode this codebase has spent releases eliminating everywhere else.

The rule against bare `system()` was already enforced by a static check. That check was scoped to `bin/` and had never looked at the library.

## Changed: the checks now cover what they claim to

- The bare-`system()` check runs over `lib/` as well as `bin/`.
- A new check fails when a function is exported without a caller, so this cannot accumulate again.
- Documentation rules — no emoji, and Taiwan terminology in Traditional Chinese — are now static checks over every public markdown file instead of being applied by hand to whichever file happened to be open. That removed ten warning signs from the READMEs and changelogs (they render as emoji on GitHub) and corrected two terms in `docs/` that had kept their PRC spellings.

> The lesson recorded from this, for whoever audits next: **a check that passes because it never looked reads as coverage.** Scope every static check to everything it should cover, not to the file that prompted it.
>
> And: the new terminology check reported "ok" on a file it had just been handed a violation in — the script has no `use utf8`, so its Chinese literals were byte strings compared against decoded characters. Every new check is now run against a deliberate violation before it is trusted, because a green check that cannot fail looks exactly like a clean tree.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.34-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
