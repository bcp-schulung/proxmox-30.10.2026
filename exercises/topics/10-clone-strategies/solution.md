# Solution - Topic 10: Clone Strategies

**Topic ID:** `10-clone-strategies`

> **Instructor material.**

---

## 1. The linked clone

```bash
qm clone 9000 102 --name web-test --storage nfs-lab
```

> **No `--full` flag means a linked clone.** Proxmox 8 and later default to
> a linked clone when the flag is absent. Always write `--full` or
> `--full 0` explicitly - the difference is too consequential to leave to a
> default.

Verify:

```bash
qm config 102 | grep scsi0
# scsi0: nfs-lab:base-9000-disk-0,iothread=1,discard=on
```

The `base-9000` in the name is the marker of a linked clone. A full clone
shows its own disk name:

```bash
qm config 100 | grep scsi0
# scsi0: nfs-lab:vm-100-disk-0,discard=on,iothread=1
```

### The creation time

```bash
time qm clone 9000 102 --name web-test --storage nfs-lab
# real    0m1.234s

time qm clone 9000 103 --name web03 --full --storage nfs-lab
# real    0m12.456s
```

The linked clone is created in seconds. That is the whole point of the
technique.

## 2. The configuration

```bash
qm set 102 \
  --cores 2 \
  --sockets 1 \
  --memory 4096 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --onboot 1
```

## 3. The cloud-init drive

```bash
cat > /tmp/ci-102.yaml << EOF
#cloud-config
hostname: web-test
fqdn: web-test.nordwind.example.com
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

qm set 102 \
  --ide2 local:cloudinit \
  --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-102.yaml
```

## 4. Start and verify

```bash
qm start 102

for i in $(seq 1 30); do
    qm guest cmd 102 ping >/dev/null 2>&1 && break
    sleep 5
done

qm guest cmd 102 ping
qm guest exec 102 -- hostname
# web-test
```

## 5. The base template

```bash
qm config 9000 | grep template
# template: 1

pvesm list nfs-lab --content images | grep base-9000
```

### The dependency, demonstrated

```bash
# Proxmox protects you
qm delete 9000
# unable to delete VM 9000: unable to free disk 'nfs-lab:base-9000-disk-0' -
# logical volume 'vm-9000-disk-0' is used in configuration
```

The base disk stays as long as a linked clone uses it. That is the guard
rail. The rule is still worth knowing:

> **Never delete a template that has linked clones.**

## 6. The full clone, for comparison

```bash
qm clone 9000 101 --name web02 --full --storage nfs-lab
qm set 101 --cores 2 --memory 4096 --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1"
qm set 101 --ide2 local:cloudinit --ipconfig0 ip=dhcp --cicustom local:/tmp/ci-101.yaml
qm start 101
```

Compare the two:

```bash
qm config 101 | grep scsi0     # nfs-lab:vm-101-disk-0
qm config 102 | grep scsi0     # nfs-lab:base-9000-disk-0
```

### The space difference

```bash
pvesm list nfs-lab --content images
# local:vm-9000-disk-0      32 GB
# local:base-9000-disk-0    32 GB      <- the base, shared by all linked clones
# local:vm-101-disk-0       32 GB      <- the full clone, its own
# local:base-9000-disk-0    32 GB      <- the linked clone, a view of the base
```

The linked clone adds almost nothing until it starts writing.

## 7. Cloning directly onto another node

```bash
qm clone 9000 103 --name web03 --full --storage nfs-lab --target pve2
```

The disk goes to the shared storage and the configuration is created on
`pve2`. On a cluster with shared storage that is how you build a
redundant pair without a second round trip.

## 8. The complete sequence

```bash
qm clone 9000 102 --name web-test --storage nfs-lab

qm set 102 --cores 2 --sockets 1 --memory 4096 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1" --onboot 1

cat > /tmp/ci-102.yaml << EOF
#cloud-config
hostname: web-test
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

qm set 102 --ide2 local:cloudinit --ipconfig0 ip=dhcp --cicustom local:/tmp/ci-102.yaml

qm start 102
qm guest cmd 102 ping
qm guest exec 102 -- hostname
```

## 9. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The clone boots with the template's hostname | The cloud-init drive was not replaced | `qm set 102 --ide2 local:cloudinit --cicustom local:/tmp/ci-102.yaml` |
| The clone took minutes instead of seconds | It was a full clone | Drop the `--full` flag |
| `qm delete 9000` fails | A linked clone still uses the base | Delete the linked clones first, or keep the template |
| The clone has no address | `--ipconfig0` is missing | `qm set 102 --ipconfig0 ip=dhcp` |
| The clone is on the wrong node | The default is the node you ran the command on | `qm set 102 --target pve2` (only on a stopped guest) |
