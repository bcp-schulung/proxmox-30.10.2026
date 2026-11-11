# Solution - Long Exercise: Nordwind Logistics Platform

**Exercise ID:** `long-nordwind`

> **Instructor material.** This is the complete reference solution. Every
> command is given in the order it is run, with the reasoning for the
> non-obvious choices. The student-facing material is `introduction.md` and
> `requirements.md`.

---

## Conventions

| Variable | Value |
|---|---|
| `NODES` | `pve1 pve2 pve3` |
| `VPC` | `10.20.0.0/16` |
| `OPERATOR` | the operator's address, e.g. `203.0.113.10` - the instructor provides it |
| `NFS_SERVER` | `10.20.2.20` |
| `NFS_EXPORT` | `/export/lab` |
| `PBS_SERVER` | `10.20.2.21` |
| `PBS_DATASTORE` | `main` |

The overlay ranges are per node, because the nodes route between each other
and identical subnets would collide:

| Node | Overlay | Gateway |
|---|---|---|
| pve1 | `10.10.10.0/24` | `10.10.10.1` |
| pve2 | `10.10.20.0/24` | `10.10.20.1` |
| pve3 | `10.10.30.0/24` | `10.10.30.1` |

---

## Task 1 - Node preparation

### 1.1 Identity and time

**On each node.** Proxmox refuses to start `pve-cluster` when the hostname
resolves to a loopback address, so this is not optional.

```bash
hostnamectl set-hostname pve1          # pve2, pve3 on the other nodes
sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo "10.20.0.41 pve1 pve1.seminar.local pve1" >> /etc/hosts
timedatectl set-ntp true
timedatectl status
```

A clock drift of more than about two seconds makes corosync drop the node and
breaks the cluster certificate validity. This is the first thing to check
when a join fails for no reason.

### 1.2 Repositories

**On each node.** Without a subscription the `enterprise` repository makes
every `apt` call fail with a 401, and `apt update` breaks the node's update
path completely.

```bash
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
rm -f /etc/apt/sources.list.d/pve-enterprise.list
apt update
apt list --upgradable
```

### 1.3 The host firewall

**On each node.** The order matters: write the rules **before** switching the
policy to DROP, or the node cuts itself off.

```bash
# The rules first
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 22     --proto tcp --source "${OPERATOR}/32" --comment "SSH from the operator"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 8006   --proto tcp --source "${OPERATOR}/32" --comment "web UI from the operator"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport "5405:5412" --proto udp --source "${VPC}" --comment "corosync and KNET"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 2049   --proto tcp --source "${VPC}" --comment "NFS client"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 8007   --proto tcp --source "${VPC}" --comment "PBS"

# Only now the default deny
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT
```

> **Note.** The node-level firewall in `/etc/pve/nodes/<node>/host.fw` takes
> precedence over the datacenter rules for traffic to the node itself. The
> lab's `node-bootstrap.sh` already writes a correct `host.fw`. If the
> students replaced it, restore it from the backup of the file.

### 1.4 What to check

```bash
pveversion -v | head -3
hostnamectl
getent hosts "$(hostname)"
timedatectl show -p NTPSynchronized
pvesh get /cluster/firewall/options
pvesh get /cluster/firewall/rules
systemctl status pve-firewall --no-pager
```

---

## Task 2 - Cluster formation

### 2.1 Distribute the SSH keys first

`pvecm add --use_ssh` authenticates with a key. If the joining node does not
know the seed node's host key, the join dies with
`Host key verification failed`.

```bash
# On every node - generate a key
ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519

# On every node - collect the public keys of all three nodes
for n in 10.20.0.41 10.20.0.33 10.20.0.28; do
  ssh-keyscan -T 10 -t rsa,ecdsa,ed25519 "$n" 2>/dev/null
done | sort -u >> /root/.ssh/known_hosts
```

### 2.2 Create the cluster on the first node

```bash
pvecm create prod-cluster --link0 10.20.0.41
```

`--link0` is the address the cluster members use to talk to each other. In
this lab that is the VPC address on `eth0`, because the overlay subnets
differ per node and corosync needs one routable path.

### 2.3 Join the other two nodes

**On pve2:**

