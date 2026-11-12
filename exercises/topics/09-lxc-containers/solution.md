# Solution - Topic 09: LXC Containers

**Topic ID:** `09-lxc-containers`

> **Instructor material.**

---

## 1. The container template

```bash
# Find the latest Debian 13 standard template
curl -fsS http://download.proxmox.com/images/system/ \
  | grep -oE 'debian-13-standard_[0-9.]+-[0-9]+_amd64\.tar\.zst' \
  | sort -uV | tail -1
```

```bash
# Put it into the shared storage
pvesm download-url nfs-lab \
  http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst \
  debian-13-standard_13.6-1_amd64.tar.zst
```

Verify:

```bash
pvesm list nfs-lab --content vztmpl
```

```
volid                 content  format  volname
nfs-lab:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst  vztmpl  vztmpl  ...
```

> **The `local:` prefix in `pct create`.** `pct create 300 local:vztmpl/...`
> reads the template from the *local* storage and copies it into the rootfs
> storage you specify with `--rootfs`. The template itself does not have to
> be on the shared storage - the container's rootfs does.

## 2. The three containers

```bash
pct create 300 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname app01 \
  --memory 1024 \
  --cores 1 \
  --swap 512 \
  --rootfs nfs-lab:8 \
  --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp \
  --unprivileged 1 \
  --ostype debian \
  --onboot 1 \
  --password "${GUEST_PASSWORD}" \
  --features nesting=1 \
  --ssh-public-key "${SSH_PUBKEY}"
```

```bash
pct create 301 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname db01 \
  --memory 2048 --cores 2 --swap 512 \
  --rootfs nfs-lab:16 \
  --net0 name=eth0,bridge=vmbr0,tag=40,ip=dhcp \
  --unprivileged 1 --ostype debian --onboot 1 \
  --password "${GUEST_PASSWORD}" \
  --features nesting=1 \
  --ssh-public-key "${SSH_PUBKEY}"
```

```bash
pct create 302 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname cache01 \
  --memory 512 --cores 1 --swap 256 \
  --rootfs nfs-lab:4 \
  --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp \
  --unprivileged 1 --ostype debian --onboot 1 \
  --password "${GUEST_PASSWORD}" \
  --features nesting=1 \
  --ssh-public-key "${SSH_PUBKEY}"
```

### The differences per tier

| | app01 | db01 | cache01 |
|---|---|---|---|
| RAM | 1024 | 2048 | 512 |
| CPU | 1 | 2 | 1 |
| Disk | 8 GB | 16 GB | 4 GB |
| VLAN | 30 | 40 | 30 |

The database gets more of everything - it is the tier that has to stay up
and that has real data in it.

## 3. The options explained

| Option | Why |
|---|---|
| `--unprivileged 1` | The container's root maps to a high UID on the host. A breakout does not give root. |
| `--features nesting=1` | Enables the `keyctl` and `clone` calls that Docker and Podman need. |
| `--ostype debian` | Tells the container manager which key management and systemd integration to use. |
| `--net0 name=eth0,...` | The interface name inside the container. A VM gets `net0`; a container gets a real name. |
| `--ip=dhcp` | The address comes from the node's dnsmasq. |
| `--rootfs nfs-lab:8` | The root filesystem, 8 GB, on the shared storage. |

### The interface name

This is the difference that confuses people coming from the VM world:

```bash
qm config 9201 | grep net0
# net0: virtio=BC:76:4E:...,bridge=vmbr0,tag=20

pct config 300 | grep net0
# net0: name=eth0,bridge=vmbr0,tag=30,ip=dhcp
```

A container has a `veth` pair on the host and a real interface name inside.
A VM has a tap device on the host and `net0` inside.

## 4. Start and verify

```bash
pct start 300
pct start 301
pct start 302
```

### The host kernel

```bash
pct exec 300 -- cat /proc/version
# Linux version 7.0.14-1-pve (build@...) (gcc ...) #1 SMP ...
```

That is the **host's** kernel. The container has none of its own. Compare
with a VM:

```bash
qm guest exec 9201 -- cat /proc/version
# Linux version 6.12.0-...-amd64 ...
```

