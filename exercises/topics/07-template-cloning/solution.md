# Solution - Topic 07: The Golden Image and Templates

**Topic ID:** `07-template-cloning`

> **Instructor material.**

---

## 1. Get the image into the shared storage

```bash
pvesm download-url nfs-lab \
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 \
  debian-13-genericcloud.qcow2
```

Or, on a node with internet access:

```bash
curl -fSL -o /mnt/pve/nfs-lab/debian-13-genericcloud.qcow2 \
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
```

Verify:

```bash
pvesm list nfs-lab --content images
```

## 2. Create the VM

```bash
qm create 9000 \
  --name debian13-template \
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
  --onboot 1 \
  --protection 0 \
  --ide2 local:cloudinit \
  --ipconfig0 ip=dhcp
```

### Why each option

| Option | Why |
|---|---|
| `--machine q35` | The modern chipset, with PCIe. Required for UEFI. |
| `--bios ovmf` | UEFI. Required for Secure Boot and for Windows in the future. |
| `--scsihw virtio-scsi-single` | The recommended disk controller. `single` is enough for most workloads; `virtio-scsi-pci` adds more queues. |
| `--net0 virtio` | The paravirtualised network device. Much faster than the emulated `e1000`. |
| `--agent enabled=1` | The QEMU guest agent. Without it there are no consistent backups and no graceful shutdown. |
| `--fstrim_cloned_disks=1` | The guest trims the unused blocks of a freshly cloned disk. Without it, a linked clone keeps growing and never releases the space of the deleted data. |
| `--tablet 1` | A USB tablet device. It makes the mouse work in the console and it is what the guest agent uses for the shutdown. |

## 3. Import the disk

```bash
qm importdisk 9000 nfs-lab:debian-13-genericcloud.qcow2 nfs-lab
```

The imported disk appears as `unused0`:

```bash
qm config 9000 | grep unused
# unused0: nfs-lab:vm-9000-disk-0
```

Then attach it:

```bash
qm set 9000 \
  --scsi0 nfs-lab:vm-9000-disk-0,discard=on,iothread=1 \
  --efidisk0 nfs-lab:1,efitype=4m,pre-enrolled-keys=1 \
  --boot order=scsi0
```

### Why `importdisk` and not `import`

`qm importdisk` copies the disk into the storage and attaches it in one
step. `qm import` creates an unattached disk that you then attach by hand.
Either works; `importdisk` is fewer steps and less to get wrong.

### Why `pre-enrolled-keys=1`

The EFI disk holds the Secure Boot keys. With `pre-enrolled-keys=1`, the
Microsoft and the Debian keys are written into it. A clone inherits the
EFI disk from the template, so a template without this produces clones that
refuse to boot with:

```
Boot failed: Secure Boot: EFI image is missing its dbx revocation update
```

or simply do not find a bootable device.

## 4. The cloud-init snippet

```bash
cat > /tmp/ci-9000.yaml << EOF
#cloud-config
hostname: debian13-template
fqdn: debian13-template.nordwind.example.com
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

qm set 9000 --cicustom local:/tmp/ci-9000.yaml
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

## 5. Boot and verify

```bash
qm start 9000

# Wait for the guest agent
for i in $(seq 1 30); do
    qm guest cmd 9000 ping >/dev/null 2>&1 && break
    sleep 5
done

qm guest cmd 9000 ping
qm guest exec 9000 -- hostname
qm guest exec 9000 -- systemctl is-active qemu-guest-agent
qm guest exec 9000 -- ip -brief a
```

Expected:

```
hostname output
debian13-template

active
```

The agent takes about 30 seconds to come up after the boot - it starts
after the network is up.

### A guest that does not answer

```bash
qm status 9000
qm showcmd 9000 | head -3
qm console 9000            # the interactive console
dmesg -T | tail -30
```

If the console shows a boot menu instead of a login prompt, the disk was not
in the boot order.

## 6. Shut it down and template it

```bash
qm shutdown 9000
qm status 9000             # stopped

qm template 9000
```

Verify:

```bash
qm config 9000 | grep template
# template: 1
```

Now the VM is read-only:

```bash
qm start 9000
# can't start VM: VM is a template
```

## 7. The complete sequence

```bash
# The image
pvesm download-url nfs-lab \
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 \
  debian-13-genericcloud.qcow2

# The VM
qm create 9000 --name debian13-template --memory 2048 --cores 2 --sockets 1 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --ostype l26 \
  --machine q35 --bios ovmf --agent "enabled=1,fstrim_cloned_disks=1" \
  --tablet 1 --onboot 1 --protection 0 --ide2 local:cloudinit --ipconfig0 ip=dhcp

# The disk
qm importdisk 9000 nfs-lab:debian-13-genericcloud.qcow2 nfs-lab
qm set 9000 --scsi0 nfs-lab:vm-9000-disk-0,discard=on,iothread=1 \
  --efidisk0 nfs-lab:1,efitype=4m,pre-enrolled-keys=1 --boot order=scsi0

# The cloud-init
cat > /tmp/ci-9000.yaml << EOF
#cloud-config
hostname: debian13-template
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
qm set 9000 --cicustom local:/tmp/ci-9000.yaml

# Boot, verify, stop
qm start 9000
qm guest cmd 9000 ping
qm guest exec 9000 -- hostname
qm shutdown 9000

# Template
qm template 9000
```

## 8. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The guest does not answer the agent | The agent is not installed | The cloud-init `packages:` section installs it |
| `qm guest cmd` times out | The agent is not running | `qm guest exec 9000 -- systemctl status qemu-guest-agent` |
| The guest boots to a menu | The disk is not in the boot order | `--boot order=scsi0` |
| The clone does not boot | No EFI keys | `pre-enrolled-keys=1` on the template |
| `qm start` on a template fails | That is correct | Convert it back with `qm template 9000` after `qm set 9000 --protection 0` |
| The clone has the wrong hostname | The cloud-init drive was not replaced | Give the clone its own snippet |
| The disk grows and never shrinks | `fstrim_cloned_disks` is not set | `--agent enabled=1,fstrim_cloned_disks=1` |
