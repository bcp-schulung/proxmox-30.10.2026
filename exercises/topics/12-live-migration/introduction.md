# Topic 12 - Live Migration

**Topic ID:** `12-live-migration`
**Course reference:** Proxmox VE Introduction, Day 2 §8 "Live Migration"
**Duration:** 45 minutes
**Runs on:** two nodes

---

## 1. What you learn

Live migration moves a **running** guest to another node. The guest keeps
running, the applications keep serving, and the downtime is typically well
under a second.

That is only possible because of three things:

1. the guest is on **shared storage** - the target node has to see the disk
2. the nodes are on a **fast, low-latency network** - the memory is copied
   over it
3. the guest uses a **portable CPU type** - the CPU state has to make sense
   on the target

## 2. The algorithm

```
   Source Node                              Target Node
   ---------                              -----------
   1. Pre-migration checks
      (storage, network, target free)
                        │
   2. Start the RAM transfer                │
      iterative pre-copy  ─────────────────►│  receives the memory
                        │                   │
   3. loop                                 │
      send the changed pages  ─────────────►│
      until the dirty rate is low           │
                        │                   │
   4. Briefly pause the VM  ───────────────►│  takes over the devices
      send the final CPU and device state   │
                        │                   │
   5. Start the VM on the target  ─────────►│  the guest runs again
                        │
   6. Clean up the source
```

Steps 1 to 3 are the bulk transfer and the guest keeps running. The pause in
step 4 is the only interruption, and it is typically a few hundred
milliseconds.

## 3. The precondition: shared storage

This is the rule that decides everything:

```bash
qm migrate 100 pve2 --online
# migrate VMs with local disks are not supported
```

The disk has to be on `nfs-lab` (or Ceph, or iSCSI). A guest on `local-lvm`
stays where it is.

```bash
# Move the disk first
qm move_disk 100 scsi0 nfs-lab --target-directory vm-100-disk-0
qm migrate 100 pve2 --online
```

## 4. The CPU type

```bash
qm set 100 --cpu host
```

`host` exposes the exact CPU features of the node. It is the fastest
option, and it is **not portable**: a guest with `--cpu host` cannot be
migrated to a node with a different CPU, and a Windows guest with a licence
check refuses to start after the move.

For a cluster that has to be able to migrate freely:

```bash
qm set 100 --cpu x86-64-v2-AES
```

## 5. The migration modes

| Command | Behaviour |
|---|---|
| `qm migrate 100 pve2 --online` | The guest keeps running |
| `qm migrate 100 pve2` | The guest is stopped, moved and started |
| `qm migrate 100 pve2 --with-local-disks` | Also moves local disks (slow) |
| `qm migrate 100 pve2 --target-local` | Moves the disk to the target's local storage |

The offline migration works with any storage - because the guest is not
running, the disk can simply be copied.

## 6. What you do

1. Verify that VM 100 is on the shared storage.
2. Migrate it to `pve2` while it is running.
3. Verify that it now runs on `pve2`.
4. Verify that the guest never stopped - the agent answers and the uptime
   was not reset.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
