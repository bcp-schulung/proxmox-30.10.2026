# The scenario - Nordwind Logistics

Nordwind Logistics is a fictional mid-size freight and warehousing company. The
seminars use it as the running example: the students build the whole
infrastructure for the company on their own Proxmox cluster, and every
exercise adds one piece of it.

Keeping one company across all exercises has two benefits. The students see
the infrastructure grow instead of seeing twenty unrelated demos, and every
number in the exercises (VLAN IDs, VMIDs, hostnames) stays the same, so the
reference solution in one exercise is still valid in the next one.

---

## 1. The business

Nordwind moves freight between 14 warehouses across northern Europe. It runs:

- a **customer portal** - the public website, where customers track shipments
- a **dispatch system** - the internal application the warehouse staff use
- a **warehouse database** - shipments, pallets, invoices
- a **tracking cache** - a short-lived Redis-style cache for the portal
- a **monitoring stack** - the internal Grafana/Prometheus pair

The company has a small IT team. There is no separate hypervisor team, no
vCenter and no storage array - the whole platform runs on Proxmox VE.

## 2. The tier model

| Tier | VLAN | Address range | Guest type | Why |
|---|---|---|---|---|
| Management | 10 | 10.10.10.0/24 | - | cluster, web UI, SSH |
| Web | 20 | 10.10.20.0/24 | VM | public facing, must be migratable and highly available |
| Application | 30 | 10.10.30.0/24 | LXC | internal service, Linux only, trusted |
| Database | 40 | 10.10.40.0/24 | LXC | stateful, needs its own backup schedule |
| Operations | 50 | 10.10.50.0/24 | LXC | monitoring, no customer traffic |

The tier model decides two things that the students have to reason about:

- **VM or container.** The web tier runs as a VM, because it is the tier that
  has to be live-migrated and restarted by HA. The application, database and
  operations tiers run as unprivileged containers, because they are Linux-only,
  trusted, and a lot of them are needed. This is exactly the decision table
  from Day 2 of the Introduction course.
- **Storage.** Everything that has to survive a node failure - the web tier,
  the database, and all of the backups - lives on shared storage. The
  application tier, which can be recreated, may live on the fast local
  storage.

## 3. The inventory

The exercises build up to this final state:

```
Cluster "prod-cluster"          3 nodes, quorate
├── pve1 / pve2 / pve3           m8i.4xlarge, PVE 9.2
│
├── Storage
│   ├── local-lvm                node local, LVM-thin  (fast, disposable)
│   ├── nfs-lab                  shared, NFS 4.1       (migratable, HA-able)
│   └── pbs-main                 backup target, PBS
│
├── Guests
│   ├── VM  9101  debian13-tpl-pve1   template, on pve1's local-lvm
│   ├── VM  9102  debian13-tpl-pve2   template, on pve2's local-lvm
│   ├── VM  9103  debian13-tpl-pve3   template, on pve3's local-lvm
│   ├── VM  9201   debian13-run-pve1                web tier,    VLAN 20, HA managed
│   ├── VM  9202   debian13-run-pve2                web tier,    VLAN 20, HA managed
│   ├── VM  9203   debian13-run-pve3             full clone,  VLAN 20, test only
│   ├── CT  300   app01                app tier,    VLAN 30
│   ├── CT  301   db01                 db tier,     VLAN 40
│   └── CT  302   cache01              app tier,    VLAN 30
│
├── Identity
│   ├── realm  ad-corp           (the 'pve' realm type in the lab)
│   ├── user   jsmith@ad-corp    operations engineer
│   ├── role   VM-Operator       VM.Console,VM.PowerMgmt,VM.Monitor
│   └── token  automation@pve!terraform   privilege separated
│
├── High availability
│   └── group  prod-nodes        pve1,pve2,pve3
│
└── Backups
    └── job    daily, 7/4/6 retention, snapshot mode, to pbs-main
```

## 4. The addressing plan

The lab cannot give the guests real VPC addresses - AWS only routes to
addresses that belong to a network interface. The guests therefore live on a
private overlay that the node provides, and the Nordwind tiers are carried as
802.1Q VLAN tags over the single `vmbr0` bridge.

```
   AWS VPC 10.20.0.0/16
      │
      ├── 10.20.0.0/24   pve1 .41   pve2 .33   pve3 .28   nfs1 .20   pbs1 .21
      │                  management, corosync, web UI, NFS, PBS
      │
      └── guest overlay (per node, because the nodes route between each other)
             pve1  10.10.10.0/24  gw 10.10.10.1
             pve2  10.10.20.0/24  gw 10.10.20.1
             pve3  10.10.30.0/24  gw 10.10.30.1
```

Inside the overlay the Nordwind tiers are VLAN tags:

```
   vmbr0 (VLAN aware)
      │
      ├── tag 10  management   10.10.10.0/24
      ├── tag 20  web          10.10.20.0/24
      ├── tag 30  application  10.10.30.0/24
      ├── tag 40  database     10.10.40.0/24
      └── tag 50  operations   10.10.50.0/24
```

**A note for the students.** The VLANs are a *design* exercise here, not a
routing exercise. The lab's dnsmasq hands out one address range per node, so
a guest that is tagged into VLAN 20 still gets its address from the node's
DHCP server. What the students build and verify is the segmentation itself -
that the tag is on the NIC, that the bridge knows about it, and that the
firewall rules follow the tier model. On real hardware the VLANs would each
have their own DHCP scope; the segmentation logic is identical.

## 5. The build order

The long exercise follows this order, and each topic example maps to one of
the steps:

| Step | Topic | Result |
|---|---|---|
| 1 | Platform and node setup | 3 nodes with a repository, a hostname, a correct time source |
| 2 | Cluster formation | `prod-cluster`, quorate, 3 members |
| 3 | Storage | `local-lvm`, `nfs-lab`, `pbs-main` |
| 4 | Networking | `vmbr0`, VLAN aware, DHCP, routing between the nodes |
| 5 | Identity | realm, user, role, ACL, API token |
| 6 | The golden image | template `9101` |
| 7 | The web tier | VM 9201 + 9202, full clones, agent enabled |
| 8 | The container tiers | CT 300, 301, 302 |
| 9 | Cloning and testing | VM 9203, linked clone |
| 10 | Snapshots | snapshot, change, rollback |
| 11 | Live migration | VM 9201 to another node |
| 12 | Segmentation | VLAN tags per tier, firewall rules |
| 13 | Backup | backup job, retention, restore |
| 14 | High availability | HA group, HA managed guests |
| 15 | Monitoring and operations | metrics, notifications, task log |
| 16 | Troubleshooting | the guest-or-host decision tree |

Steps 1-5 are the cluster. Steps 6-11 are the workloads. Steps 12-14 are the
protection. Steps 15-16 are the day-2 operations.

## 6. The rules of the game

1. **The cluster is the source of truth.** Everything lives in `/etc/pve`, and
   `/etc/pve` is replicated by corosync. A change made on `pve1` is visible on
   `pve3` within milliseconds. The exercises show this on purpose.
2. **Shared storage is a precondition, not an optimisation.** Live migration
   and HA both require it. The students discover this themselves in the
   migration and HA exercises.
3. **Least privilege by default.** The operator account is not `root@pam`
   with everything. There is a narrow role, and the API token has its own ACL.
4. **The backup is not the backup.** A backup that was never restored is not a
   backup. The restore step is part of every backup exercise.
5. **Every exercise is verified.** Each `exercise.sh` runs the same checks
   the instructor runs. The student can check their own work before the
   instructor does.
