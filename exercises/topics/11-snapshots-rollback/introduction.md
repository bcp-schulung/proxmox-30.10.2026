# Topic 11 - Snapshots and Rollback

**Topic ID:** `11-snapshots-rollback`
**Course reference:** Proxmox VE Introduction, Day 2 §8 "Snapshots & Live
Migration"
**Duration:** 30 minutes
**Runs on:** one node

---

## 1. What you learn

A snapshot is a point-in-time copy of a disk. With the guest agent enabled
it also captures the memory, which turns "restore a disk" into "restore a
running guest".

```
   Base Disk State
        │
        ├── Snapshot: pre-update
        │        │
        │        ├── Snapshot: after-patch
        │        │
        └── Current Running State
                 │
            Rollback to pre-update
```

## 2. What a snapshot actually is

A snapshot does not copy the whole disk. It records the state of the disk at
that moment and writes the differences into a separate file. A guest with a
1 GB disk that changes 50 MB after the snapshot uses about 50 MB of extra
space.

```bash
qm config 9201 | grep scsi0
# scsi0: nfs-lab:vm-9201-disk-0,size=32G
```

After a snapshot, the original disk becomes a thin disk with the
differences in a separate volume. On a thin LVM pool the space is only
taken when it is used.

## 3. The commands

```bash
qm snapshot 9201 pre-update --description "Before the Nordwind release"
qm listsnapshot 9201
qm rollback 9201 pre-update
qm delsnapshot 9201 pre-update
```

### The two types of rollback

| Command | What it does | The guest |
|---|---|---|
| `qm rollback 9201 pre-update` | Restores the disk **and** the memory | The guest is running again |
| `qm rollback 9201 pre-update --mode snapshot` | Restores the disk only | The guest is stopped |

The default is the full rollback, which restores the memory state. The guest
comes back exactly as it was - same process, same uptime, same open files.

## 4. The guest agent matters

A snapshot with the agent enabled freezes the filesystem first:

```
fsfreeze -> snapshot -> fsfthaw
```

Without the agent, the snapshot is taken while the guest is writing to the
disk. The result is a snapshot that is *consistent enough* for a backup, but
not for a database - the database's journal might be inconsistent with its
data.

This is why the guest agent check appears in almost every exercise.

## 5. The cost

Snapshots are not free. Every snapshot keeps the changed blocks alive. On a
guest that writes a lot - a database, a log server - a snapshot that is
never deleted slowly fills the storage.

```bash
pvesm list nfs-lab --content images
```

**Delete the snapshots you no longer need.** A snapshot is not a backup; it
is a rollback point on the same storage as the original.

## 6. What you do

1. Take a snapshot of VM 9201 named `pre-update` with a description.
2. Make a change inside the guest.
3. Roll the guest back.
4. Verify that the change is gone.
5. Delete the snapshot.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
