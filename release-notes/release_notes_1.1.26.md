Management-plane load release, continuing the work started in v1.1.21, plus a retry defect that could strand a volume on the array permanently.

---

## MEDIUM — Roughly half the steady-state REST calls were avoidable

v1.1.21 went through this code once for management-plane load. Counting again — by stubbing the API with a counter and running three consecutive `activate_storage()` + `status()` cycles — found four more calls that did not need to be made:

- **The pod was fetched twice per poll.** `get_managed_capacity()` fetched the pod object and then called `pod_get_quota_limit()`, which fetched the same pod object again. The already-fetched object is now passed in.
- **Every new client re-detected the REST version.** `_detect_api_version()` costs at least one unauthenticated `GET /api/api_version`, and up to nine more probes if that fails. It ran for every client object: the plugin's client cache expires after 300s, and the background reaper forks and so always builds a fresh one. The result is now cached per array for the life of the process. A fallback guess made because the array did not answer is deliberately **not** cached — the next client should detect properly rather than inherit the guess.
- **Every forked reaper pass logged in again.** A Pure `x-auth-token` is a bearer token, so a new client can be seeded with a session another client already established. What must not be shared across a fork is the keep-alive socket, and each client still builds its own UA. A stale token costs exactly one 401, after which the existing retry path re-logs in.
- **`activate_storage()` re-asked for things that do not change.** It fetched the iSCSI port list and re-verified the host object on every poll. Both are now cached per process for 300s. The host entry is recorded only *after* the check actually succeeds, so a transient failure cannot silence the check for a whole TTL; and if the host object is removed on the array mid-window, `volume_connect_host()` still fails with a clear error.

Measured with a counting stub over three consecutive polls: **15 calls before, 8 after.** For a five-node cluster with two Pure storages that is a drop from roughly nine REST calls per second at complete idle to under four.

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

---

## MEDIUM — A `pure-pod` that does not exist is now a hard error

The capacity lookup fell back to the array total, so a typo in `pure-pod` made the storage advertise the **whole array** as free while every volume create failed because the pod was missing — two symptoms that contradict each other, joined only by a generic warning in the pvestatd log. A 404 on the pod now fails with a message naming the setting to check.

---

## Documentation

Two storages sharing one Pod double-count capacity in Proxmox VE: each reports the Pod's quota as its own total and the Pod's provisioned size as its own used. Volume names stay correctly isolated (each storage only ever sees `pve-<its own storage>-*`), so nothing breaks — but "available" is wrong on both, and provisioning against it over-commits the Pod. Give each storage its own Pod, or read the figures as per-Pod rather than per-storage. Documented in the Pod section of both READMEs.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.26-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