```bash
pvecm add 10.20.0.41 --link0 10.20.0.33 --use_ssh
```

**On pve3:**

```bash
pvecm add 10.20.0.41 --link0 10.20.0.28 --use_ssh
```

The fingerprint is asked for interactively. The instructor has it:

```bash
pvecm updatecerts --fingerprint     # on pve1
```

### 2.4 Verify

```bash
pvecm status
pvecm nodes
```

```
Quorum information
------------------
    Nodes:             3
    Node ID:           0x00000001
    Ring ID:           1.9f
    Quorum:            2
    Flags:             Quorate

Membership information
----------------------
    Node ID             Name                 State
    0x00000001         pve1 (10.20.0.41)     Member
    0x00000002         pve2 (10.20.0.33)     Member
    0x00000003         pve3 (10.20.0.28)     Member
```

### 2.5 The lesson

A configuration change is now visible everywhere:

```bash
echo "test" > /etc/pve/cluster-demo.txt
ls /etc/pve/cluster-demo.txt      # on pve2 and pve3
rm /etc/pve/cluster-demo.txt
```

---

## Task 3 - Storage backends

### 3.1 The LVM-thin pool on each node

**On each node.** The volume group is node local; the *definition* is
cluster wide.

```bash
pvesm add lvmthin local-lvm --vgname pve --thinpool data \
  --content images,rootdir
```

The definition is written once into `/etc/pve/storage.cfg` and replicated to
all nodes. Each node resolves `pve/data` against its own volume group. This
is exactly what the PVE installer does when nodes are clustered afterwards.

### 3.2 The shared NFS storage

**Once, on any node.**

```bash
pvesm add nfs nfs-lab --server 10.20.2.20 --export /export/lab \
  --content images,rootdir,iso,vztmpl,backup,snippets \
  --options "vers=4.1,hard,proto=tcp"
```

### 3.3 The backup target

The PBS credentials come from the instructor:

```bash
pvesm add pbs pbs-main --server 10.20.2.21 --datastore main \
  --username backup@pbs --password "${PBS_PASSWORD}" \
  --fingerprint "${PBS_FINGERPRINT}" --content backup
```

The fingerprint must match the one on the PBS server. It protects the
cluster against a man in the middle on the first contact:

```bash
# On the PBS server
proxmox-backup-manager fingerprint
```

### 3.4 Verify

```bash
pvesm status
```

```
Name             Type     Status           Total            Used       Available        %
local-lvm        lvm-thin active             251.00 GiB    20.00 GiB     231.00 GiB   7.97%
nfs-lab          nfs      active        1000.00 GiB     0.00 GiB    1000.00 GiB   0.00%
pbs-main         pbs      active                 0 B          0 B             0 B        0%
```

Prove that the NFS storage is genuinely shared:

```bash
echo "shared" > /mnt/pve/nfs-lab/.shared-test
cat /mnt/pve/nfs-lab/.shared-test        # on pve2 and pve3
rm /mnt/pve/nfs-lab/.shared-test
```

---

## Task 4 - The guest network

### 4.1 The bridge

**On each node.** The overlay range differs per node.

```bash
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 10.20.0.41/24
    gateway 10.20.0.1

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes

source /etc/network/interfaces.d/*
EOF
ifreload -a
```

> **Why no `bridge-ports`?** On EC2 the bridge cannot own a MAC address, and
> AWS drops the traffic. The bridge is therefore a pure layer 2 segment for
> the guests, and the node provides DHCP, routing and NAT for them.

### 4.2 DHCP

**On each node.**

```bash
cat > /etc/dnsmasq.d/pve-lab.conf << EOF
interface=vmbr0
bind-dynamic
port=0
dhcp-authoritative
dhcp-range=10.10.10.100,10.10.10.200,255.255.255.0,12h
dhcp-option=option:router,10.10.10.1
dhcp-option=option:dns-server,10.10.10.1
EOF
systemctl restart dnsmasq
```

### 4.3 Routing and NAT between the nodes

**On each node**, add the routes to the other overlay ranges and the
masquerade rules.

