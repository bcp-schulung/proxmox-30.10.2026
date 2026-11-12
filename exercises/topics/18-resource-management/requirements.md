# Requirements - Topic 18: Resource Management

**Topic ID:** `18-resource-management`

---

## The CPU

- [ ] VM 9201 has 2 sockets and 2 cores.
- [ ] VM 9201 has a CPU limit that is not unlimited (the limit is not `0`).
- [ ] VM 9201 has a CPU weight that is set.
- [ ] VM 9201 has a CPU type that is portable between the nodes.

## The memory

- [ ] VM 9201 has a memory limit that is set.
- [ ] VM 9201 has a balloon value that is set and is lower than the memory
      limit.
- [ ] The database container CT 301 has **no** balloon - the balloon is
      either absent or `0`.

## The disk

- [ ] VM 9201 has a disk that is larger than the original 32 GB - it was
      grown.
- [ ] VM 9201 has at least one disk attached.
- [ ] The disk configuration contains the discard and the iothread options.

## The container limits

- [ ] CT 300 has a CPU limit.
- [ ] CT 300 has a memory limit.

---

## Notes

**The balloon check on CT 301 is the interesting one.** The database tier
is the workload where the balloon does the most damage - the working set
is large and the reclaim pauses hurt. Turning it off for that tier and
leaving it on for the web tier is a deliberate design decision, and the
verification checks both sides of it.

**The disk growth check** verifies the *configuration*. Growing the disk
inside the guest - the partition and the filesystem - is a separate step
that happens in the guest, and the check for that is not part of this
exercise. It is worth pointing out to the students that `qm resize` alone
does not make the extra space usable.
