# Topic 02 - The Platform Architecture

**Topic ID:** `02-platform-architecture`
**Course reference:** Proxmox VE Introduction, Day 1, §2 and §3 "Virtualization
Concepts" and "Proxmox VE Architecture Overview"
**Duration:** 45 minutes
**Runs on:** one node (`pve1`)

---

## 1. What you learn

Proxmox VE is not one program. It is a set of cooperating services on top of
Debian Linux, and almost every troubleshooting session comes down to
understanding which service does what.

This exercise is a guided tour. You look at the services, look at the
cluster filesystem, and look at a running guest - and then you can answer any
question about "where does this setting live" with confidence.

## 2. The service map

```
                        Web Browser
                              |
                         HTTPS 8006
                              |
              +---------------+---------------+
              |                               |
        pveproxy                         pvedaemon
   (TLS, CSRF, auth)             (privileged API worker)
              |                               |
              +---------------+---------------+
                              |
                    pmxcfs (/etc/pve)
                       SQLite over corosync
                              |
        +---------------------+---------------------+
        |                     |                     |
  QEMU/KVM (VMs)        LXC containers        pve-firewall
   tap devices            veth pairs          (dc/node/vm)
        |                     |                     |
        +---------------------+---------------------+
                              |
                        pvestatd (RRD)
                              |
                    Storage (pvesm)
```

| Service | Port | Job |
|---|---|---|
| `pveproxy` | 8006 | HTTPS reverse proxy for the web UI and the API |
| `pvedaemon` | - | The privileged worker that executes API requests |
| `pmxcfs` | - | The cluster filesystem mounted at `/etc/pve` |
| `pvestatd` | - | Collects CPU, RAM, disk and network statistics |
| `pve-firewall` | - | Enforces the datacenter, node and guest firewall rules |
| `corosync` | 5405-5412/udp | Cluster membership and the `pmxcfs` replication |
| `pvedaemon`+`pvestatd` | - | The API and the metrics that feed the graphs |

## 3. Three ways to do the same thing

Everything the web UI does is an API call. The UI is a thin client.

```bash
qm list                                    # the CLI
pvesh get /nodes/pve1/qemu                # the API
curl -k -H "Authorization: PVEAPIToken=..." \
     https://pve1:8006/api2/json/nodes/pve1/qemu
```

The third form needs an API token. You create one in the identity topic.

**What this buys you:** everything you can do in the browser, you can script.
And everything you can script, you can verify. That is the basis of every
`exercise.sh` in this course.

## 4. The cluster filesystem

`/etc/pve` looks like a normal directory:

```
/etc/pve/
├── cluster/
│   ├── firewall/
│   └── ha/
├── nodes/
├── qemu-server/
│   ├── 100.conf
│   └── 101.conf
├── lxc/
│   ├── 300.conf
│   └── 301.conf
├── storage.cfg
├── user.cfg
├── vzdump.cron
└── priv/
```

It is not a normal directory. It is a SQLite database replicated over
corosync, and every quorate node mounts the same copy. That is why:

- a `qm set` on `pve1` is visible on `pve3` within milliseconds
- the cluster configuration has no single point of failure
- `priv/` holds the secrets, and it is not replicated in a readable form

You can see it is a FUSE filesystem:

```bash
mount | grep pve
stat -f -c '%T' /etc/pve      # -> fuse.pmxcfs
```

## 5. What you do

On `pve1`:

1. List the Proxmox services and confirm they are running.
2. Show the same guest list through `qm`, `pvesh` and the raw API.
3. Demonstrate that `/etc/pve` is a cluster filesystem.
4. Demonstrate that a change on one node appears on the others.
5. Find the QEMU process of a running guest and compare it with `qm showcmd`.

## 6. How it is checked

```bash
./exercise.sh
```

The checks confirm the services, the API equivalence and the replication.

## 7. The reference

`solution.md`.
