# Topic 07 - The Golden Image and Templates

**Topic ID:** `07-template-cloning`
**Course reference:** Proxmox VE Introduction, Day 2 §4 "VM Templates &
Cloning"
**Duration:** 60 minutes
**Runs on:** one node

---

## 1. What you learn

A template is a VM in a read-only state that exists to be cloned. It is the
difference between provisioning a server in ten minutes and provisioning one
in two hours.

```
   Base VM / Golden Image
            │
      qm template
            │
       VM Template (read-only)
        ╱          ╲
   Full Clone      Linked Clone
   own disk        shares the base disk
   production      dev / test
   minutes         seconds
```

## 2. Full clone vs linked clone

| | Full clone | Linked clone |
|---|---|---|
| Disk | A complete copy | A copy-on-write view of the base disk |
| Space | The full size | Almost nothing |
| Time | Minutes | Seconds |
| Independent? | Yes | No - it depends on the base |
| Use | Production | Dev / test / throwaway |

A linked clone is a `qcow2` overlay. Reading a block that was never written
reads the base disk; writing one creates a new block in the clone's own
file. Deleting the base breaks every linked clone.

```bash
qm config 9203 | grep scsi0
# scsi0: local-lvm:vm-9203-disk-1,size=3G        <- full clone
# scsi0: local-lvm:base-9101-disk-1,size=3G      <- linked clone
```

> The lab uses full clones. A linked clone needs a storage that supports
> snapshots, and NFS does not - see [topic 10](../10-clone-strategies/).

## 3. The cloud-init trap

This is the thing that breaks most often, and it is worth understanding
rather than memorising.

A cloud-init drive is a small disk that Proxmox hands to the guest on first
boot. The guest reads the user-data from it and applies it - the hostname,
the password, the SSH keys, the packages.

**A clone inherits the cloud-init drive of its source.** So a clone of the
template boots with the *template's* hostname and the *template's*
credentials.

The fix is to give every clone its own cloud-init drive:

```bash
qm set 9203 --ide2 local:cloudinit --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-9203.yaml
```

The `local:` prefix means the snippet lives on the node's local storage,
not on the shared storage. That is deliberate - a snippet on shared storage
is available to every node, and a snippet with a password in it is a secret
that should not be spread around.

## 4. The golden image

The image that becomes the template should be as close to "ready to work" as
possible:

- the guest agent installed and enabled
- the VirtIO drivers present (a Debian cloud image already has them)
- the SSH keys and the password set
- no host-specific state that would confuse the clones

```bash
# Inside the guest
systemctl enable --now qemu-guest-agent
```

The guest agent is not optional. It is what makes the filesystem freeze for
a consistent backup, what reports the guest's IP address to the host, and
what turns a "stop" into a graceful shutdown.

## 5. What you do

The lab is pre-provisioned with a template on every node, but the exercise is to
build one yourself:

1. Download a Debian cloud image into the node's ISO directory. **It is a qcow2
   disk, not an ISO** - it cannot be referenced as `local:iso/<file>.qcow2`.
2. Create the VM 9101 with the correct machine type, controller and guest
   agent settings.
3. Create the EFI vars disk, **before** the import.
4. Import the disk with `qm importdisk` and attach it - reading the volume
   name back out of the config rather than guessing the disk number.
5. Attach a cloud-init snippet.
6. Boot it, verify the guest agent answers, and shut it down.
7. Convert it into a template.

Then repeat it on the other two nodes. Every node needs its own template,
because a template on the local storage of a node cannot be cloned onto a
different one.

## 6. How it is checked

```bash
./exercise.sh
```

## 7. The reference

`solution.md`.