### The cgroup

```bash
pct exec 300 -- cat /proc/1/cgroup
# 0::/system.slice/lxc-300.scope
```

The path contains `lxc-300.scope`. That is the cgroup that carries the
memory limit, the CPU limit and the I/O weight.

### The network

```bash
pct exec 300 -- ip -brief a
# lo      UNKNOWN  127.0.0.1/8
# eth0    UP       10.10.10.102/24
```

### The guest agent

```bash
pct exec 300 -- systemctl enable --now qemu-guest-agent
pct exec 300 -- systemctl is-active qemu-guest-agent
```

The guest agent inside a container talks to the host through the **mount
point** `/dev/vz` or through the virtio-serial device - depending on the
version, the container needs `mount=...`:

```bash
pct config 300 | grep mount
# mount: /dev/vz
```

If the agent does not answer, add the mount point and restart:

```bash
pct set 300 --mount /dev/vz
pct reboot 300
```

### The whole check from outside

```bash
pct status 300
pct exec 300 -- hostname
pct exec 300 -- uptime
pct exec 300 -- systemctl --failed --no-legend
```

## 5. The comparison, side by side

```bash
# The VM
qm status 9201
qm config 9201 | grep -E '^(cores|memory|scsihw|agent)'
qm showcmd 9201 | head -1 | cut -c1-120

# The container
pct status 300
pct config 300 | grep -E '^(cores|memory|unprivileged|features)'
pct exec 300 -- cat /proc/version
```

| | VM 9201 | CT 300 |
|---|---|---|
| Process | `qemu-system-x86_64` | `lxc-start` + the container processes |
| Kernel | Its own | The host's |
| Boot time | Seconds | Milliseconds |
| Overhead | ~100 MB for the firmware and the devices | A few MB |
| Root filesystem | A disk image | A directory on the storage |
| Isolation | Hardware boundary | Namespaces and cgroups |

## 6. The complete sequence

```bash
# The template
pvesm download-url nfs-lab \
  http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst \
  debian-13-standard_13.6-1_amd64.tar.zst

# The application tier
pct create 300 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname app01 --memory 1024 --cores 1 --swap 512 \
  --rootfs nfs-lab:8 \
  --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp \
  --unprivileged 1 --ostype debian --onboot 1 \
  --password "${GUEST_PASSWORD}" --features nesting=1 \
  --ssh-public-key "${SSH_PUBKEY}"

# The database tier
pct create 301 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname db01 --memory 2048 --cores 2 --swap 512 \
  --rootfs nfs-lab:16 \
  --net0 name=eth0,bridge=vmbr0,tag=40,ip=dhcp \
  --unprivileged 1 --ostype debian --onboot 1 \
  --password "${GUEST_PASSWORD}" --features nesting=1 \
  --ssh-public-key "${SSH_PUBKEY}"

# The operations tier
pct create 302 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname cache01 --memory 512 --cores 1 --swap 256 \
  --rootfs nfs-lab:4 \
  --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp \
  --unprivileged 1 --ostype debian --onboot 1 \
  --password "${GUEST_PASSWORD}" --features nesting=1 \
  --ssh-public-key "${SSH_PUBKEY}"

# Start and verify
pct start 300 && pct start 301 && pct start 302
pct exec 300 -- cat /proc/version
pct exec 300 -- cat /proc/1/cgroup
pct exec 300 -- ip -brief a
```

## 7. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `pct create` fails: "no such volume" | The template is not in the storage | `pvesm list nfs-lab --content vztmpl` |
| The container has no address | dnsmasq does not serve the VLAN | The DHCP range covers the overlay of the node |
| The container starts but the network is down | The interface name is wrong | `--net0 name=eth0,...` |
| The guest agent does not answer | The mount point is missing | `pct set 300 --mount /dev/vz` and restart |
| `pct exec` says "not running" | The container is stopped | `pct start 300` |
| The rootfs is on the local storage | The `--rootfs` was omitted | `pct set 300 --rootfs nfs-lab:8` (needs a migration for a running container) |
| Docker does not work inside | `nesting` is missing | `pct set 300 --features nesting=1` and restart |
