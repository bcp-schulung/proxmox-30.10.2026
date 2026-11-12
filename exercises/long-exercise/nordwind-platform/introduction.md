# Long Exercise - Build the Nordwind Logistics Platform on Proxmox VE

**Exercise ID:** `long-nordwind`
**Duration:** 2 days (16 hours of guided work, 8 hours of contact time)
**Difficulty:** Advanced
**Deliverable:** A running, secured, backed-up, highly available Proxmox VE
cluster that hosts the complete Nordwind Logistics infrastructure.

---

## 1. What this exercise is

Over two days you build the entire platform for **Nordwind Logistics**, a
fictional freight and warehousing company, on a Proxmox VE cluster that starts
empty.

Nothing is given to you. The three nodes exist and have Proxmox VE installed,
and that is all. The cluster does not exist, the storage does not exist, the
network does not exist, the guests do not exist, and there is no backup. You
build all of it.

The exercise is split into **16 tasks** that map onto the topics of the
Proxmox VE Introduction course. Each task has:

- a **goal** - what has to be true when the task is done
- a **requirement list** - the exact state you have to reach
- a **verification** - how the task is checked, and how you check it yourself

The instructor has a complete reference solution for every task. You do not
get it - you get the *requirements*, and you work out the commands. The
`exercise.sh` in this directory runs the whole verification suite, so you can
check your work at any moment.

## 2. The scenario

Nordwind Logistics moves freight between 14 warehouses. They run a customer
portal, an internal dispatch system, a warehouse database, a tracking cache and
a monitoring stack. The full description is in
[`../docs/SCENARIO.md`](../docs/SCENARIO.md).

The short version:

| Tier | VLAN | Guest type | Reason |
|---|---|---|---|
| Web | 20 | VM | must be live-migratable and highly available |
| Application | 30 | LXC | Linux only, trusted, many of them |
| Database | 40 | LXC | stateful, own backup schedule |
| Operations | 50 | LXC | monitoring, no customer traffic |

The infrastructure you are building:

```
Cluster "prod-cluster"          3 nodes, quorate
├── Storage: local-lvm (local), nfs-lab (shared), pbs-main (backup)
├── Guests: VM 9201/9202 (web), VM 9203 (test), CT 300/301/302 (app/db/cache)
├── Identity: realm ad-corp, user jsmith, role VM-Operator, API token
├── HA group prod-nodes, HA managed web tier
└── Daily backup job with 7/4/6 retention
```

## 3. The lab environment

### What you get

| Item | Value |
|---|---|
| Nodes | `pve1`, `pve2`, `pve3` |
| Cluster name | `prod-cluster` (you create it) |
| Management IPs | `10.20.0.41`, `10.20.0.33`, `10.20.0.28` |
| Shared storage server | `nfs1` at `10.20.2.20`, export `/export/lab` |
| Backup server | `pbs1` at `10.20.2.21`, datastore `main` |
| Guest overlay | `10.10.10.0/24` (pve1), `10.10.20.0/24` (pve2), `10.10.30.0/24` (pve3) |
| Root password | printed by the instructor at the start |

### What you do not get

- A running cluster - you create it in Task 2
- Any storage - you create it in Task 3
- Any guest - you create everything from Task 6 on
- Any credentials beyond the node root password

### Two important deviations from a real data centre

Read these before you start. They change how some tasks look.

**1. The management interface is not bridged.**
On real hardware the management IP usually sits on `vmbr0` and the physical
NIC is enslaved to the bridge. In this lab `eth0` keeps the VPC address and
`vmbr0` is a bridge *without* a physical port. The reason is AWS: it drops
traffic whose source MAC is not the one registered on the network interface,
so a bridge that owns its own MAC address would take the node offline - and
you would have no way back in.

What this changes for you: the guest bridge has no wire to the outside world.
The node provides DHCP, routing and NAT for the guests instead. Everything
else about the bridge - VLAN tags, `bridge vlan show`, `bridge link`, the
`vmbr0` naming - behaves exactly as it does on hardware.

**2. There is no ZFS.**
ZFS cannot run on an EBS block device. The storage exercises use LVM-thin and
NFS instead of ZFS. The reasoning behind the choice is identical.

## 4. How the two days are structured

### Day 1 - the platform and the workloads (8 tasks, ~8 hours)

