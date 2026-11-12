# Requirements - Long Exercise: Nordwind Logistics Platform

**Exercise ID:** `long-nordwind`

This is the complete requirement list for the 16 tasks. Each task states what
has to be true when it is done. Everything is verified by `exercise.sh`.

Conventions used throughout:

- `[ ]` a requirement
- **On each node** - the command has to run on `pve1`, `pve2` and `pve3`.
  Everything else runs once, on any node, because `/etc/pve` is shared.
- **idempotent** - running the step twice must not break anything.

---

## Task 1 - Node preparation

**Goal:** every node is a healthy, correctly named Proxmox installation that
can join a cluster.

### Requirements

- [ ] `pveversion` reports the installed Proxmox VE version on all three nodes.
- [ ] The hostname of each node is exactly its lab name (`pve1`, `pve2`, `pve3`).
- [ ] The hostname resolves to the node's own management address in
      `/etc/hosts` - not to `127.0.1.1`.
- [ ] `timedatectl` shows the system clock synchronised. A clock drift of more
      than 2 seconds breaks corosync and the cluster certificates.
- [ ] The `pve-no-subscription` repository is configured and the `enterprise`
      repository is absent, unless the node carries a subscription.
- [ ] `apt update` completes without an error.
- [ ] The Proxmox host firewall is enabled on each node with a default deny
      inbound policy.
- [ ] The firewall allows, at minimum: SSH (22) and the web UI (8006) from the
      operator network, and UDP 5405-5412 (corosync) and TCP 2049 (NFS) from
      the VPC.
- [ ] `pve-firewall` is running on all three nodes.

**Verification:** `../topics/01-node-preparation/exercise.sh`

---

## Task 2 - Cluster formation

**Goal:** the three nodes form one quorate cluster called `prod-cluster`.

### Requirements

- [ ] `pvecm status` on any node shows exactly three members.
- [ ] The cluster name is `prod-cluster`.
- [ ] `pvecm status` reports `Quorate: Yes`.
- [ ] The expected vote count is reported (3 members, quorum is 2).
- [ ] Every node can see every other node with `pvecm nodes`.
- [ ] Each node knows the SSH public key of the other nodes, so that
      `pvecm add --use_ssh` and the node-to-node management work.
- [ ] A configuration change made on one node is visible on the others within a
      second - for example a storage definition in `/etc/pve/storage.cfg`.
- [ ] The `pve-cluster` service is running on all three nodes.

**Verification:** `../topics/03-cluster-formation/exercise.sh`

---

## Task 3 - Storage backends

**Goal:** three storage backends are defined, and the students know which
workloads belong on which.

### Requirements

- [ ] `pvesm status` lists at least three storages:
  - [ ] `local-lvm` - LVM-thin, **node local**, content `images,rootdir`
  - [ ] `nfs-lab` - NFS, **shared**, content `images,rootdir,iso,vztmpl,backup,snippets`
  - [ ] `pbs-main` - Proxmox Backup Server, content `backup`
- [ ] `pvesm status` shows `nfs-lab` and `pbs-main` as `active` on **all three
      nodes**, and `local-lvm` as active on each node with its own usage.
- [ ] The `nfs-lab` storage is genuinely shared: a file written on `pve1` is
      visible on `pve2` and `pve3`.
- [ ] The PBS datastore `main` exists on the backup server and is reachable.
- [ ] The backup user `backup@pbs` exists and has at least the `DatastoreReader`
      and `DatastoreWriter` roles on the datastore `main`.
- [ ] `local-lvm` has a thin pool with free space on every node.

**Verification:** `../topics/04-storage-backends/exercise.sh`

---

## Task 4 - The guest network

**Goal:** the guests have a working network, and the students can explain how.

### Requirements

- [ ] A bridge `vmbr0` exists on all three nodes.
- [ ] The bridge is VLAN aware (`bridge-vlan-aware yes`).
- [ ] `bridge vlan show` lists the bridge.
- [ ] The bridge has an address in the node's overlay range and the address is
      the default gateway for that range.
- [ ] A DHCP server answers on the bridge - the node hands out addresses in the
      node's own overlay range.
- [ ] The guest overlay is routed: a guest on `pve1` can reach a guest on
      `pve2` by its own address.
- [ ] The guests can reach the outside world through NAT.
- [ ] The three nodes use **different** overlay subnets, so that the routing
      between them is explicit.

**Verification:** `../topics/05-guest-network/exercise.sh`

---

## Task 5 - Identity and access control

**Goal:** a human operator and an automation identity exist, and neither has
more access than it needs.

### Requirements

- [ ] A realm `ad-corp` exists.
- [ ] A user `jsmith@ad-corp` exists.
- [ ] A role `VM-Operator` exists with **exactly** these privileges:
      `VM.Console,VM.PowerMgmt,VM.Monitor`.
- [ ] The role is granted on the web tier guests only - the ACL path is
      `/vms/9201` (and `/vms/9202` if it exists), not `/`.