```bash
ip route replace 10.10.20.0/24 via 10.20.0.33
ip route replace 10.10.30.0/24 via 10.20.0.28

iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -d 10.10.0.0/16 -j RETURN
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -d 10.20.0.0/16 -j RETURN
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
sysctl -w net.ipv4.ip_forward=1
```

The two `RETURN` rules matter: traffic between the overlay subnets must not
be NATed, so a guest on `pve1` is reachable at its own address from `pve2`.

### 4.4 Verify

```bash
ip -brief addr show vmbr0
bridge vlan show
systemctl status dnsmasq --no-pager
```

---

## Task 5 - Identity and access control

### 5.1 The realm and the user

```bash
pveum realm add ad-corp --type pve --comment "Nordwind corporate realm"
pveum user add jsmith@ad-corp --password "${JSMITH_PASSWORD}"
```

> **Deviation.** The deck adds an Active Directory realm. The lab has no
> directory server, so the built-in `pve` realm type is used under the
> deck's name. The commands are otherwise identical.

### 5.2 The narrow role

```bash
pveum role add VM-Operator -privs "VM.Console,VM.PowerMgmt,VM.Monitor"
```

The point of a custom role is the blast radius. `PVEVMUser` would also grant
the disk and network configuration privileges, which a person who only
operates the web tier does not need.

### 5.3 The ACL

```bash
pveum acl modify /vms/100 --users jsmith@ad-corp --roles VM-Operator
pveum acl modify /vms/101 --users jsmith@ad-corp --roles VM-Operator
```

Not on `/`. An ACL on `/` would give the operator the rights everywhere.

### 5.4 The privilege separated API token

```bash
pveum user token add automation@pve terraform --privsep 1
pveum acl modify /vms/100 --tokens 'automation@pve!terraform' --roles VM-Operator
```

`--privsep 1` is the important flag. Without it the token inherits the full
privileges of its user, and the ACL below would be decoration.

### 5.5 Verify

```bash
pveum realm list
pveum user list
pveum role list
pveum acl list
pveum user permissions jsmith@ad-corp
pveum user token list automation@pve
```

---

## Task 6 - The golden image and the template

### 6.1 Get the image

```bash
pvesm download-url nfs-lab https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 debian-13-genericcloud.qcow2
```

### 6.2 Create the VM and import the disk

```bash
qm create 9000 --name debian13-template --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single \
  --ostype l26 --machine q35 --bios ovmf \
  --agent "enabled=1,fstrim_cloned_disks=1" --tablet 1 --onboot 1 \
  --ide2 local:cloudinit --ipconfig0 ip=dhcp

qm importdisk 9000 nfs-lab:debian-13-genericcloud.qcow2 nfs-lab
qm set 9000 --scsi0 nfs-lab:vm-9000-disk-0,discard=on,iothread=1 \
  --efidisk0 nfs-lab:1,efitype=4m,pre-enrolled-keys=1 \
  --boot order=scsi0
```

### 6.3 The cloud-init snippet

The snippet gives the guest its hostname, the guest agent and the credentials.

```bash
cat > /tmp/ci-9000.yaml << EOF
#cloud-config
hostname: debian13-template
fqdn: debian13-template.nordwind.example.com
manage_etc_hosts: true
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      passwd: '${GUEST_PASSWORD}'
      type: text
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF

qm set 9000 --cicustom local:/tmp/ci-9000.yaml
```

> **The trick that trips everybody up.** The cloud-init drive belongs to the
> VM, and a clone inherits it. When the clone gets a new hostname, the
> cloud-init drive has to be replaced as well - otherwise the clone boots
> with the template's hostname and the old credentials. Every clone in this
> exercise gets its own snippet.

### 6.4 Boot, check, template

```bash
qm start 9000
qm guest cmd 9000 ping          # the agent answers
qm guest exec 9000 -- hostname
qm template 9000                # now read-only, and clonable
```

`qm template` makes the VM read-only. It cannot be started any more - that
is the point.

---

## Task 7 - The web tier

### 7.1 The full clone

```bash
qm clone 9000 100 --name web01 --full --storage nfs-lab
qm set 100 --scsi0 nfs-lab:vm-100-disk-0,discard=on,iothread=1 \
  --cores 2 --memory 4096 --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1" --onboot 1
qm set 100 --ide2 local:cloudinit --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-100.yaml
qm start 100
```

