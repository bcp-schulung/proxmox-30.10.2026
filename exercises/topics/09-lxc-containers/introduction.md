# Topic 09 - LXC Containers

**Topic ID:** `09-lxc-containers`
**Course reference:** Proxmox VE Introduction, Day 2 §5 and §6 "LXC
Containers" and "Containers vs. VMs"
**Duration:** 60 minutes
**Runs on:** one node

---

## 1. What you learn

An LXC container is not a virtual machine. It is a set of Linux namespaces
plus a set of cgroup limits, running on the host's own kernel.

```
   Host Linux Kernel
        │
        ├── Namespaces: PID, NET, MNT, UTS, IPC, USER
        ├── cgroups v2 - resource limits
        │
        ├── Container 300 (app01)
        └── Container 301 (db01)
```

The consequence that matters in practice: a container boots in milliseconds,
needs a few megabytes of overhead, and can only run a Linux kernel.

## 2. VM or container?

| Criteria | Choose a VM | Choose a container |
|---|---|---|
| Guest OS | Windows, BSD, any non-Linux | Linux only |
| Isolation requirement | Strong, untrusted tenants | Trusted, same organisation |
| Density | Lower (full kernel per guest) | Higher (shared kernel) |
| Boot time | Seconds | Milliseconds |
| Kernel-level features | Custom modules, nested virt | Must be host compatible |

**The rule of thumb from the course:**

> Default to LXC for Linux services you trust and control. Use a VM whenever
> you need OS diversity, strong isolation, or kernel-level customisation.

For Nordwind that means:

- the **web tier** runs as a VM, because it has to be live-migrated and
  restarted by HA
- the **application, database and operations tiers** run as containers,
  because they are Linux, trusted, and there are many of them

## 3. Unprivileged containers

Since Proxmox VE 9, containers are unprivileged by default.

```bash
pct create 300 ... --unprivileged 1
```

An unprivileged container maps the container's root to a high UID range on
the host (100000-165535 by default). The container's `root` is not the
host's `root` - it is an unprivileged host user with a mapping. A breakout
from the container therefore does not give the attacker root on the host.

A **privileged** container maps the container's root to the host's root. Any
process that escapes the container is root on the host.

```bash
pct config 300 | grep unprivileged
# unprivileged: 1
```

## 4. The rootfs and the template

```bash
pct create 300 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname app01 --rootfs nfs-lab:8 ...
```

The template is a tarball with a minimal root filesystem. The container
gets its own root filesystem from it, sized as you ask.

The rootfs goes on the **shared** storage when the container has to survive
a node failure or be restarted by HA.

## 5. The features

```bash
pct set 300 --features nesting=1
```

| Feature | What it enables |
|---|---|
| `nesting=1` | Running Docker or `systemd` inside the container |
| `keyctl=1` | The `keyctl` syscall, needed by some container runtimes |
| `fuse=1` | FUSE mounts inside the container |
| `mknod=1` | `mknod` inside the container |

`nesting=1` is the one students need most often - it is what makes Docker
and Podman work inside a container.

## 6. Inside the container

```bash
pct enter 300
ip a                       # the network namespace
cat /proc/1/cgroup         # the cgroup membership
cat /proc/version          # the HOST kernel
ps aux
```

`/proc/version` is the proof: a container has no kernel of its own. It
shows the host's.

```bash
pct exec 300 -- systemctl status qemu-guest-agent
pct exec 300 -- ip -brief a
pct exec 300 -- lsblk
```

`pct exec` runs a command in the container without entering it - the
equivalent of `qm guest exec` for a VM.

## 7. What you do

1. Get the Debian 13 container template into the shared storage.
2. Create the three Nordwind containers:
   - `300 app01` - application tier, VLAN 30
   - `301 db01` - database tier, VLAN 40
   - `302 cache01` - operations tier, VLAN 30
3. Make all three unprivileged, with `nesting=1`, and the rootfs on the
   shared storage.
4. Start them and verify the agent and the network.

## 8. How it is checked

```bash
./exercise.sh
```

## 9. The reference

`solution.md`.
