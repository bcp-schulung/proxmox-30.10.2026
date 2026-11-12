# Seminar Runbook

A guideline for running the **Proxmox VE Introduction** seminar in this lab.
Every block is **15 minutes**.

Each block describes roughly **what happens next** - the topic, the task, the
point to make, and what to check before moving on. It is deliberately not a
script: the commands live in the exercise material, which is on the nodes and
in front of the students. Read this to know where you are and what to look
for, and let the exercise do the rest.

The seminar is a **long exercise** (tasks 1-16) with **topic exercises** woven
through it. The students build the Nordwind Logistics platform themselves;
each topic exercise is the reference example and the self-check for the task
it belongs to.

---

## Before the students arrive

| Step | Why |
|---|---|
| `./tests/selftest.sh` | The harness itself. Must be 0 failures. |
| `bash exercises/validate.sh` | The exercise tree. Must be all OK. |
| `bash exercises/deploy.sh` | Puts the exercise material on all three nodes. |
| `./debug.sh` | Full report on AWS, network, nodes, cluster and guests. |

The deploy step is the one that is easy to forget, and without it every
`exercise.sh` is missing on the nodes.

### The starting state

| Node | Template | Guest |
|---|---|---|
| pve1 | 9101 `debian13-tpl-pve1` | 9201 `debian13-run-pve1` (running) |
| pve2 | 9102 `debian13-tpl-pve2` | 9202 `debian13-run-pve2` (running) |
| pve3 | 9103 `debian13-tpl-pve3` | 9203 `debian13-run-pve3` (running) |

Everything else is the students' work. The guests are **bare clones** of the
Debian cloud image - they boot, but they have no network and no guest agent,
and that is deliberate.

### Decide this before the seminar

Two topics are **hands-on** - the objects do not exist when the seminar
starts and the students create them:

| Topic | Object |
|---|---|
| 06 - Identity and access control | realm, user, role, ACLs, token |
| 07 - The golden image and the template | the image and the template |

If you would rather hand these over ready-made, `provision.sh --with-security`
creates the identity objects for you.

### Two ways to run the lab

| Mode | When |
|---|---|
| **On the existing cluster** | You keep the running guests and templates. Tasks 1 and 2 are then already done - show the verification instead of making them do it. |
| **From scratch** | The students build everything. Run `reset.sh --all` on each node first. It dissolves the cluster, removes the storages, the guests and the identities, and leaves three standalone Proxmox nodes with their network configured. It is idempotent. |

---

## How to use the blocks

Each block has three parts:

| Part | Meaning |
|---|---|
| **Topic** | What this block is about |
| **Move** | What happens next - the demo, the task, the point |
| **Check** | The verification, and what a pass looks like |
| **Watch for** | What usually goes wrong |

**The verification is the spine of the seminar.** Run the exercise for the
current topic after every block. If it passes, move on. If it fails, the
`FAIL` line names what is missing - that is the teaching moment, not an
interruption.

```bash
cd /opt/exercises/topics/<topic>
./exercise.sh
```

**Keep the clock.** When you are behind, drop the blocks marked
**[optional]** first, then task 14 (high availability), then the
supplementary topics. Do not drop the verification - that is the part the
students learn.

---

# Day 1 - the platform and the workloads

*Tasks 1-8. Roughly 8 hours of contact time.*

## Block 1.0 - Opening

**Topic**
Welcome, the agenda, and the scenario.

**Move**
Introduce Nordwind Logistics - a freight and warehousing company with four
tiers: web, application, database and operations. The web tier is VMs, the
rest are containers, and that decision is what the whole platform hangs on.
Get everyone onto a node and looking at `pveversion`.

**Check**
Everyone has a terminal open on a node.

**Watch for**
The nodes log in as `admin`, not `root`, from the lab host.

---

## Block 1.1 - Task 1, node preparation

**Topic**
Getting a single node ready.

**Move**
What a node looks like before it is prepared: identity, time, package
sources, firewall. The no-subscription repository and the removal of the
enterprise repository file are a deliberate first step, not a detail. The
node firewall comes last.

**Check**
Topic 01 - `28 passed, 0 failed, 1 skipped`. The skip is `chronyc` not
being installed.

**Watch for**
The clock check fails on a node that has been off for a while.

---

## Block 1.2 - Task 1, continued

**Topic**
The node firewall.

**Move**
Why `vmbr0` has no physical port in this environment and what that does to
guest addressing. Walk the rules and say what each one is for. The
verification runs per node, so the students run it on their own node.

