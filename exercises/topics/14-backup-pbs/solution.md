# Solution - Topic 14: Backup and Restore with PBS

**Topic ID:** `14-backup-pbs`

> **Instructor material.**

---

## 1. The storage

```bash
pvesm status --storage pbs-main
```

If it does not exist yet:

```bash
# The fingerprint comes from the backup server
proxmox-backup-manager fingerprint         # on pbs1

pvesm add pbs pbs-main \
  --server 10.20.2.21 \
  --datastore main \
  --username backup@pbs \
  --password "${PBS_PASSWORD}" \
  --fingerprint "${PBS_FINGERPRINT}" \
  --content backup
```

## 2. The backup job

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
  --retention-keep-monthly 6 \
  --notes "Nordwind production backup"
```

Verify:

```bash
pvesh get /cluster/backup
```

```json
[
  {
    "id": "backup-abcdef",
    "storage": "pbs-main",
    "vmid": "100,301",
    "schedule": "daily",
    "mode": "snapshot",
    "enabled": 1,
    "compress": "zstd",
    "retention-keep-daily": 7,
    "retention-keep-weekly": 4,
    "retention-keep-monthly": 6
  }
]
```

### The schedule syntax

| Schedule | Meaning |
|---|---|
| `daily` | Once a day |
| `hourly` | Once an hour |
| `weekly` | Once a week, on Sunday at 02:00 |
| `monthly` | Once a month, on the first at 02:00 |
| `mon..fri` | Monday to Friday |
| `1,15` | The 1st and the 15th of every month |
| `sat,sun` | The weekend |

### The retention is a keep list

```
keep-daily 7      keep-weekly 4      keep-monthly 6      keep-yearly 2
```

The result over time:

```
Day 1   Day 2   ...  Day 7   Day 8
  B1      B2         B7      B8     <- the daily backups
                W1              W2   <- the weekly backups
                          M1        <- the monthly backups
```

The recent history is dense, the long-term history is sparse. That is the
shape most restore requirements actually have - "something from yesterday" is
common, "something from 14 months ago" is rare.

## 3. The manual backup

```bash
vzdump 100 --storage pbs-main --mode snapshot
vzdump 301 --storage pbs-main --mode snapshot
```

Expected:

```
INFO:  100: guest has CT lock, cleanup will try to remove it
INFO:  100: started task with UPID pvesm:100:root@pam:6a3b1c2d:...
INFO:  100: (fuse) backup: vm-100-disk-0.qcow2: 8.00 GiB (22.4% of 32.00 GiB)
INFO:  100: backup is sparse: 8.00 GiB (22.4% of 32.00 GiB)
INFO:  100: transferred 8.00 GiB from 0 to 0
INFO:  100: (fuse) volume 'vm-100-disk-0' is sparse: 8.00 GiB (22.4% of 32.00 GiB)
INFO:  100: end task
```

The `sparse` line is the deduplication at work - only the used blocks are
sent.

Verify:

```bash
pvesm list pbs-main --content backup
```

```
volid                                              content  format  volname
pbs-main:backup/vm/100/2026-11-10T02:00:00Z       backup   pbs     ...
pbs-main:backup/lxc/301/2026-11-10T02:05:00Z      backup   pbs     ...
```

## 4. The restore

```bash
# The available backups
pvesm list pbs-main --content backup