Repeat for VM 101 `web02`.

### 7.2 The VLAN tag

`tag=20` puts the guest into the web tier. The tag is what the firewall and
the segmentation exercise work with:

```bash
qm config 100 | grep net0
# net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0,tag=20
```

### 7.3 Verify

```bash
qm config 100
qm guest cmd 100 ping
qm guest exec 100 -- ip -brief a
```

---

## Task 8 - The container tiers

### 8.1 The container template

```bash
pvesm download-url nfs-lab http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst debian-13-standard_13.6-1_amd64.tar.zst
```

### 8.2 The containers

```bash
pct create 300 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname app01 --memory 1024 --cores 1 --rootfs nfs-lab:8 \
  --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp \
  --unprivileged 1 --ostype debian --onboot 1 \
  --password "${GUEST_PASSWORD}" --features nesting=1
```

| CT | Name | VLAN | Role |
|---|---|---|---|
| 300 | `app01` | 30 | application tier |
| 301 | `db01` | 40 | database tier |
| 302 | `cache01` | 30 | operations tier / monitoring |

### 8.3 Verify

```bash
pct config 300
pct exec 300 -- cat /proc/1/cgroup
pct exec 300 -- ip -brief a
```

`/proc/1/cgroup` shows the container runs in the host's cgroup hierarchy -
that is the difference between a container and a VM.

---

## Task 9 - Clones and test environments

```bash
qm clone 9000 102 --name web-test --storage nfs-lab     # linked clone
qm set 102 --cores 2 --memory 4096 --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1"
qm set 102 --ide2 local:cloudinit --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-102.yaml
qm start 102
```

The linked clone is visible in the disk line:

```bash
qm config 102 | grep scsi0
# scsi0: nfs-lab:vm-102-disk-0,iothread=1,discard=on   <- full clone
# scsi0: nfs-lab:base-9000-disk-0,size=...             <- linked clone
```

A linked clone depends on the template. **Never delete the template while
linked clones exist.**

---

## Task 10 - Snapshots and rollback

```bash
qm snapshot 100 pre-update --description "before the Nordwind release"

# make a change in the guest
qm guest exec 100 -- sh -c 'echo "release-2.4" > /etc/nordwind-version'

# ... and undo it
qm rollback 100 pre-update
qm guest exec 100 -- cat /etc/nordwind-version   # the file is gone

qm delsnapshot 100 pre-update
```

A snapshot of a running guest with the agent enabled includes the memory
state, so the rollback brings back a guest that is running, not a guest that
is stopped.

---

## Task 11 - Live migration

```bash
qm status 100
qm migrate 100 pve2 --online
qm status 100
pvesh get /cluster/resources --type vm | grep 100
```

The migration only works because the disk is on `nfs-lab`. If a student
tries to migrate a VM that is on `local-lvm`, the refusal is the lesson:

```
migrate VMs with local disks are not supported
```

After the migration:

```bash
qm guest cmd 100 ping          # the guest never noticed
```

---

## Task 12 - Segmentation and firewall

### 12.1 The datacenter rules

The default deny comes first only after the necessary rules exist.

```bash
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT
```

### 12.2 The tier rules

```bash
# The web tier reaches the database tier
pvesh create /nodes/pve1/qemu/100/firewall/rules \
  --action ACCEPT --type in --dport 5432 --proto tcp --source 10.10.20.0/24 \
  --comment "web tier -> database tier"

# The database tier does not reach the web tier
pvesh create /nodes/pve1/lxc/301/firewall/rules \
  --action DROP --type in --dport 443 --proto tcp --source 10.10.20.0/24 \
  --comment "database tier -> web tier denied"
```

The rule set on a VM/CT lives in
`/etc/pve/firewall/<vmid>.fw` and is replicated by the cluster filesystem.

### 12.3 The VLAN tags

```bash
qm set 100 --net0 virtio,bridge=vmbr0,tag=20
qm set 101 --net0 virtio,bridge=vmbr0,tag=20
pct set 300 --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp
pct set 301 --net0 name=eth0,bridge=vmbr0,tag=40,ip=dhcp
```

