**Upgrade if you use Fibre Channel, set `pure-pod`, or see an intermittent HTTP 500 on the storage pages.**

---

## CRITICAL — FC: a VM started from the web interface could not find its disk

`pvedaemon` and `pveproxy` run under `perl -T`. The SCSI host scan writes `- - -` to `/sys/class/scsi_host/hostN/scan`, and the plugin built that path from `readdir()` of `/sys/class`, so the path was tainted. The write happens in a forked child inside an `eval`; under taint mode `open` refused it and the child exited with no message.

On iSCSI this was masked, because the per-session `iscsiadm --rescan` still runs. On Fibre Channel the host scan is the **only** way a newly mapped LUN is discovered. A disk is allocated without waiting for its device, so creating it succeeded; starting the VM from the web interface then waited for a device nothing had scanned for, and timed out. The same start from `qm start` (no `-T`) worked, and `pvestatd` would find the LUN on its next periodic rescan.

`sysfs_write_with_timeout()` now untaints its path itself, accepts only paths under `/sys` with no `..`, and warns when it refuses one.

## CRITICAL — Intermittent HTTP 500 and "active: no" on the storage pages

One process keeps two API clients per storage — a short-timeout, single-attempt health client (`activate_storage`, `status`) and the data client — and they share one array session. Since 1.1.36 a client logs its session out when its local cache expires. The replacement health client was then seeded with the token that had just been logged out, and the re-login on HTTP 401 sat inside the retry loop, behind "attempts remaining", which a single-attempt client never has. Every `activate_storage()` in that process failed until the data client happened to refresh.

What it looked like: an occasional `Internal Server Error (500)` on the storage content view and `active: no` on the summary — both served by whichever `pvedaemon` worker was affected — and gaps of minutes in the usage graph when the array expired a session itself.

A 401 now triggers one re-login and one repeat regardless of the retry count (the array did not act on a request it rejected as unauthenticated, so this is safe for every method), and a released token is cleared from every client that borrowed it. Either half was tested on its own; the re-login alone fixes every case.

## HIGH — `pure-pod` spelled differently from the array

FlashArray names are case-insensitive, so `pure-pod PVE-Pod` works for every create and connect against a pod that exists as `pve-pod`. But the array returns names in its own spelling, and the pod filter and the local re-match of returned names compared exact strings. The pod's volume list came back empty: no disks in the web interface, and the orphan reaper — seeing none of the storage's volumes — treated every tracked device as stale and removed any that was not open after its ten-minute grace period.

The pod's spelling is now resolved once per client with a name lookup, and returned names are matched case-insensitively.

## FC: "No FC target ports detected" on every node

The kernel names FC remote ports `rport-H:C-N`. The plugin matched `rport-N-N-N`, which never exists, so the warning repeated on every poll of every FC node with healthy zoning, and the device-wait diagnostics reported zero targets — pointing at a fabric that was fine.

---

## New option: `pure-pod-capacity`

For a pod **without** a `quota_limit`, what the storage reports:

| Value | Total | Used | Available |
|---|---|---|---|
| `array` (default, unchanged) | whole array | everything on the array | array free |
| `pod` | used + available | this pod (per `pure-pod-usage-metric`) | array free |

A pod with a `quota_limit` reports the quota as total in either mode.

```bash
pvesm set <storage> --pure-pod-capacity pod
```

The capacity warning no longer tells you to expand a pod quota when the pod has none.

---

## Tests

Five new suites, each failing on 1.1.37: `fcrport.pl`, `sysfstaint.pl` (runs under `perl -T`, as `pvedaemon` does), `sessionshare.pl` (a simulated array with real session semantics), `podscope.pl`, `podcase.pl`.

---

## Action required after upgrade

Run on **every** cluster node — the fixes live in `pvedaemon` as well as `pvestatd`:

```bash
systemctl restart pvedaemon pvestatd pveproxy
systemctl show -p MainPID pvedaemon pvestatd   # the PIDs must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
