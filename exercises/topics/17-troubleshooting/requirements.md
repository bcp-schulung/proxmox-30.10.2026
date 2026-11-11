# Requirements - Topic 17: Troubleshooting

**Topic ID:** `17-troubleshooting`

---

## The forensic snapshot

- [ ] VM 100 has a snapshot named `incident` - the evidence was preserved
      **before** the repair.
- [ ] The snapshot carries a description.

## The diagnosis

- [ ] The guest was identified as the faulty layer - not the host. The
      guest agent answering (`qm guest cmd 100 ping`) while the service
      inside the guest is broken proves it.

## The repair

- [ ] VM 100 is running.
- [ ] The guest agent answers again.
- [ ] The guest is functional - the guest agent service is active.

## The documentation

- [ ] The task log records the actions of the incident on VM 100.
- [ ] The snapshot `incident` still exists - the evidence was not deleted
      during the repair.

---

## Notes

**The snapshot check is the forensic discipline.** A student who repairs the
guest first and snapshots afterwards has already destroyed the evidence. The
snapshot has to be taken *before* the repair, and it has to survive it.

**The "the guest was the faulty layer" check** is verified by the guest
agent. If the agent answers, the QEMU process is alive, the virtio-serial
channel works and the hypervisor is healthy. Whatever is broken is inside
the guest. That is a proof, not a guess.

**The incident documentation** is the last step of the IR cycle, and it is
the one that is always skipped. The task log is written by Proxmox itself -
the student only has to make sure the repair happened as a logged action.
