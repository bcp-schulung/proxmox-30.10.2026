# Seminar exercises on the AWS lab

Every exercise from the course material, mapped onto the cluster the harness builds.
Commands are the ones from the decks - the lab was designed so they work unchanged.
Where AWS forces a deviation, it is called out explicitly.

**Lab inventory**

| Object | Name | Storage | Notes |
|---|---|---|---|
| Cluster | `prod-cluster` | | 3 nodes, quorate |
| Node | `pve1`, `pve2`, `pve3` | | 10.20.0.11 / .12 / .13 |
| Storage | `local-lvm` | node-local | LVM-thin |
| Storage | `nfs-lab` | shared | NFS, enables live migration and HA |
| Storage | `pbs-main` | shared | Proxmox Backup Server |
| Bridge | `vmbr0` | | 10.10.10.1 / 10.10.20.1 / 10.10.30.1 |
| Template | VM 9000 `debian13-template` | `nfs-lab` | Debian 13, cloud-init, guest agent, on pve1 |
| VM | 100 `web01` | `nfs-lab` | Full clone, on pve1 - the live-migration target |
| VM | 101 `web02` | `nfs-lab` | Full clone, on pve2 |
| VM | 102 `web-test` | `nfs-lab` | **Linked** clone of 9000, on pve3 |
| CT | 300 `app01` | `nfs-lab` | Unprivileged LXC, on pve1 |
| CT | 301 `db01` | `nfs-lab` | Unprivileged LXC, on pve2 |

The guests are spread over the nodes so that the cluster behaves like a real one and so
that the shared storage is genuinely exercised. `provision.sh` prints the final placement
when it finishes, and you can check it at any time:

```bash
pvesh get /cluster/resources | grep -E 'qemu|lxc'
```

**Getting in**

```bash
ssh -i .state/keys/pve-lab.pem root@<node-public-ip>
# password for the web UI: see .env (PVE_ROOT_PASSWORD)
```

---

## Day 1 - Platform fundamentals

### Exercise: the cluster exists and is quorate

```bash
pvecm status
pvesh get /cluster/resources
```

Expect three members and `Quorate: Yes`. Open the web UI and look at
**Datacenter → Permissions → Groups** - `/etc/pve` is identical on every node because
pmxcfs replicates it over corosync.

### Exercise: storage backends

```bash
pvesm status
```

Three entries: `local-lvm` (node-local), `nfs-lab` (shared) and `pbs-main`.
This is the exact point the course makes on Day 3 - **live migration and HA only work
on shared storage.**

### Exercise: the network

```bash
ip a
bridge vlan show
cat /etc/network/interfaces
```

The management interface `eth0` is a plain interface, `vmbr0` is the guest bridge. Read
`docs/ARCHITECTURE.md` section 2 before you explain why to the audience.

### Exercise: users, realms, roles

```bash
pveum user list
pveum acl list
pveum user permissions jsmith@ad-corp
```

See the security day below for the full RBAC exercise.

---

## Day 2 - VMs and containers

### Exercise: the VM lifecycle

```bash
qm status 100
qm config 100
qm showcmd 100              # the exact QEMU command line
qm start 100
qm shutdown 100
```

### Exercise: a template and its clones

The lab is pre-provisioned with all three, but the exercise is to build one yourself:

```bash
qm clone 9000 110 --name web03 --full        # full clone
qm clone 9000 120 --name web04               # linked clone
qm set 110 --net0 virtio,bridge=vmbr0
qm start 110
```

Then compare them - the linked clone shares the base disk and is created in seconds:

```bash
qm config 110 | grep scsi0
qm config 120 | grep scsi0
```

### Exercise: resources

```bash
qm set 100 --sockets 1 --cores 4 --cpulimit 2 --cpuunits 2048
qm set 100 --memory 8192 --balloon 4096
qm resize 100 scsi0 +10G
qm set 100 --scsi1 nfs-lab:5
```

### Exercise: snapshots and rollback

```bash
qm snapshot 100 pre-update --description "Before patching"
# ... make a change inside the guest ...
qm rollback 100 pre-update
qm delsnapshot 100 pre-update
```

### Exercise: live migration

VM 100 lives on the shared storage, so it can move between the nodes:

```bash
qm migrate 100 pve2 --online
pvecm status
qm list
```

The downtime is well under a second. This is the exercise that proves why `nfs-lab`
exists.

### Exercise: containers

```bash
pct config 300
pct enter 300
pct exec 300 -- systemctl status qemu-guest-agent
pct config 301
```

