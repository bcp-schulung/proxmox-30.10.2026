# Solution - Topic 12: Live Migration

**Topic ID:** `12-live-migration`

> **Instructor material.**

---

## 1. The precondition

```bash
qm status 100
# status: running

qm config 100 | grep scsi0
# scsi0: nfs-lab:vm-100-disk-0,discard=on,iothread=1
```

The disk is on the shared storage, so the migration is possible.

### The refusal, when the disk is local

```bash
qm migrate 100 pve2 --online
# migrate VMs with local disks are not supported
```

That refusal is the most valuable moment in this exercise. It is the moment
where the students understand *why* the shared storage exists.

The fix:

```bash
qm move_disk 100 scsi0 nfs-lab --target-directory vm-100-disk-0
qm migrate 100 pve2 --online
```

`qm move_disk` copies the disk to the shared storage. On a live guest the
disk is copied while it runs, and the switch happens at the end.

## 2. The CPU type

```bash
qm config 100 | grep '^cpu:'
# cpu: host
```

`host` is the fastest, and it is the fastest *until* you try to migrate the
guest to a node with a different CPU.

```bash
qm set 100 --cpu x86-64-v2-AES
```

For a cluster that has to be able to migrate freely, a named baseline is the
right choice. The cost is a few percent of performance.

> **The Windows licence check.** A Windows guest with `--cpu host` refuses
> to start after it was moved to a node with a different CPU, because the
> hardware fingerprint changed. It is the classic surprise in a migration
> project.

## 3. The migration

```bash
qm migrate 100 pve2 --online
```

```
Task ID: 6a3b1c2d
Type:   vzdump
User ID: root@pam
Start Time: 2026-11-10 09:30:12
End Time:   2026-11-10 09:30:14
Status: OK
```

About two seconds for a 4 GB guest.

### What happened

```bash
pvesh get /cluster/resources --type vm | grep 100
# vmid type node status vmid  ...
# 100  qemu  pve2 running
```

```bash
qm status 100
# status: running
```

### The guest never noticed

```bash
qm guest cmd 100 ping
qm guest exec 100 -- cat /proc/uptime
# 3284.71 19204.33
```

The uptime is the proof. An offline migration would have reset it to
something near zero.

## 4. The other migration modes

```bash
# Offline - the guest is stopped, moved and started again
qm migrate 100 pve2

# With the local disks - slow, but possible
qm migrate 100 pve2 --with-local-disks

# To the target's local storage
qm migrate 100 pve2 --target-local
```

### The offline migration with a local disk

```bash
qm shutdown 100
qm migrate 100 pve2
qm start 100
```

This works with any storage, because the guest is not running and the disk
can simply be copied. The cost is the downtime.

## 5. Migrating a container

```bash
pct migrate 301 pve2 --online
```

Containers have no memory state, so their migration is much faster than a
VM's. The shared storage requirement is the same.

## 6. The watch

Watch a migration happen on the target node:

```bash
# On pve2, while the migration runs
watch -n 0.5 'pvesh get /nodes/pve2/qemu/100/status/current'
```

```json
{
  "status": "running",
  "qmpstatus": "prelaunch",
  "ha": { "managed": 0 }
}
```

The `qmpstatus` moves from `prelaunch` through `postmigrate` to `running`.

## 7. The complete sequence

```bash
# The precondition
qm status 100
qm config 100 | grep scsi0        # must be nfs-lab

# The CPU type - portable
qm set 100 --cpu x86-64-v2-AES

# The migration
qm migrate 100 pve2 --online

# The verification
qm status 100
pvesh get /cluster/resources --type vm | grep 100
qm guest cmd 100 ping
qm guest exec 100 -- cat /proc/uptime
```

## 8. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `migrate VMs with local disks are not supported` | The disk is on `local-lvm` | `qm move_disk` to the shared storage first |
| `migration aborted: source and target have different CPU types` | `--cpu host` on both nodes with different CPUs | Use a named CPU type |
| `unable to resolve hostname` | The nodes do not know each other | Fix `/etc/hosts` on both nodes |
| `migration failed: connection refused` | The SSH key is missing | Distribute the keys (the cluster topic) |
| The guest is slow after the migration | The first boot after a move is slow (THP, caches) | Give it a few minutes |
| The migration takes minutes | The network between the nodes is slow | The lab's nodes are in one availability zone |
| The guest loses its IP | The DHCP lease is not renewed | Wait for the lease, or check the DHCP range |
| The migration is refused because the target is in maintenance | HA maintenance mode | `ha-manager crm-command node-maintenance disable pve2` |

## 9. What the students should take away

> **Live migration is not a feature of the hypervisor. It is a property of
> the storage layout.**

The hypervisor can move a running guest in under a second, but only if:

- every node can see the disk (shared storage)
- every node can reach every other node fast enough (the network)
- the CPU is portable between the nodes (the CPU type)

Get those three right and the migration works. Get the first one wrong and
the feature simply does not exist.
