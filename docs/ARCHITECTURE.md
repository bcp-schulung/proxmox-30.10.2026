# Architecture

This document explains the topology the harness builds and, more importantly, **why** it
is shaped the way it is. The seminar material describes an on-premise Proxmox cluster; AWS
breaks several of its assumptions, and every deviation below is a deliberate decision.

---

## 1. The Proxmox version

The seminar material targets **Proxmox VE 9.2** (Debian 13.5 "Trixie", kernel 7.0,
QEMU 11.0, LXC 7.0, ZFS 2.4). That is exactly what the harness installs, so every command
in the course material works unchanged.

The official ISO installer cannot be used on EC2 - you cannot boot the machine from an
ISO, and the installer expects to own the disk. The supported alternative, documented at
[pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie),
is to install Proxmox on top of Debian 13. The Packer build does exactly that.

Five traps in that path are handled by `packer/scripts/`:

| Trap | Consequence | Fix |
|---|---|---|
| `pvenetcommit` moves `/etc/network/interfaces.new` over `/etc/network/interfaces` at boot | The bridge configuration is silently destroyed | `rm -f /etc/network/interfaces.new` after every write, and `pvenetcommit` is masked at runtime |
| cloud-init rewrites `/etc/hosts` | The hostname resolves to `127.0.1.1` and `pve-cluster` refuses to start | `manage_etc_hosts: false` in `cloud.cfg.d/99-pve-lab.cfg` |
| netplan and systemd-networkd fight ifupdown2 | Two services manage the same interface | The network is only switched over in the node bootstrap, as the last step before the reboot |
| The Debian kernel stays installed | Point-release conflicts on upgrade | `apt remove linux-image-amd64 'linux-image-6.12*' os-prober` |
| `virtio_blk` is missing from the initramfs | The instance cannot boot from its NVMe root volume | The virtio modules are added to `/etc/initramfs-tools/modules` and the initramfs is rebuilt |

The AMI keeps the Debian networking in place so that the instance boots with an address.
The switch to ifupdown2 happens in `scripts/node-bootstrap.sh`, which validates the new
configuration with `ifup -s -a` **before** the reboot - a broken `interfaces` file would
otherwise mean a node that never comes back.

---

## 2. The network

### 2.1 Why the guests cannot have VPC addresses

EC2 routes traffic to a **network interface**, using the IP addresses that are assigned
to that interface. A virtual machine inside Proxmox is a guest on a software bridge: it
has a MAC address, but AWS has never heard of it, and nothing in the VPC will route to
it. Even a guest with an IP from the VPC subnet would be unreachable, because the
VPC router only forwards to ENI-owned addresses.

So the guests need their own address space, and the host has to provide the connectivity.

### 2.2 The three layers

```
   AWS VPC 10.20.0.0/16
   │
   ├── subnet-public 10.20.0.0/24 ──► internet gateway
   │     pve1 .11   pve2 .12   pve3 .13        (management, corosync, web UI)
   │     nfs1 .20   pbs1 .21
   │
   ├── subnet-services 10.20.2.0/24 ──► NAT gateway
   │     the NFS and PBS instances
   │
   └── the guest overlay: pure layer 2 inside each Proxmox node
         pve1  10.10.10.0/24   gateway 10.10.10.1
         pve2  10.10.20.0/24   gateway 10.10.20.1
         pve3  10.10.30.0/24   gateway 10.10.30.1
```

### 2.3 Why `eth0` is never bridged

The classic Proxmox layout puts the management IP on `vmbr0` and enslaves the physical
NIC to it. On a hypervisor that works, because the hypervisor owns the layer 2 domain.
On EC2 it is dangerous:

> The bridge takes a MAC address of its own. AWS drops traffic whose source MAC is not
> the one registered on the ENI. The node would simply go dark - and you would have no
> way in except the serial console.

Pinning the bridge to the uplink MAC (`hwaddress`) makes it work, but it still means a
single misconfigured file takes out SSH, the web UI *and* the cluster link at the same
time.

The harness therefore keeps `eth0` a plain interface with the VPC address, and uses a
**separate bridge without a physical port** for the guests:

```
auto eth0
iface eth0 inet static
    address 10.20.0.11/24
    gateway 10.20.0.1

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
```

`vmbr0` is a real Linux bridge: the guests get a genuine layer 2 segment, `bridge vlan
show` and `bridge link` behave as the course expects, and VLAN tags work as they do on
hardware. What it does not have is a wire to the outside world - the host provides that
instead.

