# Topic 18 - Resource Management

**Topic ID:** `18-resource-management`
**Course reference:** Proxmox VE Introduction, Day 2 §7 "Resource Management -
CPU, Memory, Disk"
**Duration:** 30 minutes
**Runs on:** one node

---

## 1. What you learn

The CPU, the memory and the disk of a guest are **limits**, not
reservations. The hypervisor enforces them with cgroups, and the guest does
not know the difference.

```
   16 vCPU on the node
        │
        ├── VM 100: 2 cores, cpulimit 2, cpuunits 2048
        ├── VM 101: 2 cores, cpulimit 4
        └── CT 300: 1 core,  cpus 1
```

## 2. The CPU

```bash
qm set 100 --sockets 1 --cores 4 --cpulimit 2 --cpuunits 2048
```

| Option | Meaning |
|---|---|
| `--sockets` | The number of CPU sockets the guest sees |
| `--cores` | The number of cores per socket |
| `--cpulimit` | The CPU limit in cores. `0` means unlimited. |
| `--cpuunits` | The relative weight when the node is oversubscribed |

### The limit and the weight

- **`--cpulimit`** is a hard ceiling. The guest cannot use more than that,
  even when the node is idle.
- **`--cpuunits`** is a relative weight. It only matters when the node is
  oversubscribed - then the guests share the available CPU in proportion to
  their weights.

The default weight is 1024. A guest with 2048 gets twice the share of a
guest with 1024 under contention.

> **`--cpulimit 0` means unlimited.** A guest without a limit can consume
> every core of the node and starve its neighbours. On a shared cluster
> every guest should have a limit.

## 3. The memory

```bash
qm set 100 --memory 8192 --balloon 4096
```

| Option | Meaning |
|---|---|
| `--memory` | The maximum, and the amount the guest sees |
| `--balloon` | The minimum. The host can reclaim memory down to this. |

The balloon device lets the host take memory back from a guest that is not
using it. The guest sees the memory disappear and its page cache shrinks.

### When not to use the balloon

> Ballooning is useful for oversubscribed clusters, but disable it for
> latency-sensitive database workloads.

The reason is the pause. Every time the host reclaims a chunk, the guest
has to process the change. On a database with a large working set that
means a page fault storm at exactly the wrong moment.

```bash
qm set 100 --balloon 0
```

## 4. The disk

```bash
qm resize 100 scsi0 +20G          # grow
qm set 100 --scsi1 nfs-lab:50     # add a second disk
```

A grow is visible in the guest immediately - the guest's partition and
filesystem have to be grown separately:

```bash
qm guest exec 100 -- lsblk
qm guest exec 100 -- growpart /dev/sda 1
qm guest exec 100 -- resize2fs /dev/sda1
```

## 5. The hotplug

```bash
qm set 100 --scsi1 nfs-lab:50    # added live
qm set 100 --delete scsi1
```

Proxmox supports the hotplug of disks and network interfaces. The CPU and
the memory do not support it - those changes need a reboot.

## 6. What you do

1. Set the CPU limit and the weight on VM 100.
2. Configure the memory with a balloon on VM 100 and without one on the
   database container.
3. Grow the disk of VM 100 and verify it inside the guest.
4. Add and remove a second disk.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