### 12.4 Verify

```bash
pvesh get /cluster/firewall/rules
bridge vlan show
cat /etc/pve/firewall/100.fw
```

---

## Task 13 - Backup and restore

### 13.1 The backup job

```bash
pvesh create /cluster/backup \
  --storage pbs-main \
  --vmid 100,301 \
  --schedule daily \
  --mode snapshot \
  --enabled 1 \
  --compress zstd \
  --retention-keep-daily 7 \
  --retention-keep-weekly 4 \
  --retention-keep-monthly 6
```

The `snapshot` mode uses the guest agent to freeze the filesystem, so the
backup is consistent even while the guest writes to it.

### 13.2 The manual backup

```bash
vzdump 100 --storage pbs-main --mode snapshot
vzdump 301 --storage pbs-main --mode snapshot
pvesm list pbs-main --content backup
```

### 13.3 The restore - the part everybody forgets

```bash
# Restore into a NEW VMID as a linked clone, so the original is untouched
qmrestore pbs-main:backup/vm/100/2026-11-10T02:00:00Z 190 --storage nfs-lab
qm set 190 --net0 virtio,bridge=vmbr0,tag=20
qm start 190
qm guest cmd 190 ping
```

> **Why a new VMID?** A restore to the same VMID overwrites the original. In a
> real recovery the original is the damaged one and is deliberately kept for
> the forensic analysis. The lab follows the same rule: restore into a fresh
> VMID, verify it, then decide what to do with the original.

### 13.4 Verify

```bash
pvesh get /cluster/backup
pvesm list pbs-main --content backup
```

---

## Task 14 - High availability

```bash
ha-manager add group prod-nodes --nodes pve1,pve2,pve3

ha-manager add vm:100  --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add vm:101  --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add ct:301  --group prod-nodes --max_restart 3 --max_relocate 2

ha-manager status
```

The rule that makes this work: **HA restarts a guest on a different node**.
That is only possible when the disk is on shared storage. A guest on
`local-lvm` is rejected:

```
cannot add HA managed resource: storage 'local-lvm' is not shared
```

To watch the failover, stop a node and look at `ha-manager status`. The
resource moves to a healthy node and comes back up.

---

## Task 15 - Monitoring and notifications

### 15.1 The status and the metrics

```bash
pvesh get /cluster/status
pvesh get /cluster/metrics
pvesh get /cluster/resources
```

### 15.2 The notification endpoint and the matcher

```bash
pvesh create /cluster/notifications/endpoints/sendmail \
  --name ops-mail --comment "Nordwind operations"

pvesh create /cluster/notifications/matchers/system-mail \
  --type sentry \
  --comment "all cluster notifications" \
  --notification-template all
```

The template `all` sends every event. A production setup narrows it down:

```bash
pvesh create /cluster/notifications/matchers/backup-failures \
  --type sentry --comment "only the backup failures" \
  --notification-template backup-fail
```

### 15.3 The task log

```bash
pvesh get /cluster/log --limit 50
```

---

## Task 16 - Troubleshooting

### 16.1 The decision tree

```
Problem reported
     │
     ├── Guest or host?
     │      │
     │      ├── Guest
     │      │     ├── VM or CT?
     │      │     │     ├── VM   -> qm status, qm showcmd, console, dmesg on the host
     │      │     │     └── CT   -> pct status, journalctl -u pve-container@<id>
     │      │
     │      └── Host
     │            ├── Service -> journalctl -u pvedaemon -u pveproxy -u pvestatd
     │            └── Storage -> pvesm status, dmesg -T | tail
     │
     └── Apply the fix, then verify
```

### 16.2 The worked example

The guest is unreachable. Before touching anything:

```bash
# 1. Preserve the evidence
qm snapshot 100 incident-2026-11-10 --description "before the diagnosis"

# 2. Which layer?
qm status 100                       # is the guest running at all?
qm showcmd 100 | head -5            # is QEMU running with the right devices?
qm guest cmd 100 ping               # does the agent answer?

# If the guest runs but has no network:
qm guest exec 100 -- ip -brief a
qm guest exec 100 -- ip route
qm guest exec 100 -- cat /etc/resolv.conf

# If the host is at fault:
journalctl -u pvedaemon -u pveproxy --since "10 min ago" --no-pager
dmesg -T | tail -50
pvesm status
```