**Check**
Topic 01 again - `28 passed, 0 failed`.

**Watch for**
On the existing cluster this task is already done. Use the block as a
demonstration.

---

## Block 1.3 - Task 2, cluster formation

**Topic**
Turning three independent nodes into one cluster.

**Move**
The seed node, the join, and the quorum. Show that `/etc/pve` is a cluster
filesystem - a change on one node is on the others within milliseconds, and
the students do not have to repeat commands on every node.

**Check**
Topic 03 - `16 passed, 0 failed`.

**Watch for**
**The most common failure in the whole seminar.** The join fails when the
seed node's host key is unknown. Put the seed node's key into
`/root/.ssh/known_hosts` on the joining node *before* the students start
this task.

---

## Block 1.4 - Task 2, continued

**Topic**
The cluster as a running thing.

**Move**
The corosync rings and the votequorum provider. What happens when a node
leaves, and how the other two carry on. Run the verification from every
node.

**Check**
Topic 03 - `16 passed, 0 failed` from each node.

**Watch for**
A node that has joined but still shows `Quorate: No`. That is a corosync
problem, not a `pvecm` problem.

---

## Block 1.5 - Task 3, storage backends

**Topic**
Three storages and the rules they imply.

**Move**
`local-lvm` node-local, `nfs-lab` shared, `pbs-main` the backup target.
This is where the rule that the rest of the seminar depends on comes from: a
full clone can only be moved to another node if the source is on shared
storage, and a linked clone is a snapshot, which NFS does not support.
Demonstrate that the NFS storage really is shared.

**Check**
Topic 04 - `21 passed, 0 failed, 3 skipped`. The skips are the PBS checks -
the backup server is not part of this lab.

**Watch for**
The NFS mount fails because the export is not reachable from the node.

---

## Block 1.6 - Task 3, continued

**Topic**
Content types and what breaks without them.

**Move**
What `images`, `iso`, `vztmpl`, `backup`, `snippets` and `rootdir` are for,
and why `local-lvm` carries only two of them.

**Check**
Topic 04 again.

---

## Block 1.7 - Task 4, the guest network

**Topic**
How a guest reaches the outside world.

**Move**
The three layers: the VPC, the guest overlay, and the NAT between them.
Each node uses its **own** overlay subnet - that is deliberate, and it is
what makes the routing table meaningful.

**Check**
Topic 05 - `22 passed, 0 failed`.

**Watch for**
Students who give every node the same overlay subnet. The exercise checks
that they differ.

---

## Block 1.8 - Task 4, continued

**Topic**
NAT and routing between the overlays.

**Move**
The masquerade rule and the RETURN rules, and why the order matters - the
RETURN rules have to come first or the traffic to the NFS and backup
servers comes back to the wrong address. Traffic to the other overlays is
deliberately not NATed.

**Check**
Topic 05 again.

---

## Block 1.9 - Task 5, identity and access control

**Topic**
Who may do what.

**Move**
Realm, user, role, ACL, token. The built-in `pve` realm type under the name
`ad-corp`, because the lab has no directory server - the commands are
identical to production. **The narrow role is the point**: a role that grants
everything an operator needs is easy, a role that grants exactly what they
need is the work. This topic is hands-on, the objects do not exist yet.

**Check**
Topic 06 - `17 passed, 0 failed` when the work is done.

**Watch for**
The role is the easy part and the ACL is what students get wrong. The token
needs a **separate** ACL entry from the user's - that is what privilege
separation means.

---

## Block 1.10 - Task 5, continued

**Topic**
What a user can actually do.

**Move**
Effective permissions versus what the ACL says. The token ACL scoped to one
guest rather than to `/vms`.

**Check**
Topic 06 again.

---

## Block 1.11 - Task 6, the golden image and the template

**Topic**
Building the image the students will clone from.

**Move**
The image is a qcow2 disk, not an ISO, and the error message that tells you
so. Then the disk number trap: with an EFI disk already attached, the
imported OS disk lands on a different number than you would guess, and
attaching the wrong one gives a template that boots a 4 MB EFI partition
instead of Debian. Make the students check the disk size before they go on.

**Check**
Topic 07 - `19 passed, 0 failed`.

**Watch for**
This is where students lose the most time, and it is almost always the disk
number.

---

## Block 1.12 - Task 6, continued

**Topic**
Cloud-init and the template.

