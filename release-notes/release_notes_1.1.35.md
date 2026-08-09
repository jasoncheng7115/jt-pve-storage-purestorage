Two faults found by auditing this project against defects the sibling `jt-pve-storage-synology` plugin hit first. Both are the same shape: something that works from a shell and does not work where it actually runs.

---

## HIGH — The web interface runs a different Perl from your shell

Measured on a Proxmox VE 9 node:

```
pvedaemon   #!/usr/bin/perl -T
pveproxy    #!/usr/bin/perl -T
pvestatd    #!/usr/bin/perl
qm          #!/usr/bin/perl
pvesm       #!/usr/bin/perl
```

Under taint mode a value that came from a file, a socket or another command's output cannot reach `exec`. And `PVE::Tools::run_command` does **not** untaint for you:

```
literal argument            succeeds
value read from sysfs       Insecure dependency in exec while running with -T switch
```

Every device path this plugin builds comes from a WWID the array returned or from `multipathd` output — both tainted sources. So an operation driven from the **web interface** could fail where the identical operation from `pvesm` on a shell succeeded. A probe against the real functions caught `multipath_flush()` handing a tainted device path to `multipath -f`.

Arguments are now untainted through a regex capture against an allowlist, at both command runners and at every direct `run_command` call site. Anything outside the allowlist is **refused, not stripped**: a stripped argument is a different argument, and a device path that needed stripping is one this plugin should not be acting on.

> The reason this survives testing: the shebang is the fixture. `qm`, `pvesm` and `pvesh` are all plain `#!/usr/bin/perl`, so every check that drives the plugin from a shell passes while the web interface goes on failing. There is now a test that runs under `-T`.

Also measured, and the reason a bare command name would fail the same way: `/proc/<pid>/environ` for `pvedaemon`, `pvestatd` and `pveproxy` contains **no `PATH` at all**, so `exec` falls back to `/bin:/usr/bin` — while `multipath`, `multipathd`, `iscsiadm`, `dmsetup`, `blockdev` and `kpartx` all live in `/usr/sbin`. This plugin already used absolute paths everywhere, so only the taint half applied to it.

---

## MEDIUM — `/sbin/udevadm` does not exist, so every udev refresh did nothing

On Debian 13 `udevadm` is in `/usr/bin`, and `/sbin` is a symlink to `/usr/sbin`. All four call sites failed with:

```
exec of /sbin/udevadm failed: No such file or directory
```

Silently, because they are wrapped in `eval`. `_udev_refresh()` is the helper this project *requires* for every udevadm call — the rule was followed everywhere and the helper had never worked, on any node, since it was written.

What was lost: `udevadm trigger --subsystem-match=block` and `udevadm settle` after a LUN appears or changes. Device nodes and `/dev/disk/by-id/` symlinks were never explicitly settled, which is a plausible contributor to reports of a device not appearing within the timeout on a host where `multipath -ll` looks healthy a minute later.

Command paths now resolve against a candidate list and fail with a message naming what was looked for. A static check asserts that every literal command path used as an argv element exists on the host — because absolute is not the same as correct.

---

## Added

- `bin/pve-pure-config-get --version`. An operator reaching for the recovery tool during an outage should be able to ask the script which build it is, rather than the package database of a node that may be part of the problem.

## Checked, no change needed

The sibling found that Proxmox VE constructs volume names beyond the three this plugin enumerates, and this plugin **refuses** a name it does not recognise — so a missing one would fail an allocation outright. The list was therefore read out of Proxmox VE rather than guessed: the only `vdisk_alloc` calls carrying an explicit name are `vm-<vmid>-state-<snap>` and `vm-<vmid>-cloudinit`, both already handled. `vm-<vmid>-efi-enroll` is a QEMU storage daemon id and never reaches storage allocation, and a TPM state disk allocates with no name, arriving as an ordinary `vm-<vmid>-disk-<n>`.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.35-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
