# Requirements - Topic 10: Clone Strategies

**Topic ID:** `10-clone-strategies`

---

## The linked clone

- [ ] VM 102 exists.
- [ ] It is named `web-test`.
- [ ] Its `scsi0` refers to `base-9000-disk-0` - it is a **linked** clone.
- [ ] It is on the shared storage `nfs-lab`.
- [ ] It has its own cloud-init drive.
- [ ] It has its own IP configuration.
- [ ] It is running.
- [ ] The guest reports the hostname `web-test`.

## The base template

- [ ] The template 9000 still exists.
- [ ] The template 9000 is still marked as a template.
- [ ] The base disk `base-9000-disk-0` still exists.

## The full clone, for comparison

- [ ] VM 100 exists and is a **full** clone - its disk is `vm-100-disk-0`,
      not `base-9000-disk-0`.

---

## Notes

**The "the template still exists" check is the safety net.** A linked clone
without its base is a broken guest that cannot even be started. Proxmox
refuses to delete the base in this case, but the check makes the dependency
explicit.

**The hostname check** is the proof that the clone got its own cloud-init
drive. A linked clone that inherited the drive boots as `debian13-template`,
and every student hits this at least once.