- [ ] `pveum user permissions jsmith@ad-corp` shows the granted privileges and
      nothing more.
- [ ] An API token `automation@pve!terraform` exists **with privilege
      separation enabled**.
- [ ] The token has its own ACL entry on `/vms/9201` with the `VM-Operator`
      role.
- [ ] The token's ACL is separate from the user's ACL - the token does not
      inherit the user's permissions.
- [ ] `pvesh get /cluster/log` shows the administrative actions of the
      session.

**Verification:** `../topics/06-identity-rbac/exercise.sh`

---

## Task 6 - The golden image and the template

**Goal:** a prepared guest image that can be cloned in seconds.

### Requirements

- [ ] A VM with the ID `9101` exists and is named `debian13-tpl-pve1`.
- [ ] VM 9101 is marked as a **template** (`qm template 9101` was run).
- [ ] The template has a cloud-init drive attached.
- [ ] The template has the QEMU guest agent enabled
      (`--agent enabled=1,fstrim_cloned_disks=1`).
- [ ] The template uses `virtio-scsi-single` as the disk controller.
- [ ] The template lives on the node-local LVM-thin storage `local-lvm`.
- [ ] `scsi0` is the 3 GB Debian disk, not the 4 MB EFI vars disk.
- [ ] The template boots and the guest agent answers
      (`qm guest cmd 9101 ping` succeeds while it is running).

**Verification:** `../topics/07-template-cloning/exercise.sh`

---

## Task 7 - The web tier

**Goal:** the customer-facing tier runs as highly available virtual machines.

### Requirements

- [ ] VM `9201` exists and is named `debian13-run-pve1`.
- [ ] VM `9202` exists and is named `debian13-run-pve2`.
- [ ] VM 9201 is a **full clone** of the template 9101 on pve1.
- [ ] VM 9202 is a **full clone** of the template 9102 on pve2 - each guest
      comes from the template of the node it runs on.
- [ ] Both live on the node-local LVM-thin storage `local-lvm`.
- [ ] Both have a disk of their own (`vm-<vmid>-disk-N`), not the base disk
      of a template.
- [ ] Both are configured with:
  - [ ] 2 vCPU (`--cores 2`)
  - [ ] 4096 MB memory
  - [ ] `virtio` network on `vmbr0` with the VLAN tag `20`
  - [ ] `virtio-scsi-single` disk controller
  - [ ] the guest agent enabled
  - [ ] `discard=on` and `iothread=1` on the disk
- [ ] VM 9201 and VM 9202 are running.
- [ ] The guest agent answers in both guests.

**Verification:** `../topics/08-vm-lifecycle/exercise.sh`

---

## Task 8 - The container tiers

**Goal:** the application, database and cache tiers run as unprivileged
containers.

### Requirements

- [ ] CT `300` exists, is named `app01`, and belongs to the application tier
      (VLAN 30).
- [ ] CT `301` exists, is named `db01`, and belongs to the database tier
      (VLAN 40).
- [ ] CT `302` exists, is named `cache01`, and belongs to the application tier
      (VLAN 30).
- [ ] All three are **unprivileged** (`--unprivileged 1`).
- [ ] All three use `nesting=1`.
- [ ] All three have a rootfs on the shared storage `nfs-lab`.
- [ ] Each container has its own hostname and a DHCP lease on the correct VLAN.
- [ ] All three are running.
- [ ] `pct exec <id> -- cat /proc/1/cgroup` shows the container is using the
      host kernel and cgroups - not a separate kernel.

**Verification:** `../topics/09-lxc-containers/exercise.sh`

---

## Task 9 - Clones and test environments

**Goal:** a disposable test environment that is created in seconds.

### Requirements

- [ ] VM `9203` exists, is named `debian13-run-pve3`.
- [ ] VM 9203 is a **linked clone** of template 9101.
- [ ] VM 9203 shares its base disk with the template (its `scsi0` refers to
      `base-9101-disk-0`).
- [ ] VM 9203 has its own cloud-init drive with its own hostname.
- [ ] VM 9203 runs on the shared storage.
- [ ] The template 9101 still exists and is still a template - a linked clone
      depends on it.

**Verification:** `../topics/10-clone-strategies/exercise.sh`

---

## Task 10 - Snapshots and rollback

**Goal:** a change can be undone.

### Requirements

- [ ] VM 9201 has a snapshot named `pre-update`.
- [ ] The snapshot carries a description.
- [ ] A file that was created after the snapshot is gone after the rollback.
- [ ] The snapshot can be deleted after the rollback.
- [ ] The guest stays reachable through the whole cycle - the snapshot was
      taken with the guest agent enabled, so the memory was included.

**Verification:** `../topics/11-snapshots-rollback/exercise.sh`

---

## Task 11 - Live migration

**Goal:** a running guest moves to another node without downtime.

### Requirements

