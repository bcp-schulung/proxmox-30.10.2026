# Topic 08 - The VM Lifecycle

**Topic ID:** `08-vm-lifecycle`
**Course reference:** Proxmox VE Introduction, Day 2 §2 and §3 "QEMU/KVM
Fundamentals" and "Creating & Configuring Virtual Machines"
**Duration:** 60 minutes
**Runs on:** one node

---

## 1. What you learn

A virtual machine on Proxmox is one QEMU process. Everything you do to it -
start, stop, snapshot, migrate - is either a change to that process or a
change to the configuration that the process reads at the next start.

That single fact explains almost everything:

- a stopped guest can be reconfigured freely, because nothing is running
- a running guest needs `qm set` with `--pending` for the changes that
  cannot be applied live
- the guest agent turns a "stop" into a graceful shutdown

## 2. The lifecycle

```
   qm create
       │
       ▼
   Created ──── qm destroy ───► gone
       │
     qm start
       │
       ▼
   Running ──── qm shutdown / qm stop ───► Stopped
       │
       ├── qm suspend ──► Paused ── qm resume ──► Running
       │
       ├── qm snapshot ──► Snapshotted
       │
       └── qm migrate --online ──► Migrating ──► Running (on the other node)
```

### The difference between `qm stop` and `qm shutdown`

| | `qm stop` | `qm shutdown` |
|---|---|---|
| What it does | Cuts the power | Asks the guest to shut down |
| Guest agent | Not needed | Needed (or an ACPI signal) |
| Data | May be lost | Clean |
| Use | A guest that hangs | Everything else |

```bash
qm shutdown 9201 --timeout 60     # wait up to 60 seconds
qm shutdown 9201 --forceStop 1    # cut the power after the timeout
```

## 3. The configuration areas

| Setting | Options | Notes |
|---|---|---|
| Machine type | `q35`, `pc-i440fx` | `q35` is the modern one, with PCIe |
| BIOS | `seabios`, `ovmf` | OVMF is UEFI, needed for Secure Boot |
| CPU type | `host`, `x86-64-v2-AES` | `host` is fastest, but not portable |
| Disk bus | `virtio-scsi-single`, `sata`, `ide` | VirtIO SCSI is the recommendation |
| Display | `virtio-gl`, `vga`, `serial0` | Headless servers want `serial0` |
| SCSI controller | `virtio-scsi-single` | One queue is enough for most |

### The CPU type

```bash
qm set 9201 --cpu host
```

`host` exposes the host's CPU features - the fastest option, and the reason
a Windows guest with a licence check refuses to start after a migration to
a different node.

`x86-64-v2-AES` is a named baseline that every node of the cluster supports.
It costs a little performance and buys full portability.

## 4. The guest agent

```bash
qm set 9201 --agent enabled=1,fstrim_cloned_disks=1
```

The guest agent enables three things:

1. **Filesystem freeze and thaw** - the basis of a consistent backup
2. **Reporting the guest's IP** - the host can then offer the console and
   the network view
3. **A graceful shutdown** - `qm shutdown` becomes a real shutdown

```bash
qm guest cmd 9201 ping
qm guest exec 9201 -- ip -brief a
qm guest exec 9201 -- systemctl status qemu-guest-agent
```

## 5. What you do

1. Create the web tier VM 9201 from the template - a full clone.
2. Configure it: CPU, memory, network with the VLAN tag, disk controller,
   guest agent.
3. Give it its own cloud-init drive with its own hostname.
4. Start it and verify the guest agent answers.
5. Take a snapshot, make a change, roll it back.
6. Shut it down cleanly and start it again.

## 6. How it is checked

```bash
./exercise.sh
```

## 7. The reference

`solution.md`.
