# Requirements - Topic 04: Storage Backends

**Topic ID:** `04-storage-backends`

---

## The definitions

- [ ] `pvesm status` lists `local-lvm`.
- [ ] `pvesm status` lists `nfs-lab`.
- [ ] `pvesm status` lists `pbs-main`.
- [ ] All three storages are `active`.

## The scope

- [ ] `local-lvm` is defined as `lvmthin` with the volume group `pve` and
      the thin pool `data`.
- [ ] `nfs-lab` is defined as `nfs`, pointing at the NFS server
      (`10.20.2.20`) and the export `/export/lab`.
- [ ] `pbs-main` is defined as `pbs`, pointing at the backup server
      (`10.20.2.21`) and the datastore `main`.
- [ ] `nfs-lab` is shared - it is active on all three nodes.
- [ ] `pbs-main` is shared - it is active on all three nodes.

## The content types

- [ ] `nfs-lab` declares `images`.
- [ ] `nfs-lab` declares `rootdir`.
- [ ] `nfs-lab` declares `iso`.
- [ ] `nfs-lab` declares `vztmpl`.
- [ ] `nfs-lab` declares `backup`.
- [ ] `nfs-lab` declares `snippets`.
- [ ] `pbs-main` declares `backup`.
- [ ] `pbs-main` does **not** declare `images` - a backup target holds no
      disks.

## The proof that the NFS storage is shared

- [ ] A file written into `/mnt/pve/nfs-lab` on one node is visible on the
      other two nodes.
- [ ] The test file is removed again afterwards.

## The capacity

- [ ] `local-lvm` reports free space on every node.
- [ ] The NFS export reports free space.

---

## Notes

**The "shared" proof is the important one.** `pvesm status` showing the
storage on three nodes is not the same as the storage being shared - a
misconfigured NFS mount can appear on every node and still be a local
directory on each of them. The file test is the real proof.

**The content types are a security control, not a convenience.** A storage
that can hold `snippets` can hold a script that Proxmox executes. A storage
that can hold `backup` can hold a full copy of a guest - which is a much
bigger prize for an attacker than a disk image. Keep the content types as
narrow as the workload allows.