# Restore into a NEW VMID
qmrestore pbs-main:backup/vm/100/2026-11-10T02:00:00Z 190 --storage nfs-lab
```

Expected:

```
INFO: restore VM 100 from backup 2026-11-10T02:00:00Z
INFO: 100: guest has CT lock, cleanup will try to remove it
INFO: start VM 100 on node 'pve1'
INFO: 100: start failed: unknown error - maybe because of wrong --storage
```

No - that last line only happens when the storage is wrong. The normal
output:

```
INFO: restore VM 100 from backup 2026-11-10T02:00:00Z
INFO: 100: guest has CT lock, cleanup will try to remove it
INFO: 1 images with type 'qcow2' in the backup
INFO: 1 images with type 'raw' in the backup
INFO: start VM 100 on node 'pve1'
```

### The restore is a linked clone by default

```bash
qmrestore pbs-main:backup/vm/100/2026-11-10T02:00:00Z 190 --storage nfs-lab
```

The new VM 190 shares the base disk with the backup in the datastore. That
is fast and space efficient - and it means the backup **cannot be pruned**
while the restored guest exists.

For a full, independent copy:

```bash
qmrestore pbs-main:backup/vm/100/2026-11-10T02:00:00Z 190 --storage nfs-lab --full
```

### Configure and start it

```bash
qm set 190 \
  --cores 2 --memory 4096 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1"

qm start 190

for i in $(seq 1 30); do
    qm guest cmd 190 ping >/dev/null 2>&1 && break
    sleep 5
done

qm guest cmd 190 ping
qm guest exec 190 -- hostname
```

The restored guest keeps the configuration of the backup, so the hostname
is `web01` - it is the same guest, restored.

## 5. The container restore

```bash
pctrestore pbs-main:backup/lxc/301/2026-11-10T02:05:00Z 391 --storage nfs-lab
pct start 391
pct exec 391 -- hostname
```

## 6. The verification on the PBS side

```bash
# On the backup server
proxmox-backup-manager datastore list
proxmox-backup-manager snapshot list --datastore main
```

```
--- snapshot list ---
vmid    type  time
100     qemu  2026-11-10T02:00:00Z
301     lxc   2026-11-10T02:05:00Z
```

### The verification job

```bash
proxmox-backup-manager verify-job create daily-verify --schedule daily
```

PBS verifies the stored chunks against their checksums. That is how silent
bit rot - a disk that changes a byte without anyone noticing - is caught.

## 7. The encryption

```bash
proxmox-backup-client key create /etc/pve/priv/storage/pbs-main.enc
proxmox-backup-client key paperkey /etc/pve/priv/storage/pbs-main.enc
```

The chunks are encrypted **before** they leave the node. A fully compromised
backup server still cannot read them.

> **The paper key is the only way back in.** Collect it from the students
> and store it physically, offline. Losing it means losing every encrypted
> backup, permanently.

## 8. The complete sequence

```bash
# The job
pvesh create /cluster/backup \
  --storage pbs-main --vmid 100,301 \
  --schedule daily --mode snapshot --enabled 1 --compress zstd \
  --retention-keep-daily 7 --retention-keep-weekly 4 --retention-keep-monthly 6

# The manual backups
vzdump 100 --storage pbs-main --mode snapshot
vzdump 301 --storage pbs-main --mode snapshot

pvesm list pbs-main --content backup

# The restore
BACKUP=$(pvesm list pbs-main --content backup | grep 'vm/100' | head -1 | awk '{print $1}')
qmrestore "${BACKUP}" 190 --storage nfs-lab
qm set 190 --cores 2 --memory 4096 --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1"
qm start 190
qm guest cmd 190 ping
```

## 9. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `qmrestore` fails with "already exists" | The target VMID is taken | Restore into a new VMID |
| The backup fails with "no such snapshot" | The guest is not running and the mode is `snapshot` | Use `--mode stop` |
| The backup is very slow | The guest writes a lot | Expected - the dirty rate is high |
| The restore is very slow | The network between the nodes and the PBS | The lab's nodes are in one availability zone |
| `unable to parse the fingerprint` | The fingerprint was copied with a line break | Copy it without the newline |
| The job runs but nothing appears | The guest is excluded by the `vmid` filter | Check the job's `vmid` list |
| The datastore is full | The retention does not cover it | Add a `prune` job or lower the retention |
| The restored guest has no network | The restore does not carry the `net0` of the original | Set it after the restore |