| Task | Topic | Course reference |
|---|---|---|
| 1 | Node preparation | Intro Day 1, §4 |
| 2 | Cluster formation | Intro Day 1, §6 |
| 3 | Storage backends | Intro Day 1, §8 / Day 3, §2 |
| 4 | The guest network | Intro Day 1, §9 |
| 5 | Identity and access control | Intro Day 1, §7 |
| 6 | The golden image and the template | Intro Day 2, §4 |
| 7 | The web tier (VMs) | Intro Day 2, §2, §3 |
| 8 | The container tiers (LXC) | Intro Day 2, §5, §6 |

**Breakdown**

| | Hours |
|---|---|
| Guided instruction | 2.0 |
| Task 1-4 work (the cluster) | 2.0 |
| Task 5 work (identity) | 1.0 |
| Task 6-8 work (the workloads) | 2.5 |
| Checkpoint and review | 0.5 |

### Day 2 - the protection and the operations (8 tasks, ~8 hours)

| Task | Topic | Course reference |
|---|---|---|
| 9 | Clones and test environments | Intro Day 2, §4 |
| 10 | Snapshots and rollback | Intro Day 2, §8 |
| 11 | Live migration | Intro Day 2, §8 |
| 12 | Segmentation and firewall | Security Day 2, §2, §3 |
| 13 | Backup and restore | Intro Day 3, §3, §4 |
| 14 | High availability | Intro Day 3, §5 |
| 15 | Monitoring and notifications | Intro Day 3, §7 |
| 16 | Troubleshooting | Intro Day 3, §8 |

**Supplementary topics.** Four topics are taught as standalone exercises
rather than as numbered tasks of the long exercise. They are available as
reference examples and as optional extra work:

| Topic | Directory |
|---|---|
| 02 - The platform architecture | `../topics/02-platform-architecture/` |
| 18 - Resource management | `../topics/18-resource-management/` |
| 19 - Updates and maintenance | `../topics/19-updates-maintenance/` |
| 20 - The API and automation | `../topics/20-web-ui-automation/` |

**Breakdown**

| | Hours |
|---|---|
| Guided instruction | 1.0 |
| Task 9-11 work (workload management) | 1.5 |
| Task 12 work (segmentation) | 1.5 |
| Task 13-14 work (backup and HA) | 2.0 |
| Task 15-16 work (operations) | 1.5 |
| Final acceptance test | 0.5 |

## 5. The working method

### Work on the node, not on a laptop

Everything happens on the Proxmox nodes. Log in as root:

```bash
ssh root@10.20.0.41     # pve1
```

The `qm`, `pct`, `pvesm`, `pveum` and `pvesh` commands are the interface to
the platform. The web UI at `https://10.20.0.41:8006/` is the same API in a
browser - use whichever you prefer, but the exercises are written for the CLI
because the CLI is what you can script and what the verification uses.

### Check your work constantly

After every task, run the verification for that task. Each topic example has
its own `exercise.sh`:

```bash
cd /opt/exercises/topics/03-cluster-formation
./exercise.sh
```

It prints `PASS` or `FAIL` per check. A `FAIL` line tells you what is
missing. The full suite is at the end:

```bash
cd /opt/exercises/long-exercise/nordwind-platform
./exercise.sh
```

### The configuration is shared

`/etc/pve` is a cluster filesystem. A change you make on `pve1` is on `pve3`
within milliseconds. You do not need to run the same command on every node -
only the tasks that explicitly say "on each node".

The exceptions are the node-local things: `/etc/network/interfaces`, the
LVM-thin pool, and the firewall configuration in
`/etc/pve/nodes/<node>/host.fw`.

### Idempotency

Write your commands so that running them twice does not break anything.
`pvesm add` fails if the storage exists, `qm clone` fails if the VMID is
taken, `pveum acl modify` is safe to repeat. When a task says "add", check
first:

```bash
pvesm status
qm list
pveum acl list
```

## 6. The tasks

Each task below is a summary. The full requirement list, the exact
verification and the reference solution live in the per-task directory
`../topics/<task-id>/`.

