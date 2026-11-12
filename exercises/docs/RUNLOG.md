# Run log - bringing the lab up and running the exercises

## 2026-11-11 - initial assessment

### The state of the cluster

The cluster is up and healthy:

```
Name:             prod-cluster
Transport:        knet
Nodes:            3
Quorum:           2
Quorate:          Yes
```

| Node | Address | Role |
|---|---|---|
| pve1 | 10.20.0.246 | local |
| pve2 | 10.20.0.241 | |
| pve3 | 10.20.0.113 | |

### What is missing

The harness is at the `storage` phase. Four things are not in place:

**1. The Proxmox Backup Server instance is gone.**

```
i-04929fd55469ccbba  None  terminated   <- the old pbs1
i-07a4d508b4becb756  None  terminated
```

Only four instances are running: pve1, pve2, pve3 and nfs1. There is no
`pbs1` at all, and `10.20.2.243` does not answer on any port. The
`pbs-main` storage therefore does not exist.

**2. The template VM 9101 was broken.**

```
scsi0:    (missing)
boot:     order=net0            <- the boot order pointed at the network
unused0:  nfs-lab:9101/vm-9101-disk-0.raw
unused1:  nfs-lab:9101/vm-9101-disk-1.raw
```

`qm importdisk` had created `unused0` and `unused1`, but the `qm set
--scsi0` step never ran, so the VM had no boot disk at all.

**3. No clones and no containers.** No VM 9201/9202/9203, no CT 300/301/302,
and no `vztmpl` in the shared storage.

**4. The guests phase never completed.** `vms_ready: false`,
`cts_ready: false`, `security_ready: false`.

### What was fixed

The template disk attachment (`unused0` -> `scsi0`, EFI disk added, boot
order fixed to `order=scsi0`, leftover `unused1` deleted) and the Secure
Boot problem (`pre-enrolled-keys=1` selects the `.secboot.fd` firmware,
which rejects the unsigned Debian cloud image) were both repaired. The
guest still does not boot - that is tracked separately.

---

## 2026-11-11 - running the exercises

### The safety rule

> **The Proxmox host firewall on these nodes runs with `policy_in: DROP`.**
> A rule set that is written wrongly cuts SSH and the web UI off, and there
> is no way back except the serial console.

Consequences for the work:

- **Never write a firewall rule set on a node that is being reached over
  SSH.** The rules are written first, the default deny is switched on
  afterwards, and a second session stays open while testing.
- **Never change the firewall on a node other than the one the session is
  on** without checking that the rule set allows the operator's address.
- The exercise scripts only ever *read* the firewall configuration. They
  never write it.

The instructor may therefore want to confirm that the AWS security group
still allows the operator's IP on 22 and 8006 before the seminar starts.

### Topic 01 - Node preparation

Run against the live cluster on pve1. The result was **12 passed, 14
failed, 1 skipped** - and every failure was a bug in the exercise, not in
the lab. Three findings:

**1. Proxmox VE 9 uses the deb822 repository format.**

```
/etc/apt/sources.list.d/pve-install-repo.sources
    Types: deb
    URIs: http://download.proxmox.com/debian/pve
    Suites: trixie
    Components: pve-no-subscription
```

The old course material shows `pve-no-subscription.list`. The check now
accepts both formats.

**2. The firewall rules live at the node level, not at the cluster level.**

```
/etc/pve/cluster/firewall/cluster.fw   <- empty
/etc/pve/nodes/pve1/host.fw              <- the real rules
```

The node level takes precedence for the traffic addressed to the node
itself, so it is the node level that carries the effective policy. The
check now inspects both levels and verifies the union.

**3. `pveversion` prints `pve-manager/9.2.26/...`,** not `proxmox-ve/9.x`.

The `pveversion` output on this build is:

```
pve-manager/9.2.26/41a0e2e09b9e6f9d (running kernel: 7.0.14-28-pve)
```

The check was looking for `proxmox-ve/9.`.

### A note on the enterprise repository

The nodes still carry `pve-enterprise.sources` and `apt update` therefore
reports:

```
E: Failed to fetch https://enterprise.proxmox.com/debian/pve/dists/trixie/InRelease
  401  Unauthorized
```

This is the *expected* symptom that the security topic describes, and it is
one of the things the students are asked to fix in task 1. The nodes are
unlicensed, so the fix is to remove the enterprise source.