- [ ] VM 9201 is running.
- [ ] The migration target is `pve2`.
- [ ] After the migration, VM 9201 runs on `pve2`.
- [ ] The migration was **online** - the guest was running during the move.
- [ ] The guest stayed reachable - the guest agent answers after the move.
- [ ] The uptime of the guest was not reset by the migration (it kept running,
      it was not restarted).

**Verification:** `../topics/12-live-migration/exercise.sh`

---

## Task 12 - Segmentation and firewall

**Goal:** the tiers are separated, and the separation is enforced.

### Requirements

- [ ] The datacenter firewall is enabled with `policy_in DROP`.
- [ ] The rule set is least privilege - no `ACCEPT` rule with no source, and
      no rule that accepts everything.
- [ ] Every web tier VM carries the VLAN tag `20` on its network device.
- [ ] Every application tier container carries the VLAN tag `30`.
- [ ] The database tier container carries the VLAN tag `40`.
- [ ] `bridge vlan show` on a node shows the tagged VLANs of the guests that
      run on it.
- [ ] The web tier VMs have their own firewall rules - the rule set is not
      only at the datacenter level.
- [ ] A rule exists that only allows the web tier to reach the database tier,
      and not the other way round.

**Verification:** `../topics/13-firewall-segmentation/exercise.sh`

---

## Task 13 - Backup and restore

**Goal:** the platform can be recovered.

### Requirements

- [ ] A backup job exists that targets `pbs-main`.
- [ ] The job covers at least VM 9201 and CT 301.
- [ ] The job runs in `snapshot` mode - it uses the guest agent.
- [ ] The job is enabled and has a schedule.
- [ ] The retention policy is `keep-daily 7`, `keep-weekly 4`,
      `keep-monthly 6`.
- [ ] A manual backup of VM 9201 exists in the datastore.
- [ ] A manual backup of CT 301 exists in the datastore.
- [ ] The restore works: VM 9201 is restored into a **new** VMID as a
      `linked` clone and boots successfully.
- [ ] The restored guest answers on the guest agent.

**Verification:** `../topics/14-backup-pbs/exercise.sh`

---

## Task 14 - High availability

**Goal:** a node failure does not take a service down.

### Requirements

- [ ] An HA group `prod-nodes` exists and contains all three nodes.
- [ ] VM 9201 is managed by HA (`ha-manager status` lists it).
- [ ] VM 9202 is managed by HA.
- [ ] CT 301 is managed by HA.
- [ ] The restart policy is set (`--max_restart` and `--max_relocate`).
- [ ] The managed guests are on shared storage - HA refuses to manage a guest
      whose disk is node local.
- [ ] `ha-manager status` shows the resources in the `started` state with a
      configured node.

**Verification:** `../topics/15-ha/exercise.sh`

---

## Task 15 - Monitoring and notifications

**Goal:** the operator knows when something is wrong.

### Requirements

- [ ] `pvesh get /cluster/status` returns the node and guest status.
- [ ] `pvesh get /cluster/metrics` returns current metrics.
- [ ] A notification endpoint exists (`pvesh get /cluster/notifications/endpoints`).
- [ ] A notification matcher exists that routes at least the backup and the HA
      events.
- [ ] The task log records the actions of the session -
      `pvesh get /cluster/log --limit 50`.
- [ ] The monitoring tier is present in the inventory: CT 302 `cache01` runs
      as the monitoring workload of the operations tier.

**Verification:** `../topics/16-monitoring/exercise.sh`

---

## Task 16 - Troubleshooting

**Goal:** a broken guest is diagnosed and fixed.

### Requirements

- [ ] The guest-or-host decision tree is applied: the diagnosis identifies the
      layer (guest / host service / storage) before a fix is chosen.
- [ ] A deliberately broken guest (stopped agent, missing interface or a
      detached disk) is diagnosed and repaired.
- [ ] The repair is verified - the guest works again.
- [ ] The incident is documented: the relevant entries are in the task log and
      in `journalctl`.
- [ ] A backup exists of the guest **before** the repair was attempted - the
      forensic evidence is preserved.

**Verification:** `../topics/17-troubleshooting/exercise.sh`

---

## Acceptance test

The final acceptance test runs every check of every task:

```bash
cd /opt/exercises/long-exercise/nordwind-platform
./exercise.sh
```

| Result | Meaning |
|---|---|
| `All checks passed` | The platform is complete |
| `N failed` | The named checks are the open items |

---

## Supplementary topics

These four topics are not part of the numbered task list, but each of them
is verified in the same way and the reference example is available:

| Topic | Directory | Requirement |
|---|---|---|
| 02 - The platform architecture | `../topics/02-platform-architecture/` | The services run, the API works, `/etc/pve` is replicated |
| 18 - Resource management | `../topics/18-resource-management/` | The CPU, the memory and the disk limits are set on the guests |
| 19 - Updates and maintenance | `../topics/19-updates-maintenance/` | The repository is right, the node is up to date, the HA-aware reboot works |
| 20 - The API and automation | `../topics/20-web-ui-automation/` | The API token exists and is limited to its ACL |