### 2.4 How the guests reach the internet

`dnsmasq` runs on each node and serves the overlay subnet:

```
dhcp-range=10.10.10.100,10.10.10.200,255.255.255.0,12h
dhcp-option=option:router,10.10.10.1
dhcp-option=option:dns-server,10.10.10.1
```

The node forwards and masquerades the traffic (`/usr/local/sbin/pve-lab-netfilter`):

```
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -d 10.10.0.0/16 -j RETURN
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -d 10.20.0.0/16 -j RETURN
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
```

The masquerade target is the node's own VPC address, so the traffic egresses through the
ENI that owns that address - exactly what the VPC expects.

The two `RETURN` rules matter:

- Traffic to **other overlay subnets** is deliberately *not* NATed, so a guest on pve1
  can reach a guest on pve2 at its own address. Each node has a static route for the
  other overlay subnets.
- Traffic to the **VPC** is not NATed either, so replies come back to the guest's own
  address and the NFS/PBS servers see the real guest addresses.

### 2.5 Why each node has its own overlay subnet

If all three nodes used `10.10.10.0/24`, a guest on pve1 sending to `10.10.10.60`
(guest on pve2) would find the address directly connected on its own `vmbr0`, answer the
ARP itself, and the packet would never leave the node. Per-node subnets avoid that and
make the routing between the nodes explicit.

### 2.6 Corosync

Corosync 3 (Kronosnet) is unicast-only; multicast is deprecated. The cluster link needs
UDP 5405-5412 between the nodes, plus TCP 22 for the join. The nodes are in one
availability zone, so the latency is far below the 5 ms that Proxmox asks for.

The join uses `pvecm add --use_ssh`, which authenticates with an SSH key instead of
prompting for a password. The harness generates a dedicated key pair on each node and
distributes the public keys to all of them first.

---

## 3. Storage

| Storage ID | Type | Scope | Used for |
|---|---|---|---|
| `local-lvm` | LVM-thin on the node's EBS volume | node-local | Fast local disks |
| `nfs-lab` | NFS 4.1 from the `nfs1` instance | shared | VM disks, ISO, container templates, backups |
| `local` | directory on `/var/lib/vz` | node-local | The cloud-init drive |
| `pbs-main` | Proxmox Backup Server | shared | Backup target |

`local-lvm` is defined **once** in the cluster-wide configuration, with each node
resolving the name against its own volume group - the same behaviour as a cluster that
was created from the ISO and joined afterwards. The storage ID stays `local-lvm`, exactly
as the course material uses it.

`nfs-lab` is what makes live migration and HA possible: both require every node to see
the same disk. The export uses `no_root_squash` because the unprivileged LXC containers
map their root to a high UID range on the host.

### Why not ZFS

The security course uses ZFS for the encryption exercise
(`zfs create -o encryption=aes-256-gcm`). AWS does not support ZFS on EBS - the kernel
does not allow it on a block device that AWS manages. The harness uses LVM-thin and NFS
instead, and the encryption exercise runs against the NFS storage.

---

## 4. The instance topology

| Name | Type | Size | Role |
|---|---|---|---|
| `pve1` … `pve3` | `m8i.4xlarge` | 16 vCPU / 64 GiB | Proxmox VE 9.2 cluster nodes |
| `nfs1` | `t3.medium` | 2 vCPU / 4 GiB | NFS server for the shared storage |
| `pbs1` | `t3.large` | 2 vCPU / 8 GiB | Proxmox Backup Server 4.x |

Every Proxmox node gets:

- a 32 GiB encrypted gp3 root volume (the operating system)
- a 250 GiB encrypted gp3 data volume (the LVM-thin pool)
- a public IP in the public subnet, with SSH (22), the web UI (8006) and the VNC/SPICE
  console (5900-5999) restricted to the operator's public IP

The volume is located **by its EBS serial number**, not by device index - on Nitro the
`nvme` numbering follows attachment order and is not predictable:

```bash
lsblk -ndo NAME,SERIAL | awk -v v=vol-0123 '$2==v {print $1}'
```

---

## 4a. The guest templates

Each Proxmox node carries its own copy of the Debian 13 cloud image and its own template.
The templates are deliberately **per-node and node-local**: `local-lvm` is an LVM-thin
pool on the node's own disk, not shared storage, so a template that lives on pve2 cannot
be cloned onto pve1 without a copy.