### 16.3 A broken guest, fixed

```bash
# Break it: stop the guest agent
qm guest exec 100 -- systemctl stop qemu-guest-agent

# Diagnose
qm guest cmd 100 ping        # times out - the agent is gone
journalctl -u pveproxy --since "5 min ago" --no-pager | tail

# Fix
qm guest exec 100 -- systemctl start qemu-guest-agent
qm guest cmd 100 ping        # answers again
```

### 16.4 The write-up

```bash
pvesh get /cluster/log --limit 100 --output-format json | \
  jq -r '.[] | "\(.time) \(.username) \(.cmd)"'
```

---

## Appendix A - the complete command sequence

The whole platform, from an empty set of three nodes, in order. This is what
the reference build script runs.

```bash
# --- Task 1, on each node -----------------------------------------------
hostnamectl set-hostname pve1
sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo "10.20.0.41 pve1" >> /etc/hosts
timedatectl set-ntp true
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
rm -f /etc/apt/sources.list.d/pve-enterprise.list
apt update

# --- Task 2 ------------------------------------------------------------
ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
for n in 10.20.0.41 10.20.0.33 10.20.0.28; do
  ssh-keyscan -T 10 -t rsa,ecdsa,ed25519 "$n" 2>/dev/null
done | sort -u >> /root/.ssh/known_hosts

pvecm create prod-cluster --link0 10.20.0.41        # on pve1
pvecm add 10.20.0.41 --link0 10.20.0.33 --use_ssh   # on pve2
pvecm add 10.20.0.41 --link0 10.20.0.28 --use_ssh   # on pve3

# --- Task 3 ------------------------------------------------------------
pvesm add lvmthin local-lvm --vgname pve --thinpool data --content images,rootdir
pvesm add nfs nfs-lab --server 10.20.2.20 --export /export/lab \
  --content images,rootdir,iso,vztmpl,backup,snippets --options "vers=4.1,hard,proto=tcp"
pvesm add pbs pbs-main --server 10.20.2.21 --datastore main \
  --username backup@pbs --password "${PBS_PASSWORD}" \
  --fingerprint "${PBS_FINGERPRINT}" --content backup

# --- Task 4, on each node ----------------------------------------------
# (see section 4 - the bridge, dnsmasq, the routes and the NAT rules)

# --- Task 5 ------------------------------------------------------------
pveum realm add ad-corp --type pve
pveum user add jsmith@ad-corp --password "${JSMITH_PASSWORD}"
pveum role add VM-Operator -privs "VM.Console,VM.PowerMgmt,VM.Monitor"
pveum acl modify /vms/100 --users jsmith@ad-corp --roles VM-Operator
pveum acl modify /vms/101 --users jsmith@ad-corp --roles VM-Operator
pveum user token add automation@pve terraform --privsep 1
pveum acl modify /vms/100 --tokens 'automation@pve!terraform' --roles VM-Operator

# --- Task 6 ------------------------------------------------------------
pvesm download-url nfs-lab https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 debian-13-genericcloud.qcow2
qm create 9000 --name debian13-template --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --ostype l26 \
  --machine q35 --bios ovmf --agent "enabled=1,fstrim_cloned_disks=1" \
  --tablet 1 --onboot 1 --ide2 local:cloudinit --ipconfig0 ip=dhcp
qm importdisk 9000 nfs-lab:debian-13-genericcloud.qcow2 nfs-lab
qm set 9000 --scsi0 nfs-lab:vm-9000-disk-0,discard=on,iothread=1 \
  --efidisk0 nfs-lab:1,efitype=4m,pre-enrolled-keys=1 --boot order=scsi0
qm set 9000 --cicustom local:/tmp/ci-9000.yaml
qm start 9000
qm template 9000

# --- Task 7 ------------------------------------------------------------
qm clone 9000 100 --name web01 --full --storage nfs-lab
qm set 100 --cores 2 --memory 4096 --net0 virtio,bridge=vmbr0,tag=20 \
  --scsi0 nfs-lab:vm-100-disk-0,discard=on,iothread=1 \
  --agent "enabled=1,fstrim_cloned_disks=1" --onboot 1
qm set 100 --cicustom local:/tmp/ci-100.yaml
qm start 100
# ... the same for 101 / web02

# --- Task 8 ------------------------------------------------------------
pvesm download-url nfs-lab http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst debian-13-standard_13.6-1_amd64.tar.zst
pct create 300 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname app01 --memory 1024 --cores 1 --rootfs nfs-lab:8 \
  --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp \
  --unprivileged 1 --ostype debian --onboot 1 --features nesting=1 \
  --password "${GUEST_PASSWORD}"
# ... the same for 301 / db01 (tag 40) and 302 / cache01 (tag 30)

# --- Task 9 ------------------------------------------------------------
qm clone 9000 102 --name web-test --storage nfs-lab
qm set 102 --cores 2 --memory 4096 --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1" --cicustom local:/tmp/ci-102.yaml
qm start 102

# --- Task 10 -----------------------------------------------------------
qm snapshot 100 pre-update --description "before the release"
qm guest exec 100 -- sh -c 'echo release-2.4 > /etc/nordwind-version'
qm rollback 100 pre-update
qm delsnapshot 100 pre-update

# --- Task 11 -----------------------------------------------------------
qm migrate 100 pve2 --online

# --- Task 12 -----------------------------------------------------------
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT
pvesh create /nodes/pve1/qemu/100/firewall/rules --action ACCEPT --type in \
  --dport 5432 --proto tcp --source 10.10.20.0/24

# --- Task 13 -----------------------------------------------------------
pvesh create /cluster/backup --storage pbs-main --vmid 100,301 \
  --schedule daily --mode snapshot --enabled 1 --compress zstd \
  --retention-keep-daily 7 --retention-keep-weekly 4 --retention-keep-monthly 6
vzdump 100 --storage pbs-main --mode snapshot
vzdump 301 --storage pbs-main --mode snapshot
qmrestore pbs-main:backup/vm/100/<timestamp> 190 --storage nfs-lab

# --- Task 14 -----------------------------------------------------------
ha-manager add group prod-nodes --nodes pve1,pve2,pve3
ha-manager add vm:100 --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add vm:101 --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add ct:301 --group prod-nodes --max_restart 3 --max_relocate 2

# --- Task 15 -----------------------------------------------------------
pvesh create /cluster/notifications/endpoints/sendmail --name ops-mail
pvesh create /cluster/notifications/matchers/system-mail --type sentry \
  --notification-template all

# --- Task 16 -----------------------------------------------------------
qm snapshot 100 incident --description "before the diagnosis"
qm guest cmd 100 ping
journalctl -u pveproxy --since "10 min ago" --no-pager
```

