# Solution - Topic 18: Resource Management

**Topic ID:** `18-resource-management`

> **Instructor material.**

---

## 1. The CPU

```bash
qm set 100 --sockets 1 --cores 2 --cpulimit 2 --cpuunits 2048
```

Verify:

```bash
qm config 100 | grep -E '^(sockets|cores|cpulimit|cpuunits|cpu)'
```

```
sockets: 1
cores: 2
cpu: x86-64-v2-AES
cpulimit: 2
cpuunits: 2048
```

### The limit and the weight, side by side

| | `--cpulimit 2` | `--cpuunits 2048` |
|---|---|---|
| What it does | A hard ceiling of 2 cores | A relative weight under contention |
| When it matters | Always | Only when the node is oversubscribed |
| The default | `0` = unlimited | `1024` |

A guest with no limit takes every core the node has. On a shared cluster
that is how one misbehaving guest takes down the performance of all the
others.

### The weight in practice

Three guests on a node with 8 cores:

| Guest | Limit | Weight | Under contention it gets |
|---|---|---|---|
| web01 | 2 | 2048 | 2/8 of the CPU |
| web02 | 2 | 1024 | 1/8 of the CPU |
| db01 | 4 | 4096 | 4/8 of the CPU |

### The CPU type

```bash
qm set 100 --cpu x86-64-v2-AES
```

`host` is faster, but it is not portable between the nodes. A cluster that
has to be able to migrate freely uses a named baseline.

## 2. The memory

```bash
# The web tier - the balloon is fine here
qm set 100 --memory 4096 --balloon 2048
```

| Setting | Meaning |
|---|---|
| `--memory 4096` | The guest sees 4 GB. This is also the maximum. |
| `--balloon 2048` | The host may reclaim memory down to 2 GB. |

### The database tier - no balloon

```bash
pct set 301 --memory 2048 --balloon 0
```

The database has a large working set. Every time the host reclaims a chunk
of memory, the guest has to fault the pages back in - and the pause lands
in the middle of a query.

> **The rule of thumb:** balloon the stateless services, do not balloon the
> stateful ones.

## 3. The disk

### Grow the disk

```bash
qm resize 100 scsi0 +20G
```

Verify:

```bash
qm config 100 | grep scsi0
# scsi0: nfs-lab:vm-100-disk-0,size=52G,discard=on,iothread=1
```

> **The grow is only half of the work.** The guest sees a bigger block
> device, but the partition and the filesystem are still the old size.
> ```bash
> qm guest exec 100 -- lsblk
> qm guest exec 100 -- growpart /dev/sda 1
> qm guest exec 100 -- resize2fs /dev/sda1
> ```
> A student who grows the disk and then finds that the guest still reports
> the old size has done nothing wrong - they just have to finish the job
> inside the guest.

### Add a second disk

```bash
qm set 100 --scsi1 nfs-lab:10,discard=on,iothread=1
```

The hotplug works on a running guest. The new disk appears in the guest
immediately - as `/dev/vdb` - and it has to be partitioned and formatted
inside the guest:

```bash
qm guest exec 100 -- lsblk
qm guest exec 100 -- mkfs.ext4 /dev/vdb
```

### Remove it again

```bash
qm set 100 --delete scsi1
```

## 4. The container limits

```bash
pct set 300 --cores 1 --memory 1024 --swap 512
pct set 301 --cores 2 --memory 2048 --swap 512 --balloon 0
```

Verify:

```bash
pct config 300 | grep -E '^(cores|memory|swap)'
```

```
cores: 1
memory: 1024
swap: 512
```

## 5. The hotplug matrix

| Change | Hotplug? |
|---|---|
| Add a disk | Yes |
| Remove a disk | Yes |
| Add a network interface | Yes |
| Change the CPU count | **No** - needs a reboot |
| Change the memory | **No** - needs a reboot |
| Change the CPU type | **No** - needs a reboot |

For the changes that need a reboot, Proxmox offers the pending mechanism:

```bash
qm set 100 --cores 4 --pending 1
qm pending 100
```

```json
{
  "cores": 4,
  "delete": null
}
```

The change is applied at the next start.

## 6. The measurement

The limits are only half of the story - the other half is what the guest
actually uses.

```bash
# From the host
pvesh get /nodes/pve1/qemu/100/status/current
```

```json
{
  "cpu": 0.04,
  "mem": 812345600,
  "maxmem": 4294967296,
  "disk": 2147483648,
  "uptime": 7200
}
```

```bash
# From the guest
qm guest exec 100 -- cat /proc/loadavg
qm guest exec 100 -- free -m
qm guest exec 100 -- df -h
```

### The load average

A load average of 2.0 on a 2-core guest means the guest has more work
queued than it can process. On a 4-core guest, the same value is idle.

```bash
qm guest exec 100 -- nproc
```

## 7. The complete sequence

```bash
# The CPU
qm set 100 --sockets 1 --cores 2 --cpulimit 2 --cpuunits 2048 --cpu x86-64-v2-AES

# The memory - the web tier balloons
qm set 100 --memory 4096 --balloon 2048

# The memory - the database tier does not
pct set 301 --memory 2048 --balloon 0

# The disk
qm resize 100 scsi0 +20G
qm set 100 --scsi1 nfs-lab:10,discard=on,iothread=1

# The container limits
pct set 300 --cores 1 --memory 1024 --swap 512
```

## 8. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The guest is slow but the node is idle | The CPU limit is too low | Raise `--cpulimit` |
| The guest is slow and the node is busy | The node is oversubscribed | Raise the weights, or add a node |
| The guest was killed | The memory limit was reached | Check `dmesg` for the OOM killer |
| The disk is bigger but the guest shows the old size | The partition was not grown | `growpart` and `resize2fs` |
| The database stalls every hour | The balloon reclaimed the working set | `--balloon 0` |
| The CPU change is refused | It needs a reboot | `--pending 1` |
| The guest uses more than its limit | The limit is `0` (unlimited) | Set `--cpulimit` |