| Node | ISO | Template | Storage | Running guest |
|---|---|---|---|---|
| pve1 | `/var/lib/vz/template/iso/debian-13-generic-amd64.qcow2` | `9101` `debian13-tpl-pve1` | `local-lvm` | `9201` `debian13-run-pve1` |
| pve2 | same path | `9102` `debian13-tpl-pve2` | `local-lvm` | `9202` `debian13-run-pve2` |
| pve3 | same path | `9103` `debian13-tpl-pve3` | `local-lvm` | `9203` `debian13-run-pve3` |

The image is verified against the upstream `SHA512SUMS` before it is used.

### 4a.0 The starting state

This is what the seminar starts from. `provision.sh --phase guests` brings the cluster to
exactly this state, and every exercise builds on top of it.

| Object | ID | Name | Node | State |
|---|---|---|---|---|
| Template | 9101 | `debian13-tpl-pve1` | pve1 | template, on `local-lvm` |
| Template | 9102 | `debian13-tpl-pve2` | pve2 | template, on `local-lvm` |
| Template | 9103 | `debian13-tpl-pve3` | pve3 | template, on `local-lvm` |
| Guest | 9201 | `debian13-run-pve1` | pve1 | running, full clone of 9101 |
| Guest | 9202 | `debian13-run-pve2` | pve2 | running, full clone of 9102 |
| Guest | 9203 | `debian13-run-pve3` | pve3 | running, full clone of 9103 |
| Container | 300 | `app01` | pve1 | unprivileged LXC, on `nfs-lab` |
| Container | 301 | `db01` | pve2 | unprivileged LXC, on `nfs-lab` |

The inventory lives in `config/default.env` and is the single source of truth for every
script, exercise and check. The IDs are in the `91xx`/`92xx` range so that they cannot
collide with the `100`-`102` and `9000`-`9002` range that an earlier version of the lab
used.

### 4a.0.1 Why one template per node

There is no single shared template, and that is deliberate. The two kinds of clone have
contradictory requirements:

- A **full clone** can be moved to another node only when the source is on shared
  storage. A template on the local storage of a node is refused with
  `can't clone VM to node 'pve2' (VM uses local storage)`.
- A **linked clone** is a snapshot of the template's disk, and a snapshot is only
  possible on a storage that supports them. NFS does not:
  `Linked clone feature is not supported for 'nfs-lab:9000/...'`.

A template on the node's **own** `local-lvm` satisfies both constraints, so every node
carries its own copy of the golden image and every guest is a full clone of the template
on the node it runs on.

### 4a.0.1 Only one provisioning run at a time

Two runs against the same cluster destroy each other's work. One builds the templates
while the other tears the guests down, and the cluster is left with neither - which is
not a race that can be won, it is a race that has to be prevented.

`provision.sh` and `scripts/build-seminar-guests.sh` therefore take a **run lock**
before they touch anything:

```
.state/run.lock/          a directory - mkdir is atomic
.state/run.lock/pid       the PID of the process that holds it
.state/run.lock/name      what it is doing
```

A second run finds the lock, sees that the PID is alive, and refuses to start. A lock
whose PID is gone is **stale** - it was left behind by a process that was killed - and
it is taken over.

For the same reason, `lab_destroy_guests` no longer destroys every VM it finds. It
destroys the objects of the inventory in `config/default.env` and nothing else. A
blanket teardown cannot tell a lab object from something an operator put on the
cluster on purpose, and it took the templates down with it when it ran against a
cluster that also held other work.

### 4a.1 The image is an image, not an ISO

`debian-13-generic-amd64.qcow2` is a **qcow2 disk image**, not an ISO. The `iso/`
subdirectory of a directory storage only accepts real ISO extensions
(`$PVE::Storage::ISO_EXT_RE_0`), so `local:iso/debian-13-generic-amd64.qcow2` is
rejected by the volume-name parser:

```
unable to parse directory volume name 'iso/debian-13-generic-amd64.qcow2'
```

The image is therefore brought in with `qm importdisk`, which takes a plain path and
converts the qcow2 into a raw volume on `local-lvm`:

```
qm importdisk <vmid> /var/lib/vz/template/iso/debian-13-generic-amd64.qcow2 local-lvm
qm set <vmid> --scsi0 local-lvm:vm-<vmid>-disk-1,discard=on,iothread=1
```

