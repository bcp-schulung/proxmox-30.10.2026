# Requirements - Topic 07: The Golden Image and Templates

**Topic ID:** `07-template-cloning`

---

## The VM 9000

- [ ] VM 9000 exists.
- [ ] It is named `debian13-template`.
- [ ] It lives on the shared storage `nfs-lab`.
- [ ] It uses the `q35` machine type.
- [ ] It uses `virtio-scsi-single` as the disk controller.
- [ ] It uses `virtio` as the network device.
- [ ] It is connected to the bridge `vmbr0`.
- [ ] The guest agent is enabled (`enabled=1`).
- [ ] `fstrim_cloned_disks=1` is set on the guest agent.
- [ ] It has an EFI disk with `pre-enrolled-keys=1`.
- [ ] It has a cloud-init drive attached.
- [ ] The boot order starts with the disk (`order=scsi0`).
- [ ] The disk has `discard=on` and `iothread=1`.

## The template state

- [ ] VM 9000 is marked as a template.
- [ ] VM 9000 cannot be started (a template is read-only).
- [ ] `qm config 9000` shows the `template:` line.

## The disk

- [ ] The imported disk is attached as `scsi0`.
- [ ] The disk refers to the shared storage.
- [ ] The base image is no longer sitting loose in the storage (it was
      imported, not attached).

---

## Notes

**The EFI disk with `pre-enrolled-keys=1` matters for the clones.** Without
it, a clone of a UEFI guest fails to boot, because the guest is in secure
boot mode and finds no enrolled keys. The requirement is a symptom of the
template being correct - a template without it produces broken clones, and
the broken clone is a lot harder to diagnose than the missing option.

**The "cannot be started" check is deliberate.** A template that starts is
not a template. `qm template` makes the VM read-only, and `qm start` on it
fails with `can't start VM: VM is a template`. If a student "fixed" a
template that would not boot by converting it back with `qm template 9000`
again, the check catches it.
