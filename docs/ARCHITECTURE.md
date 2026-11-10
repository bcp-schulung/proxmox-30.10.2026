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
