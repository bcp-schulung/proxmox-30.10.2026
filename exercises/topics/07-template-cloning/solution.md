# Solution - Topic 07: The Golden Image and Templates

**Topic ID:** `07-template-cloning`

> **Instructor material.**

---

## What the lab looks like

There is **one template per node**, and each guest is a full clone of the template on the
node it runs on:

| Node | Template | Guest |
|---|---|---|
| pve1 | 9101 `debian13-tpl-pve1` | 9201 `debian13-run-pve1` |
| pve2 | 9102 `debian13-tpl-pve2` | 9202 `debian13-run-pve2` |
| pve3 | 9103 `debian13-tpl-pve3` | 9203 `debian13-run-pve3` |

The templates are on the node-local `local-lvm`, not on the shared `nfs-lab`. That is not
an accident - see [Why local-lvm](#why-local-lvm) below.

## 1. Get the image onto the node

```bash
curl -fSL -o /var/lib/vz/template/iso/debian-13-generic-amd64.qcow2 \
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
```

Verify it against the upstream `SHA512SUMS`:

```bash
cd /var/lib/vz/template/iso
sha512sum -c <<< "$(curl -sS https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS \
  | grep 'debian-13-generic-amd64.qcow2$')"
```

### The image is a disk, not an ISO

`debian-13-generic-amd64.qcow2` is a **qcow2 disk image**. It cannot be referenced as
`local:iso/debian-13-generic-amd64.qcow2`, because the `iso/` subdirectory of a directory
storage only accepts real ISO extensions and the volume-name parser refuses it:

```
unable to parse directory volume name 'iso/debian-13-generic-amd64.qcow2'
```

The image is therefore brought in with `qm importdisk`, which takes a plain path. See
[section 3](#3-import-the-disk).

> The `genericcloud` variant is **not** published under `images/cloud/trixie/latest` - only
> `generic` is. A URL with `genericcloud` in it returns 404.

## 2. Create the VM

```bash
qm create 9101 \
  --name debian13-tpl-pve1 \
  --memory 2048 \
  --cores 2 \
  --sockets 1 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --tablet 1 \
  --onboot 0 \
  --protection 0
```

### Why each option

| Option | Why |
|---|---|
| `--machine q35` | The modern chipset, with PCIe. Required for UEFI. |
| `--bios ovmf` | UEFI. Required for Secure Boot and for Windows in the future. |
| `--scsihw virtio-scsi-single` | The recommended disk controller. `single` is enough for most workloads; `virtio-scsi-pci` adds more queues. |
| `--net0 virtio` | The paravirtualised network device. Much faster than the emulated `e1000`. |
| `--agent enabled=1` | The QEMU guest agent. Without it there are no consistent backups and no graceful shutdown. |
| `--fstrim_cloned_disks=1` | The guest trims the unused blocks of a freshly cloned disk. Without it, a clone keeps growing and never releases the space of the deleted data. |
| `--tablet 1` | A USB tablet device. It makes the mouse work in the console and it is what the guest agent uses for the shutdown. |
| `--onboot 0` | A template is not started automatically, and neither is a guest built from it by hand. |

The EFI vars disk is created **before** the import, and that order matters:

```bash
qm set 9101 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=1
```

### Why `pre-enrolled-keys=1`

The EFI disk holds the Secure Boot keys. With `pre-enrolled-keys=1`, the Microsoft and
the Debian keys are written into it. A clone inherits the EFI disk from the template, so
a template without this produces clones that refuse to boot with:

```
Boot failed: Secure Boot: EFI image is missing its dbx revocation update
```

or simply do not find a bootable device.

## 3. Import the disk

```bash
qm importdisk 9101 /var/lib/vz/template/iso/debian-13-generic-amd64.qcow2 local-lvm
```

The imported disk appears as `unused0`:

```bash
qm config 9101 | grep unused
# unused0: local-lvm:vm-9101-disk-1
```

**Read the volume name back out of the config and attach that.** Do not guess the disk
number. With an `efidisk0` already attached, the EFI vars volume takes `disk-0` and the
imported OS disk lands on `disk-1`. Attaching `disk-0` to `scsi0` produces a template
that boots a 4 MB EFI partition instead of Debian:

```
scsi0: local-lvm:base-9101-disk-0,discard=on,iothread=1,size=4M
```

It looks correct at first glance, because the size is read from the config rather than
from the volume. The VM starts, shows nothing on the console, and never gets an
address.

```bash
IMPORTED=$(qm config 9101 | grep '^unused0:' | sed 's/^unused0: //' | cut -d, -f1)
qm set 9101 \
  --scsi0 "${IMPORTED},discard=on,iothread=1" \
  --boot order=scsi0
qm set 9101 --delete unused0
```

Check the size before going on:

```bash
qm config 9101 | grep scsi0
# scsi0: local-lvm:vm-9101-disk-1,discard=on,iothread=1,size=3G
```

`size=3G` is the Debian disk. `size=4M` is the EFI vars disk and it is wrong.

### Why `importdisk` and not `import`

`qm importdisk` copies the disk into the storage and attaches it in one
step. `qm import` creates an unattached disk that you then attach by hand.
Either works; `importdisk` is fewer steps and less to get wrong.

## 4. The cloud-init snippet

```bash
cat > /tmp/ci-9101.yaml << EOF
#cloud-config
hostname: debian13-tpl-pve1
fqdn: debian13-tpl-pve1.nordwind.example.com
manage_etc_hosts: true
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      passwd: '${GUEST_PASSWORD}'
      type: text
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF

qm set 9101 --cicustom local:/tmp/ci-9101.yaml
```

### The `local:` prefix

`local:` means the snippet is read from the node's local storage
(`/var/lib/vz/snippets`). Without the prefix, Proxmox looks for the snippet
on the **shared** storage - where it would be visible to every node.

A snippet with a password in it should not be spread across the cluster.

### `manage_etc_hosts`

The default is `true` on Debian, but it is worth being explicit. The
cloud-init behaviour rewrites `/etc/hosts` on every boot, and with
`manage_etc_hosts: false` the node's own `/etc/hosts` survives.

### The template has no cloud-init **drive**

The snippet above sets the `cicustom` option, but the template carries no
`--ide2 local:cloudinit` drive. The drive lives on the node-local `local`
storage, and Proxmox refuses to clone a VM that uses node-local storage to
another node:

```
can't clone VM to node 'pve2' (VM uses local storage)
```

Every **clone** gets its own cloud-init drive instead.

## 5. Boot and verify

```bash
qm start 9101

# Wait for the guest agent
for i in $(seq 1 30); do
    qm guest cmd 9101 ping >/dev/null 2>&1 && break
    sleep 5
done

qm guest cmd 9101 ping
qm guest exec 9101 -- hostname
qm guest exec 9101 -- systemctl is-active qemu-guest-agent
qm guest exec 9101 -- ip -brief a
```

Expected:

```
hostname output
debian13-tpl-pve1

active
```

The agent takes about 30 seconds to come up after the boot - it starts
after the network is up.

### A guest that does not answer

```bash
qm status 9101
qm showcmd 9101 | head -3
qm console 9101            # the interactive console
dmesg -T | tail -30
```

If the console shows a boot menu instead of a login prompt, the disk was not
in the boot order.

## 6. Shut it down and template it

```bash
qm shutdown 9101
qm status 9101             # stopped

qm template 9101
```

Verify:

```bash
qm config 9101 | grep template
# template: 1
```

Now the VM is read-only:

```bash
qm start 9101
# can't start VM: VM is a template
```

## 7. The complete sequence

```bash
# The image
curl -fSL -o /var/lib/vz/template/iso/debian-13-generic-amd64.qcow2 \
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2

# The VM
qm create 9101 --name debian13-tpl-pve1 --memory 2048 --cores 2 --sockets 1 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --ostype l26 \
  --machine q35 --bios ovmf --agent "enabled=1,fstrim_cloned_disks=1" \
  --tablet 1 --onboot 0 --protection 0

# The EFI vars disk - BEFORE the import
qm set 9101 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=1

# The disk
qm importdisk 9101 /var/lib/vz/template/iso/debian-13-generic-amd64.qcow2 local-lvm
IMPORTED=$(qm config 9101 | grep '^unused0:' | sed 's/^unused0: //' | cut -d, -f1)
qm set 9101 --scsi0 "${IMPORTED},discard=on,iothread=1" --boot order=scsi0
qm set 9101 --delete unused0
qm config 9101 | grep scsi0       # must be size=3G

# The cloud-init
cat > /tmp/ci-9101.yaml << EOF
#cloud-config
hostname: debian13-tpl-pve1
manage_etc_hosts: true
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      passwd: '${GUEST_PASSWORD}'
      type: text
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF
qm set 9101 --cicustom local:/tmp/ci-9101.yaml

# Boot, verify, stop
qm start 9101
qm guest cmd 9101 ping
qm guest exec 9101 -- hostname
qm shutdown 9101

# Template
qm template 9101
```

## 8. Why local-lvm

The two kinds of clone have contradictory requirements:

- A **full clone** can be moved to another node only when the source is on
  shared storage. A template on the local storage of a node is refused with
  `can't clone VM to node 'pve2' (VM uses local storage)`.
- A **linked clone** is a snapshot of the template's disk, and a snapshot is
  only possible on a storage that supports them. NFS does not:
  `Linked clone feature is not supported for 'nfs-lab:9000/...'`.

A template on the node's **own** local LVM-thin storage satisfies both
constraints, so that is where the templates live. Every node carries its own
copy of the golden image, and every guest is cloned from the template of the
node it runs on.

## 9. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The guest does not answer the agent | The agent is not installed | The cloud-init `packages:` section installs it |
| `qm guest cmd` times out | The agent is not running | `qm guest exec 9101 -- systemctl status qemu-guest-agent` |
| The guest boots to a menu | The disk is not in the boot order | `--boot order=scsi0` |
| The clone does not boot | No EFI keys | `pre-enrolled-keys=1` on the template |
| `qm start` on a template fails | That is correct | Convert it back with `qm template 9101` after `qm set 9101 --protection 0` |
| The clone has the wrong hostname | The cloud-init drive was not replaced | Give the clone its own snippet |
| The disk grows and never shrinks | `fstrim_cloned_disks` is not set | `--agent enabled=1,fstrim_cloned_disks=1` |
| The VM boots but shows nothing and gets no address | The 4 MB EFI disk was attached as `scsi0` | Read the imported volume name back out of `unused0` and check `size=3G` |
| `unable to parse directory volume name 'iso/...'` | The qcow2 was referenced as an ISO | Use `qm importdisk` with the plain path |
| The clone refuses to move to another node | The template is on local storage | That is by design - clone on the node the template belongs to |
