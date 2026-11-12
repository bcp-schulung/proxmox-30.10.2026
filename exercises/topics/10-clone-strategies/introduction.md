# Topic 10 - Clone Strategies

**Topic ID:** `10-clone-strategies`
**Course reference:** Proxmox VE Introduction, Day 2 §4 "VM Templates &
Cloning"
**Duration:** 30 minutes
**Runs on:** one node

---

## 1. What you learn

A clone is a new guest built from a template. The question is whether it
gets its own copy of the disk or a view of the base disk.

```
   Template 9101 (base-9101-disk-1)
        │
        ├── Full clone 9201  -> vm-9201-disk-1      (a complete copy)
        └── Linked clone     -> base-9101-disk-1    (a copy-on-write view)
```

## 2. The decision

| | Full clone | Linked clone |
|---|---|---|
| Creation time | Minutes | Seconds |
| Space used | The full size | The changed blocks only |
| Independent of the template? | Yes | **No** |
| Use | Production | Development, testing, training |

**A linked clone depends on the base disk of the template.** If the template
is deleted, every linked clone breaks.

```bash
qm delete 9101
# unable to delete VM 9101: unable to free disk 'local-lvm:base-9101-disk-1' -
# logical volume 'vm-9101-disk-1' is used in configuration
```

Proxmox protects you here - it refuses to delete a template that has linked
clones. But it is better to know the rule than to rely on the guard.

## 3. Where the template has to live

The two kinds of clone have contradictory requirements, and this is the part
that trips people up:

- A **full clone** can be moved to another node only when the source is on
  **shared** storage. A template on the local storage of a node is refused
  with:

  ```
  can't clone VM to node 'pve2' (VM uses local storage)
  ```

- A **linked clone** is a snapshot of the template's disk, and a snapshot is
  only possible on a storage that supports them. NFS does not:

  ```
  Linked clone feature is not supported for 'nfs-lab:9000/...'
  ```

A template on the node's **own** local LVM-thin storage satisfies both
constraints. That is where the templates of this lab live:

```
   pve1: template 9101 -> guest 9201
   pve2: template 9102 -> guest 9202
   pve3: template 9103 -> guest 9203
```

Every guest is a **full clone** of the template on the node it runs on.

## 4. The clone flags

```bash
qm clone 9101 9201 --name debian13-run-pve1 --full --storage local-lvm
qm clone 9101 9210 --name scratch --full 0      # a linked clone
```

| Flag | Meaning |
|---|---|
| `--full` | A complete copy |
| `--full 0` | A linked clone |
| `--storage` | Where the new disk goes |
| `--name` | The name of the new guest |
| `--target` | The node the clone goes to |

The `--target` flag is worth knowing, but it only helps when the source is on
shared storage. With the templates of this lab on `local-lvm`, the clone is
made on the node that owns the template.

## 5. The cloud-init, again

Every clone needs its own cloud-init drive, otherwise it boots with the
template's hostname and credentials.

```bash
qm set 9203 --ide2 local:cloudinit --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-9203.yaml
```

## 6. What you do

1. Clone the template of your node into a new guest.
2. Verify that the clone has a disk of its own.
3. Give it its own cloud-init drive.
4. Verify that the template is still intact.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
