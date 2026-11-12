# Requirements - Topic 08: The VM Lifecycle

**Topic ID:** `08-vm-lifecycle`

> **The guests of this lab are bare clones.** The Debian cloud image ships no
> configuration of its own - no network configuration, no root password, no
> cloud-init drive - so the guest boots to a `localhost` login prompt and
> the guest agent never comes up.
>
> That is deliberate, and it is what makes this topic work: the difference
> between `qm stop` and `qm shutdown` is only visible on a guest that has the
> agent. A bare guest has to be stopped with `qm stop`, which is the data
> loss version of the same operation.

---

## The VM 9201

- [ ] VM 9201 exists.
- [ ] It is named `debian13-run-pve1`.
- [ ] It is a **full** clone of the template 9101 (its disk is
      `vm-9201-disk-1`, not `base-9101-disk-1`).
- [ ] It is on the node-local storage `local-lvm`.
- [ ] It has 2 vCPU.
- [ ] It has memory allocated.
- [ ] It uses the `virtio` network device on `vmbr0`.
- [ ] It uses `virtio-scsi-single` as the disk controller.
- [ ] The disk has `discard=on` and `iothread=1`.
- [ ] The guest agent is enabled in the configuration (`enabled=1`).
- [ ] It is **not** a template.

## The state

- [ ] VM 9201 is running.

## The lifecycle

- [ ] The guest can be stopped (`qm stop`).
- [ ] The guest is stopped afterwards.
- [ ] The guest can be started again.
- [ ] The guest is running again, and the exercise leaves it as it found it.

---

## The student's task

The checks below need a guest that has been configured. They are the work of
this topic, not the starting state:

- [ ] The guest has its own cloud-init drive (`--ide2 local:cloudinit`).
- [ ] The cloud-init drive names the guest `debian13-run-pve1`.
- [ ] `qm guest cmd 9201 ping` answers.
- [ ] The guest agent is active inside the guest.
- [ ] The guest reports the hostname `debian13-run-pve1`.
- [ ] The guest has an address on the overlay network.

Once the cloud-init drive is attached and the guest is rebuilt, the agent
comes up and `qm shutdown` works - which is the difference between a
graceful stop and a hard one.

---

## Notes

**The cloud-init hostname check is the one that catches the clone trap.** A
clone inherits the template's cloud-init drive. If the student cloned the
template and forgot to replace the drive, the guest boots as
`debian13-tpl-pve1` - and everything else works fine, which is why the bug
survives a casual test.

**The "can be shut down cleanly" check** proves the guest agent works. A
guest without the agent has to be stopped with `qm stop`, which is the data
loss version of the same operation.

**The VLAN tag check** is the segmentation foundation. Everything in the
firewall topic builds on it. The guests of this lab carry no tag yet - the
student adds it with `qm set 9201 --net0 virtio,bridge=vmbr0,tag=20`.