The disk number that `importdisk` picks is **not** the one to assume. With an `efidisk0`
already attached, the EFI vars volume takes `disk-0` and the imported OS disk lands on
`disk-1`. Attaching `disk-0` to `scsi0` produces a template that boots a 4 MB EFI
partition instead of Debian - the VM starts, shows no output, and never gets an address.
Always read the volume name back out of `qm config` and confirm the size with
`lvs` before booting.

### 4a.2 The cloud image has no configuration of its own

`debian-13-generic-amd64` is built for cloud-init. It ships **no** `/etc/network/interfaces`,
**no** `systemd-networkd` drop-in, and **no** root password. Every bit of its
configuration is supposed to arrive from a cloud-init data source at first boot.

A template with no cloud-init drive therefore boots to a login prompt with **no network
interface at all**. The templates get the following baked in instead, so that a plain
clone works with nothing else:

| Setting | Where | Why |
|---|---|---|
| DHCP on the virtio NIC | `/etc/systemd/network/10-eth.network` | The guest must get an address from the node's `dnsmasq` |
| `systemd-networkd` + `systemd-resolved` enabled | `multi-user.target.wants` | The image has no other network manager |
| `/etc/resolv.conf` -> `stub-resolv.conf` | symlink | The node's `dnsmasq` is the resolver |
| Root SSH key + root password | `/root/.ssh/authorized_keys`, `chpasswd -R` | The stock image cannot be logged into at all |
| `debian` user with password + key | `/home/debian` | The image's documented default user |
| `PermitRootLogin yes` | `/etc/ssh/sshd_config.d/10-proxmox-lab.conf` | The image ships `PasswordAuthentication no` |
| Empty `/etc/machine-id` | `/etc/machine-id` | Clones must not share a machine id |

`chpasswd -R` and the `authorized_keys` files are written against the mounted
filesystem, so the root password ends up hashed in `/etc/shadow` inside the image.

### 4a.3 No access to the running VMs is needed

**Starting a guest and verifying it is up does not require access to the guest.**
Verification is done from the Proxmox side, on the node:

| Question | Answered with |
|---|---|
| Is the VM running? | `qm status <vmid>` -> `status: running` |
| Is the QEMU process alive? | `qm list` shows a PID; `ps -p <pid>` |
| Did it boot? | QMP `screendump` -> a PPM of the console |
| Is it on the network? | `/var/lib/misc/dnsmasq.leases` shows a lease for its MAC |

This matters because the guest overlay is **not** reachable from outside the VPC. A guest
holds an address in `10.10.10.0/24`, a private segment that only the three nodes can
route to. There is no path from an operator laptop into that segment, so a check that
requires SSH into the guest cannot be part of an automated verification - it would
depend on where the check runs from.

The consequence for automation: **do not treat a guest login as the success criterion.**
A guest that boots to a login prompt and holds a DHCP lease is a working guest. Waiting
for SSH to succeed inside the guest is a different test, it needs a reachable path to
the overlay, and it makes the verification depend on the guest rather than on Proxmox.

---

## 5. Security groups

| Group | Rule | Purpose |
|---|---|---|
| `pve-lab` | 22, 8006, 5900-5999 from `AWS_CALLER_IP` | Operator access |
| `pve-lab` | UDP 5405-5412 from the VPC | Corosync/KNET |
| `pve-lab` | TCP 22 from the VPC | Node-to-node SSH and `pvecm add --use_ssh` |
| `pve-lab` | TCP 2049 from the VPC | NFS client traffic |
| `pve-lab` | TCP 8007 from the VPC | Proxmox Backup Server |
| `services-lab` | 22 from `AWS_CALLER_IP` | Operator access to NFS/PBS |
| `services-lab` | 2049 and 8007 from the VPC | NFS and PBS |

The guest overlay traffic leaves the node masqueraded to the node's own address, so it
is covered by the `pve-lab` group.

---

## 6. Failure handling

| Failure | Detection | Recovery |
|---|---|---|
| The node does not come back after the network switch | `provision.sh` aborts | `./debug.sh --node pve1`; SSM is available as an out-of-band channel |
| SSH is broken but the instance is up | `debug.sh` falls back to SSM Run Command | `aws ssm start-session` |
| The cluster does not become quorate | `pvecm status` in `debug.sh` | Check the corosync ports and the node-to-node SSH keys |
| A phase fails half way | The state file records the last completed phase | Re-run `provision.sh`; it resumes |

SSM is enabled on every instance (the `AmazonSSMManagedInstanceCore` managed policy is
attached through the instance profile), so there is always a way into a node whose
networking is broken.
