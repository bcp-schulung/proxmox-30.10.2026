# Requirements - Topic 14: Backup and Restore with PBS

**Topic ID:** `14-backup-pbs`

---

## The storage

- [ ] The storage `pbs-main` exists and is active.
- [ ] It points at the backup server and the datastore `main`.
- [ ] It declares the content type `backup`.

## The backup job

- [ ] A backup job exists that targets `pbs-main`.
- [ ] The job covers VM 100.
- [ ] The job covers CT 301.
- [ ] The job runs in `snapshot` mode.
- [ ] The job is enabled.
- [ ] The job has a schedule.
- [ ] The retention keeps 7 daily backups.
- [ ] The retention keeps 4 weekly backups.
- [ ] The retention keeps 6 monthly backups.

## The backups

- [ ] A backup of VM 100 exists in the datastore.
- [ ] A backup of CT 301 exists in the datastore.

## The restore

- [ ] A restored VM exists with a VMID of at least 190.
- [ ] The restored VM is on the shared storage.
- [ ] The restored VM is running.
- [ ] The guest agent answers in the restored VM.

---

## Notes

**The restore checks are the ones that matter.** Everything up to the
restore is bookkeeping. The restore is the part that proves the backup is
usable. A backup job that runs every night and has never been restored is a
scheduled hope, not a backup.

**"A VMID of at least 190"** is the check for "the restore went into a new
guest". A restore into VM 100 itself would overwrite the original - and
then the verification could not tell a successful restore from a no-op.
