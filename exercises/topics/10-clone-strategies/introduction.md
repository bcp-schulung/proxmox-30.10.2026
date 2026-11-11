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
   Template 9000 (base-9000-disk-0)
        │
        ├── Full clone 100  -> vm-100-disk-0      (a complete copy)
        └── Linked clone 102 -> base-9000-disk-0  (a copy-on-write view)
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
qm delete 9000
# unable to delete VM 9000: unable to free disk 'nfs-lab:base-9000-disk-0' -
# logical volume 'vm-9000-disk-0' is used in configuration
```

Proxmox protects you here - it refuses to delete a template that has linked
clones. But it is better to know the rule than to rely on the guard.

## 3. The clone flags

```bash
qm clone 9000 100 --name web01 --full --storage nfs-lab
qm clone 9000 102 --name web-test --storage nfs-lab        # linked
```

| Flag | Meaning |
|---|---|
| `--full` | A complete copy |
| `--full 0` | A linked clone |
| `--storage` | Where the new disk goes |
| `--name` | The name of the new guest |
| `--target` | The node the clone goes to |

The `--target` flag is worth knowing: a clone can be created directly on
another node. On a cluster with shared storage that is how you build a
redundant pair.

## 4. The cloud-init, again

Every clone needs its own cloud-init drive, otherwise it boots with the
template's hostname and credentials.

```bash
qm set 102 --ide2 local:cloudinit --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-102.yaml
```

## 5. What you do

1. Create the full clone VM 102 `web-test` on the shared storage.
2. Verify that it really is a linked clone.
3. Give it its own cloud-init drive.
4. Verify that the template is still intact.

## 6. How it is checked

```bash
./exercise.sh
```

## 7. The reference

`solution.md`.