Inside the container, compare with a VM:

```bash
# in the container
ip a                       # shares the host kernel
cat /proc/1/cgroup
```

### Exercise: virtIO and the guest agent

```bash
qm set 100 --agent enabled=1,fstrim_cloned_disks=1
qm guest cmd 100 ping
qm guest exec 100 -- ip a
```

---

## Day 3 - Storage, backup, operations

### Exercise: backup to Proxmox Backup Server

```bash
vzdump 100 --storage pbs-main --mode snapshot
vzdump 300 --storage pbs-main --mode snapshot

pvesm list pbs-main --content backup
```

Restore into a new VM:

```bash
qmrestore pbs-main:backup/vm/100/2026-11-10T02:00:00Z 130 --storage nfs-lab
qm start 130
```

### Exercise: backup jobs and retention

```bash
pvesh get /cluster/backup
pvesh create /cluster/backup --storage pbs-main --vmid 100 --schedule 'daily' \
    --mode snapshot --enabled 1 --retention-keep-daily 7
```

### Exercise: high availability

```bash
ha-manager add vm:100 --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager status
```

HA needs shared storage. VM 100 is on `nfs-lab`, so it qualifies. To see the failure
handling:

```bash
aws ec2 stop-instances --instance-ids <pve2-instance-id>
ha-manager status          # watch the resource move
```

### Exercise: monitoring and notifications

```bash
pvesh get /cluster/metrics
pvesh get /cluster/status
pvesh get /cluster/log --limit 50
```

### Exercise: troubleshooting - guest or host?

```bash
qm status 100 && qm showcmd 100
journalctl -u pve-container@300 -f
pvesm status
dmesg -T | tail -50
journalctl -u pvedaemon -u pveproxy -u pvestatd --since "1 hour ago"
```

---

## Migration course - lab 33 "Build the target from scratch"

The seven steps from the migration deck, already done by the harness - walk through them
in the order they happen:

| Step | Where it happens |
|---|---|
| 1. Install Proxmox VE | `packer/scripts/10-proxmox-repo.sh` and `20-proxmox-install.sh` |
| 2. Configure repositories and updates | `pve-install-repo.sources`, `pve-no-subscription` |
| 3. Create a bridge with VLAN awareness | `scripts/node-bootstrap.sh`, section 4 |
| 4. Create storage | `scripts/node-bootstrap.sh`, section 3 (LVM-thin) and phase `storage` (NFS) |
| 5. Create a test VM and boot it | Phase `guests` |
| 6. Configure a PBS backup target | Phase `backup` |
| 7. Run a backup and a restore | The Day 3 exercise above |

### Migration mapping exercise (VMware → Proxmox)

| VMware concept | Proxmox equivalent | In this lab |
|---|---|---|
| vSwitch / Distributed vSwitch | Linux bridge (`vmbr0`) | `vmbr0` on every node |
| Port group | Bridge + VLAN tag on the NIC | `qm set 100 --net0 virtio,bridge=vmbr0,tag=20` |
| Trunk port group | VLAN-aware bridge | `bridge-vlan-aware yes` |
| VMkernel port | Host IP on the bridge or a separate interface | Host IP on `eth0` |
| dvUplink / NIC teaming | Bond (`bond0`) as a bridge port | Not available - see below |

### Function test matrix (migration day 2)

```bash
# Boot
qm status 100
# Reboot
qm reboot 100
# Shutdown
qm shutdown 100
# Network
qm guest exec 100 -- ip a
# Storage
qm guest exec 100 -- lsblk
# Agent
qm guest cmd 100 ping
# Snapshot
qm snapshot 100 post-migration-test && qm rollback 100 post-migration-test
```

### Verification script (migration day 2, appendix B)

```bash
pct exec 300 -- bash -c '
  echo "Hostname: $(hostname)"
  ip -brief a
  echo "Default route:"; ip route | grep default
  echo "DNS:"; getent hosts example.com
  echo "Disk:"; lsblk
  echo "Agent:"; systemctl is-active qemu-guest-agent
  echo "Failed units:"; systemctl --failed --no-legend'
```

---

## Security course

### Day 1, lab 10 "Hardening a Proxmox node"

The harness already applies the parts that are safe to automate. The interactive parts
are the exercise:

