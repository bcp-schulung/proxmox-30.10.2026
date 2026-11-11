# Solution - Topic 08: The VM Lifecycle

**Topic ID:** `08-vm-lifecycle`

> **Instructor material.**

---

## 1. Clone the template

```bash
qm clone 9000 100 --name web01 --full --storage nfs-lab
```

`--full` is the default, but write it explicitly - the difference between a
full and a linked clone is the single most consequential flag in this
command, and it should be obvious in the command line.

Verify:

```bash
qm config 100 | grep scsi0
# scsi0: nfs-lab:vm-100-disk-0,size=32G
```

A linked clone would show `base-9000-disk-0` here.

## 2. Configure it

```bash
qm set 100 \
  --name web01 \
  --cores 2 \
  --sockets 1 \
  --memory 4096 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --scsihw virtio-scsi-single \
  --scsi0 nfs-lab:vm-100-disk-0,discard=on,iothread=1 \
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --machine q35 \
  --bios ovmf \
  --onboot 1
```

### The VLAN tag

`tag=20` puts the guest into the web tier. The tag is what the bridge and
the firewall work with:

```bash
qm config 100 | grep net0
# net0: virtio=BC:76:4E:xx:xx:xx,bridge=vmbr0,tag=20
```

### `discard=on` and `iothread=1`

| Option | What it does |
|---|---|
| `discard=on` | Passes the TRIM/Unmap through to the storage. Without it, the deleted blocks of a thin disk are never released, and a guest that creates and deletes files grows forever. |
| `iothread=1` | Runs the disk in its own thread. It helps when one disk has a long queue of I/O and the other I/O of the guest would otherwise wait behind it. |

## 3. The cloud-init drive

```bash
cat > /tmp/ci-100.yaml << EOF
#cloud-config
hostname: web01
fqdn: web01.nordwind.example.com
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

qm set 100 \
  --ide2 local:cloudinit \
  --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-100.yaml
```

### Why all three options

`--ide2 local:cloudinit` attaches the drive. Without it, the clone has no
cloud-init drive and boots with the hostname that was baked into the image.

`--ipconfig0 ip=dhcp` tells the guest to use DHCP. Without it, the guest
tries the address that was in the image - which is wrong.

`--cicustom` points at the snippet. The drive itself is regenerated on the
next boot, so the snippet has to be there *before* the boot.

### The trap

The clone inherited the template's cloud-init drive. Setting `--cicustom`
replaces the content, but the drive has to be attached as well - otherwise
the setting is stored and the drive is never created.

## 4. Start and verify

```bash
qm start 100

# The agent needs about 30 seconds
for i in $(seq 1 30); do
    qm guest cmd 100 ping >/dev/null 2>&1 && break
    sleep 5
done

qm guest cmd 100 ping
qm guest exec 100 -- hostname
qm guest exec 100 -- ip -brief a
qm guest exec 100 -- systemctl is-active qemu-guest-agent
```

Expected:

```
web01
eth0    UP    10.10.10.101/24
active
```

## 5. The snapshot cycle

```bash
qm snapshot 100 pre-update --description "before the Nordwind release"

qm guest exec 100 -- sh -c 'echo "release-2.4" > /etc/nordwind-version'
qm guest exec 100 -- cat /etc/nordwind-version
# release-2.4

qm rollback 100 pre-update

qm guest exec 100 -- cat /etc/nordwind-version
# cat: /etc/nordwind-version: No such file or directory
```

The guest keeps running through the rollback. Because the agent is enabled,
the snapshot includes the memory state, so the rollback restores a *running*
guest rather than a stopped one.

```bash
qm delsnapshot 100 pre-update
```

### The configuration changes that need a stopped guest

```bash
qm set 100 --cores 4        # applied live
qm set 100 --cpu host       # applied live
qm set 100 --scsihw virtio-scsi-pci   # needs a restart
qm resize 100 scsi0 +20G    # needs a restart, or a hotplug
```

Proxmox tells you which is which:

```
# qm set 100 --scsihw virtio-scsi-pci
unable to set scsihw: "virtio-scsi-pci" is not supported in the current configuration
```

and the pending mechanism:

```bash
qm set 100 --scsihw virtio-scsi-pci --pending 1
qm pending 100
```

## 6. The clean shutdown

```bash
qm shutdown 100 --timeout 60
qm status 100
# status: stopped
```

Without the guest agent, `qm shutdown` falls back to an ACPI request, which
many guests ignore. Then `qm shutdown --forceStop 1` cuts the power after
the timeout.

```bash
qm start 100
qm guest cmd 100 ping
```

## 7. The complete sequence

```bash
# The clone
qm clone 9000 100 --name web01 --full --storage nfs-lab

# The configuration
qm set 100 --cores 2 --sockets 1 --memory 4096 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --scsihw virtio-scsi-single \
  --scsi0 nfs-lab:vm-100-disk-0,discard=on,iothread=1 \
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --machine q35 --bios ovmf --onboot 1

# The cloud-init
cat > /tmp/ci-100.yaml << EOF
#cloud-config
hostname: web01
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
qm set 100 --ide2 local:cloudinit --ipconfig0 ip=dhcp --cicustom local:/tmp/ci-100.yaml

# Start and verify
qm start 100
qm guest cmd 100 ping
qm guest exec 100 -- hostname

# The lifecycle
qm shutdown 100 --timeout 60
qm start 100
```

## 8. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The guest has the template's hostname | The cloud-init drive was not replaced | `qm set 100 --ide2 local:cloudinit --cicustom local:/tmp/ci-100.yaml` and reboot |
| The guest has no address | `--ipconfig0` is missing | `qm set 100 --ipconfig0 ip=dhcp` |
| `qm guest cmd` times out | The agent is not installed or not running | `qm guest exec 100 -- systemctl status qemu-guest-agent` |
| `qm shutdown` does nothing | No agent and no ACPI support | `qm shutdown --forceStop 1` |
| The disk grows forever | `discard=on` is missing | `qm set 100 --scsi0 ...,discard=on` |
| `qm set --scsihw` is refused | The change needs a stopped guest | `--pending 1` and a restart |
| The guest is slow after an I/O burst | One disk blocks the others | `iothread=1` |
