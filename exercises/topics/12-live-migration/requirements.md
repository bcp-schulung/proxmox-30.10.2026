# Requirements - Topic 12: Live Migration

**Topic ID:** `12-live-migration`

---

## The precondition

- [ ] VM 100 is running.
- [ ] VM 100 is on the shared storage `nfs-lab` - a migration of a guest on
      a local disk is refused by Proxmox, and this is why.

## The migration

- [ ] VM 100 runs on `pve2` after the migration.
- [ ] VM 100 is still running.
- [ ] The guest agent answers after the migration.
- [ ] The guest's uptime was **not** reset - the guest kept running through
      the move.

## The cluster state

- [ ] The cluster is still quorate after the migration.
- [ ] All three nodes are still members.

---

## Notes

**The uptime check is the proof that the migration was online.** An offline
migration stops the guest, moves it and starts it again - the uptime starts
from zero. An online migration keeps the guest running, and the uptime
carries over.

The verification reads the uptime from the guest itself:

```bash
qm guest exec 100 -- cat /proc/uptime
```

**The quorate check** is there because a migration is a cluster operation.
If the cluster loses quorum during the move, the guest ends up in a state
that needs manual intervention.