```bash
# 1. SSH hardening
sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

> Watch out: the harness uses SSH key access, so this is safe here. On a fresh node,
> install the key **before** disabling password authentication.

```bash
# 2. Two-factor for an administrative realm
pveum realm add ad-corp --type pve --comment "seminar realm"
pveum realm modify ad-corp --tfa type=oath,digits=6,step=30
```

> **Deviation:** the deck adds an Active Directory realm. There is no directory server
> in this lab, so the built-in `pve` realm type is used under the deck's name. The
> commands are otherwise identical.

```bash
# 3. A narrow custom role
pveum role add VM-Operator -privs "VM.Console,VM.PowerMgmt,VM.Monitor"
pveum acl modify /vms/100 --users jsmith@ad-corp --roles VM-Operator

# 4. A privilege-separated API token with its own ACL
pveum user token add automation@pve terraform --privsep 1
pveum acl modify /vms/100 --tokens 'automation@pve!terraform' --roles VM-Operator
```

```bash
# 5. The cluster certificate
pvenode acme account register default admin@example.com
pvenode acme plugin add selfsigned directory
pvenode acme cert order --acme selfsigned --nodes pve1 --domains pve1.seminar.local
```

> **Deviation:** the deck uses Let's Encrypt through ACME, which needs a public DNS name
> and port 80/443. The lab uses the built-in self-signed ACME plugin, which gives the
> same outcome - one certificate that covers every node - without the DNS dependency.

```bash
# 6. The audit log
pvesh get /cluster/log --limit 200
pveum acl list
pveum user permissions jsmith@ad-corp
```

### Day 2, capstone lab "Securing a Proxmox cluster end to end"

```bash
# 1. Default-deny at the datacenter level
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT
```

> **Order matters.** Enabling the default-deny policy without the rules below cuts the
> cluster apart - corosync runs on UDP 5405-5412 and the web UI on 8006. Add the rules
> first, and keep an SSH session open while you test.

```bash
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
    --dport 8006 --proto tcp --source <your-ip>/32
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
    --dport 22 --proto tcp --source <your-ip>/32
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
    --dport "5405:5412" --proto udp --source 10.20.0.0/16
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
    --dport 2049 --proto tcp --source 10.20.0.0/16
```

```bash
# 2. Per-workload firewall
pvesh create /nodes/pve1/qemu/100/firewall/rules \
    --action ACCEPT --type in --dport 443 --proto tcp --source 10.10.10.0/24

# 3. Segmentation with a VLAN tag
qm set 100 --net0 virtio,bridge=vmbr0,tag=30
bridge vlan show

# 4. An SDN zone
pvesh create /cluster/sdn/vnets --vnet mgmtnet --zone mgmt-zone
```

```bash
# 5. Client-side encrypted backups
proxmox-backup-client key create /etc/pve/priv/storage/pbs-main.enc
proxmox-backup-client key paperkey /etc/pve/priv/storage/pbs-main.enc
```

> The paper key is the only way back into the encrypted backups. Collect it from the
> attendees - this is the exercise.

```bash
# 6. Log forwarding to a central target
cat >> /etc/rsyslog.d/90-siem-forward.conf <<'EOF'
*.* @@siem.example.com:514
EOF
systemctl restart rsyslog
```

```bash
# 7. Patch management
apt list --upgradable
pveversion -v
```

```bash
# 8. The audit trail
pvesh get /cluster/log --limit 200
```

### Encryption at rest

The deck uses ZFS:

```bash
zfs create -o encryption=aes-256-gcm -o keyformat=passphrase tank/encrypted-vms
```

> **Deviation:** AWS does not support ZFS on EBS - the kernel refuses it on a managed
> block device. Use the shared NFS storage for the segment instead, and discuss what
> "encryption at rest" means when the host holds the keys.

### PCIe passthrough (migration day 3, section 9)

> **Not available.** PCI passthrough needs IOMMU groups from real hardware. On a nested
> virtualisation layer there is no IOMMU to hand to the guest. Use this as the
> discussion point: *which features of a hypervisor survive being virtualised?*

---

## Exercises that need a human

| Exercise | Why |
|---|---|
| The web UI walkthrough | Needs a browser |
| ISO installation into a VM | The lab uses cloud images instead - see the note in `docs/ARCHITECTURE.md` |
| The migration import (VMware → Proxmox) | Needs a source vSphere environment |
| The `pveum` TOTP enrolment | Needs a phone with an authenticator app |
| The Let's Encrypt certificate | Needs a public DNS name |

## Cleaning up after the lab

```bash
./shutdown.sh              # stop everything, keep it for the next day
./clean.sh --scope cluster # destroy the guests and reset the cluster
./clean.sh --scope all     # remove the AWS resources as well
```