**Move**
The snippet and its `local:` prefix - a snippet with a password in it should
not sit on shared storage. Why the template carries no cloud-init drive while
every clone gets one: the drive lives on node-local storage, and Proxmox
refuses to clone a VM that uses node-local storage to another node.

**Check**
Topic 07 again.

---

## Block 1.13 - Task 7, the web tier

**Topic**
The first real workloads.

**Move**
The web tier is VMs because it has to be live-migratable and highly
available. The guest configuration, and the cloud-init drive that gives the
guest its own identity. **The guests are bare clones** - the cloud image
ships no configuration of its own, so the guest boots to a `localhost` prompt
with no network and no guest agent. That is the point of this block.

**Check**
Topic 08 - `19 passed, 0 failed, 1 skipped`. The skip is the guest-agent
check, which passes once the cloud-init drive is attached and the guest is
rebuilt.

**Watch for**
The exercise stops and starts the guest. It restarts it from a trap, but if
you interrupt it, check the guest is running before you move on.

---

## Block 1.14 - Task 7, continued

**Topic**
Stopping a guest, and the difference between two ways to stop it.

**Move**
`qm stop` against `qm shutdown`. A guest without the agent has to be stopped
with `qm stop`, which is the data loss version of the same operation. This is
the teaching point of the topic and it is exactly what a bare guest shows.
Then the snapshot, the change and the rollback.

**Check**
Topic 08 again.

---

## Block 1.15 - Task 8, the container tiers

**Topic**
The other three tiers.

**Move**
Application, database and operations as LXC containers, and why. The
comparison with a VM - a container shares the host kernel. Why the database
tier gets its own backup schedule.

**Check**
Topic 09.

**Watch for**
The container template has to be fetched first and the download is slow.
Start it early in the block.

---

## Block 1.16 - Day 1 checkpoint

**Topic**
Where we are.

**Move**
Run the acceptance test for everything so far and review the day's sticking
points with the group.

**Check**
The long exercise covers tasks 1-8. Use this block to decide what to drop if
you are behind.

---

# Day 2 - the protection and the operations

*Tasks 9-16, plus the supplementary topics.*

## Block 2.1 - Task 9, clones and test environments

**Topic**
Two ways to make a guest from a template.

**Move**
Full clone against linked clone - time, space, independence. A linked clone
shares the base disk, and deleting the template breaks every one of them;
Proxmox refuses to let you do it. Remind the group why the templates live on
`local-lvm`.

**Check**
Topic 10.

**Watch for**
A clone that boots with the **template's** hostname. It means the cloud-init
drive was not replaced, and it is the most common mistake in the seminar.

---

## Block 2.2 - Task 10, snapshots and rollback

**Topic**
Point-in-time copies.

**Move**
A snapshot of a running guest with the agent enabled includes the memory
state, so the rollback brings back a running guest. The disk grows and never
shrinks without `fstrim`.

**Check**
Topic 11.

**Watch for**
The rollback brings back the old hostname too. It surprises people.

---

## Block 2.3 - Task 11, live migration

**Topic**
Moving a running guest.

**Move**
Live migration needs the disk on shared storage, because the target node has
to be able to open the same volume. The guests of this lab are on
`local-lvm`, so the migration is refused - **that refusal is the lesson**.
Move the disk first, then migrate, and the guest never notices.

**Check**
Topic 12.

**Watch for**
A student who forces it with `--with-local-disks` and wonders why it takes
minutes. That is the copy, not the migration.

---

## Block 2.4 - Task 12, segmentation and firewall

**Topic**
Separating the tiers.

**Move**
The VLAN tags per tier, and the difference between the datacenter firewall
and the node firewall. The datacenter firewall is not enabled automatically
because it would cut off the web UI and corosync.

**Check**
Topic 13.

**Watch for**
No single right answer here. Grade the reasoning - does the rule set follow
the tier model?

---

## Block 2.5 - Task 12, continued

**Topic**
Comparing the designs.

**Move**
Walk through the students' rule sets. Put two different ones side by side
and ask the group which is right and why.

**Check**
Each group's exercise passes. The discussion is the point.

---

## Block 2.6 - Task 13, backup and restore

**Topic**
Backups, and the datastore.

**Move**
Backing up to the backup server in snapshot mode, and restoring into a
**new** VMID - restoring over the original would overwrite the evidence.

**Check**
Topic 14.

**Watch for**
**The restore has to work.** If the backup runs but the restore does not,
the task is not half done - it is not done. This carries 20% of the grade.

---

## Block 2.7 - Task 13, continued