---

## Appendix B - what the students get wrong

| Symptom | Cause | Fix |
|---|---|---|
| `pvecm add` fails with `Host key verification failed` | The joining node does not know the seed node's key | `ssh-keyscan` into `/root/.ssh/known_hosts` on the joining node |
| `apt update` returns 401 | The `enterprise` repository is still configured | Remove `pve-enterprise.list` |
| The guest has no address | dnsmasq is not running, or the bridge has no address | `systemctl status dnsmasq`, `ip a show vmbr0` |
| The guest has an address but no route | The NAT rules are missing | `iptables -t nat -L POSTROUTING -n -v` |
| The clone has the template's hostname | The cloud-init drive was not replaced | `qm set <id> --cicustom local:/tmp/ci-<id>.yaml` |
| `migrate VMs with local disks are not supported` | The disk is on `local-lvm` | Move it to `nfs-lab` - this is the lesson |
| `cannot add HA managed resource: storage is not shared` | Same reason | The disk has to be on `nfs-lab` |
| The restore fails with `VM 100 already exists` | The restore target VMID is taken | Restore into a new VMID |
| The web UI shows a certificate warning | The default self-signed certificate | `pvenode acme cert order --acme selfsigned` |
| The web UI is unreachable after enabling the firewall | The rules were written after the default deny | Write the rules first, keep an SSH session open |
