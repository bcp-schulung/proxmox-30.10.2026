# Topic 04 - Storage Backends

**Topic ID:** `04-storage-backends`
**Course reference:** Proxmox VE Introduction, Day 1 §8 and Day 3 §2
**Duration:** 60 minutes
**Runs on:** one node (the definitions are cluster wide)

---

## 1. What you learn

Choosing a storage backend is one of the most consequential early decisions
in a Proxmox deployment. It decides whether you get live migration, snapshots
and HA "for free" - or whether you have to build them yourself.

## 2. The decision

```
                    Single node, simple
                          |
                  Directory Storage
                          |
        +-----------------+-----------------+
        |                                   |
   Fast local disks                  Resilient single node
   (LVM / LVM-thin)                  (ZFS with RAIDZ)
        |
   +----+----+
   |         |
Multi-node            Existing SAN / NAS
HA / live-migration    (iSCSI + LVM, NFS, CIFS)
        |
   Ceph RBD / CephFS
   (distributed, self-healing)
```

The rule of thumb from the course:

> Single node with no HA needs -> local ZFS.
> Multi-node cluster wanting HA / live migration without dedicated storage
> hardware -> Ceph.
> Existing SAN / NAS -> NFS or iSCSI + LVM.

## 3. The three backends in this lab

| ID | Type | Scope | Content | Used for |
|---|---|---|---|---|
| `local-lvm` | LVM-thin | **node local** | images, rootdir | fast disks, disposable workloads |
| `nfs-lab` | NFS 4.1 | **shared** | images, rootdir, iso, vztmpl, backup, snippets | everything that must survive a node failure |
| `pbs-main` | PBS | shared | backup | the backup target |

### The one rule that matters

> **Live migration and HA only work on shared storage.**

That is not a Proxmox limitation - it is physics. To migrate a running guest
to another node, the target node has to be able to see the disk. To restart
a guest on another node after a failure, the same is true.

```bash
qm migrate 9201 pve2 --online
# migrate VMs with local disks are not supported
```

A student who hits this once never forgets it.

## 4. Shared and node local

```bash
pvesm status
```

The `Status` column tells you whether a storage is usable right now. The
scope is a property of the definition:

- a `lvmthin`, `dir` or `zfspool` storage is **node local** - each node
  resolves it against its own device
- an `nfs`, `iscsi`, `cifs` or `rbd` storage is **shared**

A cluster-wide definition of a node-local storage is not a contradiction. It
is exactly what the PVE installer produces when nodes are clustered
afterwards: `local-lvm` is defined once in `/etc/pve/storage.cfg`, and each
node resolves the name `pve/data` against its own volume group.

## 5. The content types

Every storage declares what it may hold:

| Content | Meaning |
|---|---|
| `images` | VM disks |
| `rootdir` | container root filesystems |
| `iso` | ISO images |
| `vztmpl` | container templates |
| `backup` | vzdump backups |
| `snippets` | cloud-init and hook scripts |
| `import` | disks that are not attached to a guest |

A storage that does not declare `iso` cannot hold an ISO, and the web UI
hides the upload button for it. This is a small thing that surprises people
regularly.

## 6. What you do

1. Create the `local-lvm` storage (LVM-thin on the node's data volume).
2. Create the `nfs-lab` storage (NFS 4.1 from the NFS server).
3. Create the `pbs-main` storage (Proxmox Backup Server).
4. Prove that `nfs-lab` is genuinely shared - write a file and read it on
   another node.
5. Check the content types and the free space.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
