# Solution - Topic 04: Storage Backends

**Topic ID:** `04-storage-backends`

> **Instructor material.**

---

## 1. The LVM-thin pool

**On each node.** The pool is node local; only the definition is cluster wide.

```bash
# Check whether the pool exists
pvs
vgs
lvs

# Create it if it does not
pvcreate /dev/nvme1n1
vgcreate pve /dev/nvme1n1
lvcreate -l 95%FREE -T pve/data
```

> The thin pool leaves 5% headroom so that the metadata can grow later. A
> percentage has to go to `-l` (lowercase); `-L` expects an absolute size.

Then, **once on any node**:

```bash
pvesm add lvmthin local-lvm --vgname pve --thinpool data \
  --content images,rootdir
```

### Why one definition for three pools

`pvesm add` writes into `/etc/pve/storage.cfg`, which is replicated to all
nodes. Every node then resolves the name `pve/data` against **its own**
volume group. The result:

```
$ pvesm status
Name        Type     Status           Total            Used       Available        %
local-lvm   lvm-thin active         251.00 GiB    12.00 GiB     239.00 GiB   4.78%
```

Note that the `Total` differs per node - each node reports its own pool.
That is correct behaviour, not a bug.

## 2. The shared NFS storage

**Once on any node:**

```bash
pvesm add nfs nfs-lab \
  --server 10.20.2.20 \
  --export /export/lab \
  --content images,rootdir,iso,vztmpl,backup,snippets \
  --options "vers=4.1,hard,proto=tcp"
```

| Option | Why |
|---|---|
| `vers=4.1` | NFS 4.1 supports the stateful protocol that Proxmox expects, and it plays better with a firewall |
| `hard` | A hard mount retries on a server failure instead of returning an I/O error to the guest |
| `proto=tcp` | UDP has no congestion control; TCP does |

### The `no_root_squash` question

The NFS export uses `no_root_squash`, because the unprivileged LXC containers
map their root to a high UID range on the host. With the default
`root_squash`, the container's root would be mapped to `nobody` on the NFS
server and the container would not be able to write to its own rootfs.

## 3. The backup target

The instructor provides the credentials:

```bash
export PBS_SERVER="10.20.2.21"
export PBS_PASSWORD="<from the instructor>"
export PBS_FINGERPRINT="<from the instructor>"

# Read the fingerprint from the backup server itself
proxmox-backup-manager fingerprint        # on pbs1

pvesm add pbs pbs-main \
  --server "${PBS_SERVER}" \
  --datastore main \
  --username backup@pbs \
  --password "${PBS_PASSWORD}" \
  --fingerprint "${PBS_FINGERPRINT}" \
  --content backup
```

### Why the fingerprint

The fingerprint is the SHA-256 of the backup server's TLS certificate. It
protects the very first contact against a man in the middle: if the
certificate on the wire does not match the fingerprint, the cluster refuses
to store the password on it.

## 4. Prove that the NFS storage is shared

**On `pve1`:**

```bash
echo "shared" > /mnt/pve/nfs-lab/.shared-test
```

**On `pve2`:**

```bash
cat /mnt/pve/nfs-lab/.shared-test
# shared
```

**On `pve3`:**

```bash
cat /mnt/pve/nfs-lab/.shared-test
# shared
```

Clean up on any node:

```bash
rm /mnt/pve/nfs-lab/.shared-test
```

### What a failed proof looks like

If the file does not appear on the other nodes, one of three things is wrong:

1. The export is not shared - each node mounted its own local directory.
   Check `/etc/fstab` and the mount options.
2. The NFS server is not reachable from that node. Check the route and the
   security group (TCP 2049).
3. The NFS client is not installed on that node:
   ```bash
   dpkg -l nfs-common
   mount | grep nfs-lab
   ```

## 5. The check

```bash
pvesm status
pvesm list nfs-lab
pvesm list pbs-main --content backup
df -h /mnt/pve/nfs-lab
```

### `pvesm status` per node

```bash
# On every node
pvesm status --storage nfs-lab
```

```
Name      Type  Status           Total            Used       Available        %
nfs-lab   nfs   active        1000.00 GiB     0.00 GiB    1000.00 GiB   0.00%
```

## 6. The content types

```bash
grep -A 10 "^storage nfs-lab" /etc/pve/storage.cfg
```

```
storage nfs-lab
    type nfs
    server 10.20.2.20
    export /export/lab
    path /mnt/pve/nfs-lab
    content images,rootdir,iso,vztmpl,backup,snippets
    options vers=4.1,hard,proto=tcp
    prune-backups keep-all=1
```

The `content` line is what the web UI uses to decide which buttons to show.
A storage without `iso` has no "Upload ISO" button.

### The backup target is deliberately narrow

```bash
grep -A 8 "^storage pbs-main" /etc/pve/storage.cfg
```

```
storage pbs-main
    type pbs
    server 10.20.2.21
    datastore main
    username backup@pbs
    content backup
    fingerprint ...
```

Only `backup`. The backup server is not a place where disks live.

## 7. The complete sequence

```bash
# --- On each node ---
pvcreate /dev/nvme1n1
vgcreate pve /dev/nvme1n1
lvcreate -l 95%FREE -T pve/data

# --- Once, on any node ---
pvesm add lvmthin local-lvm --vgname pve --thinpool data --content images,rootdir
pvesm add nfs nfs-lab --server 10.20.2.20 --export /export/lab \
  --content images,rootdir,iso,vztmpl,backup,snippets --options "vers=4.1,hard,proto=tcp"
pvesm add pbs pbs-main --server 10.20.2.21 --datastore main \
  --username backup@pbs --password "${PBS_PASSWORD}" \
  --fingerprint "${PBS_FINGERPRINT}" --content backup

# --- Prove the sharing ---
echo shared > /mnt/pve/nfs-lab/.shared-test
cat /mnt/pve/nfs-lab/.shared-test      # on pve2 and pve3
rm /mnt/pve/nfs-lab/.shared-test
```

## 8. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `pvesm add` fails with "storage ID already exists" | The storage is defined | Check `pvesm status` first; use `pvesm set` to change it |
| The NFS storage is `inactive` | The server is unreachable | `showmount -e 10.20.2.20`, check the route |
| The storage works on pve1 but not on pve2 | The route or the security group | `ping 10.20.2.20` from pve2 |
| `qm migrate` refuses: "local disks are not supported" | The disk is on `local-lvm` | Move it: `qm move_disk` |
| The container cannot write to its rootfs | `root_squash` on the export | Export with `no_root_squash` |
| The backup job fails with an authentication error | The password was rotated | `pvesm set pbs-main --password <new>` |

## 9. The capacity question

How much space do you actually need? The calculation from the migration
course:

```
usable = raw × (1 - overhead) × (1 - growth) × (1 - headroom)
```

| Term | Typical value |
|---|---|
| Overhead | 10% for the filesystem and the metadata |
| Growth | 30% for a workload that is still growing |
| Headroom | 20% so that the pool never fills up |

A 1 TiB raw pool with those numbers gives about 540 GiB usable. On the
shared storage, the overhead of the thin provisioning matters less - the
capacity is what the file server has.
