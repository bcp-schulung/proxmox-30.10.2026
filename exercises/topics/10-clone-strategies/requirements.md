# Requirements - Topic 10: Clone Strategies

**Topic ID:** `10-clone-strategies`

---

## The guest on the node

- [ ] VM 9203 exists.
- [ ] It is named `debian13-run-pve3`.
- [ ] Its `scsi0` is a disk of its own (`vm-9203-disk-N`) - it is a **full**
      clone, not a linked one.
- [ ] It is on the local LVM-thin storage `local-lvm`.
- [ ] It has its own cloud-init drive.
- [ ] It has its own IP configuration.
- [ ] It is running.
- [ ] The guest reports the hostname `debian13-run-pve3`.

## The base template

- [ ] The template 9101 still exists.
- [ ] The template 9101 is still marked as a template.
- [ ] The base disk `base-9101-disk-0` still exists.

## The other guests, for comparison

- [ ] VM 9201 exists and is a **full** clone - its disk is `vm-9201-disk-N`,
      not `base-9101-disk-N`.
- [ ] VM 9202 exists and is a **full** clone as well.

---

## Notes

**Why every guest is a full clone.** The two kinds of clone have
contradictory requirements:

- A full clone can be moved to another node only when the source is on
  shared storage. A template on the local storage of a node is refused with
  `can't clone VM to node 'pve2' (VM uses local storage)`.
- A linked clone is a snapshot of the template's disk, and a snapshot is only
  possible on a storage that supports them. NFS does not:
  `Linked clone feature is not supported for 'nfs-lab:9000/...'`.

A template on the node's **own** local LVM-thin storage satisfies both
constraints, so that is where the templates live. The guests are then
cloned onto the node whose template they came from.

**The "the template still exists" check** makes the dependency explicit.
The template is the source of the guest, and it is what a student clones
from when they want a fresh one.

**The hostname check** is the proof that the clone got its own cloud-init
drive. A guest that inherited the drive of its template boots with the
hostname of the template, and every student hits this at least once.
