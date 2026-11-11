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
qm config 102 | grep scsi0
# scsi0: nfs-lab:base-9000-disk-0,size=32G     <- linked
# scsi0: nfs-lab:vm-102-disk-0,size=32G        <- full
```

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
qm set 102 --ide2 local:cloudinit --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-102.yaml
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

1. Download a Debian cloud image into the shared storage.
2. Create the VM 9000 with the correct machine type, controller and guest
   agent settings.
3. Import the disk and attach it.
4. Attach a cloud-init drive with the right snippet.
5. Boot it, verify the guest agent answers, and shut it down.
6. Convert it into a template.

## 6. How it is checked

```bash
./exercise.sh
```

## 7. The reference

`solution.md`.
