# Solution - Topic 02: The Platform Architecture

**Topic ID:** `02-platform-architecture`

> **Instructor material.**

---

## 1. The services

```bash
systemctl list-units 'pve*' --no-pager
systemctl status pveproxy pvedaemon pvestatd pve-cluster corosync --no-pager

# What is listening?
ss -tlnp | grep -E '8006|8007'

# The API answers
curl -sk https://localhost:8006/api2/json/version | jq .
```

Expected:

```json
{
  "data": {
    "release": "9.2",
    "repoid": "8b3a4b2c",
    "version": "9.2.3"
  }
}
```

> `curl -k` skips the certificate check. The default Proxmox certificate is
> self-signed, so without `-k` the curl call fails with a certificate
> error. That is not a problem with the cluster - it is the default
> certificate, and the TLS topic replaces it.

## 2. The cluster filesystem

```bash
mount | grep pve
stat -f -c '%T' /etc/pve          # -> fuse.pmxcfs

ls -la /etc/pve/
ls /etc/pve/qemu-server/
ls /etc/pve/lxc/
cat /etc/pve/storage.cfg
```

The permissions of the secret directory:

```bash
ls -ld /etc/pve/priv
```

Expected:

```
drwxr-xr-x 1 root root 4096 Nov 10 09:00 priv
```

The important part is that `priv/` is **not** readable by anyone but root,
and that it is not a normal directory - it is a FUSE mount that is only
available on the node that holds the secret. In a cluster with three nodes,
the storage password of an NFS storage lives on exactly one of them.

## 3. The three ways to do the same thing

```bash
# 1. The CLI
qm list

# 2. The API, node scoped
pvesh get /nodes/$(hostname)/qemu

# 3. The API, cluster scoped
pvesh get /cluster/resources --type vm

# 4. The raw HTTP API with a token
export PVE_TOKEN='automation@pve!terraform=xxxx-xxxx-xxxx'
curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/nodes/$(hostname)/qemu" | jq '.data[] | .vmid'
```

The `qm list` output:

```
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 web01                running    4096              32.00 1234
       101 web02                running    4096              32.00 2345
```

The `pvesh` output carries the same information in JSON, plus the fields the
CLI does not show - the node, the uptime, the tags.

### What the equivalence buys you

```bash
# The number of guests, counted three ways
qm list | tail -n +2 | wc -l
pvesh get /nodes/$(hostname)/qemu --output-format json | jq 'length'
pvesh get /cluster/resources --type vm --output-format json | jq 'length'
```

All three have to agree. When they do not, the CLI is reading the local
configuration and the API is reading the cluster - and that difference is
itself a diagnostic.

## 4. The replication

On `pve1`:

```bash
echo "written on pve1 at $(date)" > /etc/pve/cluster-demo.txt
```

On `pve2` (within a second):

```bash
cat /etc/pve/cluster-demo.txt
```

Then clean up:

```bash
rm /etc/pve/cluster-demo.txt
```

The check in `exercise.sh` does this automatically, so the exercise leaves
the cluster configuration as it found it.

### What happens when the cluster is not quorate

```bash
pvecm status
```

Without quorum, `pmxcfs` goes into read-only mode. A `qm set` then fails:

```
can't lock file '/var/lib/vz/.lock' - got timeout
```

or

```
CT 300 is locked (create)
```

This is by design. A node that cannot reach a majority of the cluster must
not accept configuration changes, because it cannot know whether the change
it is about to make has already been made on another node.

## 5. The QEMU process

```bash
# The command line Proxmox would use
qm showcmd 100

# The process that is actually running
ps aux | grep '[k]vm'

# The two match
```

`qm showcmd` prints the exact command line that QEMU was started with. The
process list shows the same thing with the PID. Comparing them is how you
spot a guest that was started by hand instead of by Proxmox - and a guest
that was started by hand is a guest that Proxmox does not know about, with
no backup, no HA and no configuration.

### A more precise match

```bash
pid=$(pgrep -f 'qemu-system' | head -1)
tr '\0' ' ' < /proc/${pid}/cmdline | head -c 400
echo
```

This is the *live* command line. When `qm config` and the live command line
disagree, the guest is running with an older configuration - which is the
normal case after a `qm set` on a stopped guest.

## 6. The complete sequence

```bash
# The services
systemctl status pveproxy pvedaemon pvestatd pve-cluster corosync --no-pager
ss -tlnp | grep 8006
curl -sk https://localhost:8006/api2/json/version | jq .

# The cluster filesystem
mount | grep pve
stat -f -c '%T' /etc/pve
ls /etc/pve/qemu-server/ /etc/pve/lxc/
ls -ld /etc/pve/priv

# The three ways
qm list
pvesh get /nodes/$(hostname)/qemu
pvesh get /cluster/resources --type vm

# The replication
echo "demo" > /etc/pve/cluster-demo.txt
# ... check on pve2 ...
rm /etc/pve/cluster-demo.txt

# The QEMU process
qm showcmd 100
ps aux | grep '[k]vm'
```

## 7. The troubleshooting map

When something does not work, this is the order to look in:

| Symptom | Look at |
|---|---|
| The web UI does not load | `pveproxy`, port 8006, the firewall |
| The web UI loads but shows errors | `pvedaemon`, `journalctl -u pvedaemon` |
| The changes are not saved | `pmxcfs` - is the cluster quorate? |
| The cluster is not quorate | `corosync`, the UDP ports 5405-5412, the clock |
| No graphs | `pvestatd` |
| The guests are slow | `pvestatd` metrics, the storage, the CPU limits |

This table is the answer to almost every "the Proxmox UI is broken" ticket.
