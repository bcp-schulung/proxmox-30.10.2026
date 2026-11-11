# Requirements - Topic 11: Snapshots and Rollback

**Topic ID:** `11-snapshots-rollback`

---

## The snapshot

- [ ] VM 100 has a snapshot named `pre-update`.
- [ ] The snapshot carries a description.
- [ ] The snapshot is listed by `qm listsnapshot 100`.

## The rollback

- [ ] A marker file that was created after the snapshot
      (`/etc/nordwind-exercise-marker`) does **not** exist in the guest.
- [ ] The guest is running after the rollback.
- [ ] The guest agent answers after the rollback.

## The cleanup

- [ ] The snapshot `pre-update` is deleted.
- [ ] `qm listsnapshot 100` no longer lists `pre-update`.

---

## Notes

**The marker file check is the real test.** The verification creates a marker
file inside the guest, takes the snapshot, then checks that the marker is
gone. The exercise script does this itself, so the student does not have to
remember the exact file name.

**"The guest is running after the rollback"** proves that the memory state
was restored as well. A disk-only rollback (`--mode snapshot`) would leave
the guest stopped.

**The snapshot has to be deleted at the end.** A snapshot keeps the changed
blocks of the disk alive. On a busy guest that is real space that does not
come back until the snapshot is gone.
