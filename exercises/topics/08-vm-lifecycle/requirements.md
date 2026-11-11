# Requirements - Topic 08: The VM Lifecycle

**Topic ID:** `08-vm-lifecycle`

---

## The VM 100

- [ ] VM 100 exists.
- [ ] It is named `web01`.
- [ ] It is a **full** clone of the template 9000 (its disk is
      `vm-100-disk-0`, not `base-9000-disk-0`).
- [ ] It is on the shared storage `nfs-lab`.
- [ ] It has 2 vCPU.
- [ ] It has 4096 MB of memory.
- [ ] It uses the `virtio` network device on `vmbr0`.
- [ ] It carries the VLAN tag `20`.
- [ ] It uses `virtio-scsi-single` as the disk controller.
- [ ] The disk has `discard=on` and `iothread=1`.
- [ ] The guest agent is enabled.
- [ ] It has its own cloud-init drive.
- [ ] The cloud-init drive names the guest `web01`.
- [ ] It is running.

## The guest agent

- [ ] `qm guest cmd 100 ping` answers.
- [ ] The guest agent is active inside the guest.
- [ ] The guest reports a hostname of `web01`.
- [ ] The guest has an address on the overlay network.

## The lifecycle

- [ ] The guest can be shut down cleanly (`qm shutdown`).
- [ ] The guest can be started again after the shutdown.
- [ ] The guest agent answers after the restart.

---

## Notes

**The cloud-init hostname check is the one that catches the clone trap.** A
clone inherits the template's cloud-init drive. If the student cloned the
template and forgot to replace the drive, the guest boots as
`debian13-template` - and everything else works fine, which is why the bug
survives a casual test.

**The "can be shut down cleanly" check** proves the guest agent works. A
guest without the agent has to be stopped with `qm stop`, which is the data
loss version of the same operation.

**The VLAN tag check** is the segmentation foundation. Everything in the
firewall topic builds on it.
