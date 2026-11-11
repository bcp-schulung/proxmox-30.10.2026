# Topic 14 - Backup and Restore with PBS

**Topic ID:** `14-backup-pbs`
**Course reference:** Proxmox VE Introduction, Day 3 §3 and §4
**Duration:** 60 minutes
**Runs on:** one node

---

## 1. What you learn

Proxmox Backup Server is a dedicated backup application. Compared to a plain
`vzdump` directory it gives you:

- **incremental backups** - only the changed blocks are sent
- **deduplication** - the same block in ten backups is stored once
- **client-side encryption** - the chunks are encrypted before they leave
  the node
- **verification** - silent bit rot is detected
- **pruning** - the retention policy is applied server side

## 2. The backup sequence

```
   Proxmox VE Cluster
        │
        │  vzdump
        ▼
   VM / CT disks ──► fsfreeze (via the guest agent) ──► fsthaw
        │
        │  proxmox-backup-client
        ▼
   Proxmox Backup Server
        │
        ├── Chunk store - dedup + compression
        ├── Datastore index
        ├── Garbage collection
        └── Verification jobs
```

The `fsfreeze` is the part that matters for consistency. With the guest
agent enabled, the filesystem is frozen before the snapshot and thawed
afterwards - the guest keeps running, and the backup is consistent.

## 3. The storage

PBS is registered as a Proxmox storage with the content type `backup`:

```bash
pvesm add pbs pbs-main --server 10.20.2.21 --datastore main \
  --username backup@pbs --password '...' --fingerprint '...' \
  --content backup
```

## 4. The two kinds of backup mode

| Mode | What it does | When |
|---|---|---|
| `snapshot` | Freezes the filesystem, takes the snapshot, thaws | The default, the guest is running |
| `suspend` | Suspends the guest, backs up, resumes | A guest that ignores the freeze |
| `stop` | Stops the guest, backs up, starts it | A guest that must not run during the backup |
| `none` | No consistency measure at all | Only for a guest that is already stopped |

`snapshot` is the default and it is the right one for almost everything.

## 5. The backup job

```bash
pvesh create /cluster/backup \
  --storage pbs-main \
  --vmid 100,301 \
  --schedule daily \
  --mode snapshot \
  --enabled 1 \
  --compress zstd \
  --retention-keep-daily 7 \
  --retention-keep-weekly 4 \
  --retention-keep-monthly 6
```

The retention is a **keep** list, not a delete list:

| Rule | Meaning |
|---|---|
| `keep-daily 7` | Keep the last 7 daily backups |
| `keep-weekly 4` | Keep the last 4 weekly backups |
| `keep-monthly 6` | Keep the last 6 monthly backups |

The result is a history that is dense for the recent past and sparse for the
long term - which is exactly what you want.

## 6. The restore - the part everybody forgets

> **A backup that was never restored is not a backup.**

```bash
# List the backups
pvesm list pbs-main --content backup

# Restore into a NEW VMID
qmrestore pbs-main:backup/vm/100/2026-11-10T02:00:00Z 190 --storage nfs-lab

# Configure and start it
qm set 190 --net0 virtio,bridge=vmbr0,tag=20
qm start 190
qm guest cmd 190 ping
```

**Restore into a new VMID.** A restore to the same VMID overwrites the
original - and in a real recovery the original is the damaged one, kept
deliberately for the forensic analysis.

## 7. What you do

1. Create the backup job with the retention policy.
2. Run a manual backup of VM 100 and of CT 301.
3. Verify that the backups exist in the datastore.
4. Restore VM 100 into a new VMID.
5. Start the restored guest and verify the agent answers.

## 8. How it is checked

```bash
./exercise.sh
```

## 9. The reference

`solution.md`.
