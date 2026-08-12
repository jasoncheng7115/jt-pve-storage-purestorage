Found by auditing this project against defects the sibling `jt-pve-storage-dellemc` plugin hit first.

---

## MEDIUM — Every process left a REST session behind on the array

A session is a resource on the array, not a local object. Pure's own reference says so:

> `DELETE /api/1.x/auth/session` — Deletes (invalidates) the REST session.

and Pure's generated 2.x client lists `/logout` beside `/login` as an endpoint that needs no token. Nothing here called either.

That is not one session:

- `pvestatd` rebuilds its client whenever the local 300-second cache expires
- a `pvedaemon` worker runs one task and exits
- every `pvesm`, `qm` or `pct` invocation is its own process

Each logged in once and walked away, leaving the session to sit out the array's idle timeout.

Sessions this process created are now released from an `END` block. `DESTROY` cannot do it — at global destruction the user agent is already going away — and the registry is stamped with the creating pid, so a forked worker does not end its parent's session. The client cache releases the session it is about to discard when its TTL expires, rather than abandoning it: that TTL is this plugin's policy, and the array's session is still there.

> **Two traps, both avoided.** The sibling's own logout began with *return unless the session is valid* — so the session past its TTL, the one that most needed releasing, never was. Ours is gated on owning a token, not on any local notion of validity.
>
> And one the sibling did not have: this plugin seeds a new client with another client's token, so a borrower must never log that token out. Ownership is recorded where the session is created.

---

## LOW — A long outage buried the journal

Proxmox VE logs whatever `activate_storage` dies with, on every poll — about six times a minute, per node, for as long as the outage lasts — beside a throttled OUTAGE record already carrying the same facts.

The first failures still carry the array's own answer, because that is the diagnosis. Once the outage is on record, the message names the storage and the address and points at the OUTAGE record for the rest.

---

## Checked, no change needed

The sibling found two of the four volume names Proxmox VE builds itself were unrecognised — and that the failure was not a refusal: allocation fell through to picking a free disk id, so the volume was created under a name that says it is an ordinary VM disk. Fleecing is the one that matters, because that goes wrong during a backup rather than during a create.

This plugin refuses an unrecognised name instead. The enumeration was re-read out of this Proxmox VE anyway: `vm-<vmid>-efi-enroll` appears only in `QemuServer/OVMF.pm` as a QEMU storage daemon id and never reaches allocation, and no `vdisk_alloc` in the tree passes a fleecing name — which this plugin handles regardless.

---

## Install

```bash
apt install ./jt-pve-storage-purestorage_1.1.36-1_all.deb
```

## Action required after upgrade

Run on **every** cluster node:

```bash
systemctl restart pvestatd
systemctl show -p MainPID pvestatd   # the PID must change
```

---

Full changelog: [CHANGELOG.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG.md) | [CHANGELOG_zh-TW.md](https://github.com/jasoncheng7115/jt-pve-storage-purestorage/blob/main/CHANGELOG_zh-TW.md)
