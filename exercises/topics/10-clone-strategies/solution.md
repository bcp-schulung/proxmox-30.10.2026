# Solution - Topic 10: Clone Strategies

**Topic ID:** `10-clone-strategies`

> **Instructor material.**

---

## 0. The starting point

The lab has one template per node and one running guest per node:

```
   pve1: template 9101 debian13-tpl-pve1  ->  guest 9201 debian13-run-pve1
   pve2: template 9102 debian13-tpl-pve2  ->  guest 9202 debian13-run-pve2
   pve3: template 9103 debian13-tpl-pve3  ->  guest 9203 debian13-run-pve3
```

Every guest is a **full clone** of the template on the node it runs on. The
templates are on the node-local `local-lvm`.

## 1. The full clone

```bash
qm clone 9101 9210 --name scratch --full --storage local-lvm
```

> **Always write `--full` or `--full 0` explicitly.** Proxmox 8 and later
> default to a *linked* clone when the flag is absent. The difference is too
> consequential to leave to a default.

Verify:

```bash
qm config 9210 | grep scsi0
# scsi0: local-lvm:vm-9210-disk-0,discard=on,iothread=1
```

A full clone has a disk of its own. The volume name is `vm-<vmid>-disk-N`.

## 2. The linked clone, for comparison

```bash
qm clone 9101 9211 --name scratch-linked --full 0
```

Verify:

```bash
qm config 9211 | grep scsi0
# scsi0: local-lvm:base-9101-disk-0,iothread=1,discard=on
```

The `base-9101` in the name is the marker of a linked clone - it is a view of
the template's base disk.

### The creation time

```bash
time qm clone 9101 9211 --name scratch-linked --full 0
# real    0m1.234s

time qm clone 9101 9210 --name scratch --full --storage local-lvm
# real    0m12.456s
```

The linked clone is created in seconds. That is the whole point of the
technique.

### Where a linked clone is possible at all

A linked clone is a snapshot, and a snapshot is only possible on a storage
that supports them. On the shared NFS storage the request is refused:

```
Linked clone feature is not supported for 'nfs-lab:9000/...'
```

That is the reason the templates of this lab live on `local-lvm` and not on
`nfs-lab`.

## 3. The configuration

```bash
qm set 9210 \
  --cores 2 \
  --sockets 1 \
  --memory 4096 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --onboot 1
```

## 4. The cloud-init drive

```bash
cat > /tmp/ci-9210.yaml << EOF
#cloud-config
hostname: scratch
fqdn: scratch.nordwind.example.com
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

qm set 9210 \
  --ide2 local:cloudinit \
  --ipconfig0 ip=dhcp \
  --cicustom local:/tmp/ci-9210.yaml
```

## 5. Start and verify

```bash
qm start 9210

for i in $(seq 1 30); do
    qm guest cmd 9210 ping >/dev/null 2>&1 && break
    sleep 5
done

qm guest cmd 9210 ping
qm guest exec 9210 -- hostname
# scratch
```

## 6. The base template

```bash
qm config 9101 | grep template
# template: 1

pvesm list local-lvm --content images | grep base-9101
```

### The dependency, demonstrated

```bash
# Proxmox protects you
qm delete 9101
# unable to delete VM 9101: unable to free disk 'local-lvm:base-9101-disk-0' -
# logical volume 'vm-9101-disk-0' is used in configuration
```

The base disk stays as long as a linked clone uses it. That is the guard
rail. The rule is still worth knowing:

> **Never delete a template that has linked clones.**

## 7. Cloning directly onto another node

```bash
qm clone 9101 9212 --name scratch-on-pve2 --full --storage nfs-lab --target pve2
```

The disk goes to the shared storage and the configuration is created on
`pve2`. On a cluster with shared storage that is how you build a redundant
pair without a second round trip.

Note the difference to the templates of this lab: they are on `local-lvm`, so
a clone of them **cannot** be moved to another node:

```
can't clone VM to node 'pve2' (VM uses local storage)
```

That is why every node carries its own template.

## 8. The complete sequence

```bash
qm clone 9101 9210 --name scratch --full --storage local-lvm

qm set 9210 --cores 2 --sockets 1 --memory 4096 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --agent "enabled=1,fstrim_cloned_disks=1" --onboot 1

cat > /tmp/ci-9210.yaml << EOF
#cloud-config
hostname: scratch
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

qm set 9210 --ide2 local:cloudinit --ipconfig0 ip=dhcp --cicustom local:/tmp/ci-9210.yaml

qm start 9210
qm guest cmd 9210 ping
qm guest exec 9210 -- hostname
```

## 9. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The clone boots with the template's hostname | The cloud-init drive was not replaced | `qm set 9210 --ide2 local:cloudinit --cicustom local:/tmp/ci-9210.yaml` |
| The clone took minutes instead of seconds | It was a full clone | Use `--full 0` for a linked clone |
| `qm delete 9101` fails | A linked clone still uses the base | Delete the linked clones first, or keep the template |
| The clone has no address | `--ipconfig0` is missing | `qm set 9210 --ipconfig0 ip=dhcp` |
| The clone refuses to move to another node | The template is on local storage | That is by design - clone on the node the template belongs to |
| The linked clone cannot be created | The template is on NFS | A snapshot needs a block storage - use `local-lvm` |