| # | Task | Directory |
|---|---|---|
| 1 | Node preparation | `../topics/01-node-preparation/` |
| 2 | Cluster formation | `../topics/03-cluster-formation/` |
| 3 | Storage backends | `../topics/04-storage-backends/` |
| 4 | The guest network | `../topics/05-guest-network/` |
| 5 | Identity and access control | `../topics/06-identity-rbac/` |
| 6 | The golden image and the template | `../topics/07-template-cloning/` |
| 7 | The web tier | `../topics/08-vm-lifecycle/` |
| 8 | The container tiers | `../topics/09-lxc-containers/` |
| 9 | Clones and test environments | `../topics/10-clone-strategies/` |
| 10 | Snapshots and rollback | `../topics/11-snapshots-rollback/` |
| 11 | Live migration | `../topics/12-live-migration/` |
| 12 | Segmentation and firewall | `../topics/13-firewall-segmentation/` |
| 13 | Backup and restore | `../topics/14-backup-pbs/` |
| 14 | High availability | `../topics/15-ha/` |
| 15 | Monitoring and notifications | `../topics/16-monitoring/` |
| 16 | Troubleshooting | `../topics/17-troubleshooting/` |

## 7. Grading

The exercise is graded by the acceptance test - the `exercise.sh` in this
directory. It runs **every** check of every task and reports one line per
check.

| Score | Grade |
|---|---|
| 100% of the checks pass | Complete |
| 90-99% | Complete with remarks |
| 75-89% | Partial - the instructor names the gaps |
| below 75% | Not complete |

The weighting is not flat. These are the checks that matter most:

| Area | Weight | Why |
|---|---|---|
| Cluster and storage (Tasks 1-3) | 25% | everything else depends on it |
| Identity (Task 5) | 15% | the wrong permissions are a security incident |
| Backup and restore (Task 13) | 20% | a backup that was not restored is not a backup |
| HA and migration (Tasks 11, 14) | 20% | the point of a clustered hypervisor |
| The rest | 20% | |

A special note on Task 13: the restore has to work. If the backup runs but
the restore does not, the task is not half done - it is not done. The
instructor restores a backup into a fresh VM and boots it.

## 8. What is deliberately not in scope

| Topic | Why |
|---|---|
| Installing Proxmox from the ISO | The nodes are already installed. The ISO installer cannot boot on EC2. |
| ZFS | Not supported on EBS. LVM-thin and NFS cover the same concepts. |
| Ceph | A single hyper-converged cluster needs three dedicated OSD nodes with real disks. The NFS backend teaches the shared-storage rules that Ceph would apply. |
| PCI passthrough | Needs IOMMU groups from real hardware. A nested virtualisation layer has none. |
| Active Directory | There is no directory server in the lab. The built-in `pve` realm type is used under the name `ad-corp`, so the commands are identical. |
| Let's Encrypt / public ACME | Needs a public DNS name and port 80. The built-in self-signed ACME plugin gives the same outcome - one certificate for the whole cluster. |

Each of these is discussed with the students in its context, so they know why
it is missing and what it would look like in production.

## 9. Instructor notes

The complete reference for the instructor is in
[`solution.md`](solution.md). It contains the exact command sequence for all
16 tasks, in order, with the reasoning for the non-obvious choices.

### Setup before the exercise

```bash
# On each node, reset to the pre-exercise state.
./reset.sh --all
```

The script removes the cluster configuration, the storages, the guests and
the identities, and leaves the three nodes as standalone Proxmox installations
with their network already configured. It is idempotent.

### Timing

The exercise is written for two days of 8 hours each, with a 45 minute lunch
break and two coffee breaks per day. The task work is designed to fill the
hours - there is deliberately more to do than fits comfortably, so the
instructor can mark Task 14 (HA) as optional if the group is slow.

### Where the group gets stuck

| Task | Usual sticking point |
|---|---|
| 2 | The join fails because the host key of the seed node is unknown. `pvecm add --use_ssh` needs the key in `/root/.ssh/known_hosts`. |
| 3 | The NFS mount fails because the export is not reachable from the node. Check the route and the security group. |
| 6 | The template is created but the clone gets the wrong hostname, because the cloud-init drive was not updated for the clone. |
| 11 | The migration is refused because the VM is on `local-lvm`. That refusal is the lesson - move it to `nfs-lab` first. |
| 13 | The backup runs but the restore target VMID is already taken. |
| 14 | HA refuses the guest because it is not on shared storage, or because the HA group does not exist yet. |

### Grading the discussion, not just the result

Tasks 12 and 16 have no single right answer. The firewall rules and the
troubleshooting path depend on the group's design decisions. Grade the
*reasoning*: does the rule set follow the tier model, and does the diagnosis
identify the layer before it reaches for a fix?