**Topic**
Proving the backup is real.

**Move**
Restore a student's backup into a fresh VM and **boot it**, in front of the
group. A backup that was never restored is not a backup.

**Check**
Each group's restored VM starts and answers.

**Watch for**
The restore target VMID is already taken. Pick a free one before the block.

---

## Block 2.8 - Task 14, high availability

**Topic**
The cluster taking over a workload.

**Move**
The HA group and the HA manager, and what it needs - shared storage, for
the same reason live migration does. The same refusal, and the same fix.

**Check**
Topic 15.

**Watch for**
HA refuses the guest because it is on `local-lvm`, or because the HA group
does not exist yet. Both are common.
**[optional]** This is the designated task to drop if the group is slow.

---

## Block 2.9 - Task 14, continued

**Topic**
The failover.

**Move**
Take a node down and watch the resource move. The failure handling and the
restart policy.

**Check**
The resource moves to another node.

**Watch for**
The instance takes a minute or two to actually stop. Watch the HA status
until it moves before concluding HA is broken.

---

## Block 2.10 - Task 15, monitoring and notifications

**Topic**
Seeing what the cluster is doing.

**Move**
The metrics, the node and cluster status, and the notification targets.

**Check**
Topic 16.

---

## Block 2.11 - Task 16, troubleshooting

**Topic**
Finding the layer.

**Move**
The method: identify the layer - network, storage, cluster, guest - before
reaching for a fix.

**Check**
Topic 17.

**Watch for**
Also no single right answer. Grade the diagnosis, not the fix.

---

## Block 2.12 - Final acceptance test

**Topic**
Where the platform ended up.

**Move**
Run the full acceptance test with the group watching, then read out the
grade bands and the weighting.

**Check**
The long exercise - every check of every task.

| Result | Grade |
|---|---|
| 100% of the checks pass | Complete |
| 90-99% | Complete with remarks |
| 75-89% | Partial - the instructor names the gaps |
| below 75% | Not complete |

| Area | Weight |
|---|---|
| Cluster and storage (tasks 1-3) | 25% |
| Identity (task 5) | 15% |
| Backup and restore (task 13) | 20% |
| HA and migration (tasks 11, 14) | 20% |
| The rest | 20% |

---

## Supplementary topics

Standalone examples rather than numbered tasks. Reference material, extra
work for a fast group, or a follow-up session. Each has its own
verification.

| Block | Topic | Check | Duration |
|---|---|---|---|
| S1 | 02 - The platform architecture | `cd /opt/exercises/topics/02-platform-architecture && ./exercise.sh` | 45 min |
| S2 | 18 - Resource management | `cd /opt/exercises/topics/18-resource-management && ./exercise.sh` | 30 min |
| S3 | 19 - Updates and maintenance | `cd /opt/exercises/topics/19-updates-maintenance && ./exercise.sh` | 30 min |
| S4 | 20 - The API and automation | `cd /opt/exercises/topics/20-web-ui-automation && ./exercise.sh` | 30 min |

**S1** - The platform architecture: the same operation three ways, the
replication of the cluster filesystem, and the QEMU process underneath.

**S2** - Resource management: CPU and memory limits, the balloon device,
disk growth.

**S3** - Updates and maintenance: the repository, the update procedure, and
what to do when an update breaks something. The one to run before a real
maintenance window.

**S4** - The API and automation: the REST API, a privilege-separated token
and Terraform. This is where the identity work from task 5 pays off.

---

## If you need to recover

| Situation | What to do |
|---|---|
| A guest is stopped and should be running | `qm start <vmid>` |
| The exercises are missing on the nodes | `bash exercises/deploy.sh` from the repo root |
| The students are stuck on a `FAIL` | The `FAIL` line names the check. Read it against `requirements.md`. |
| A student broke their node | `reset.sh --all` on that node, then rejoin it to the cluster |
| Everything is in a mess | `reset.sh --all` on all three nodes and start over |
| The seminar is over | `./shutdown.sh` stops everything without destroying it. `./destroy.sh` removes the lab completely. |

---

## The short version

Five things to remember:

1. **Run the verification after every block.** The `FAIL` line is the lesson.
2. **The disk number trap.** A template whose disk is the wrong size boots
   an EFI partition instead of Debian.
3. **The clone trap.** A clone without its own cloud-init drive boots as
   the template.
4. **Shared storage.** No live migration, no HA. The refusal is the lesson.
5. **The restore has to work.** A backup that was never restored is not a
   backup.
