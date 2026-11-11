# Topic 17 - Troubleshooting

**Topic ID:** `17-troubleshooting`
**Course reference:** Proxmox VE Introduction, Day 3 §8
**Duration:** 45 minutes
**Runs on:** one node

---

## 1. What you learn

The first question in any Proxmox ticket is always the same:

> **Is the problem in the guest, or on the host?**

Answering that question first turns a two hour search into a two minute
one.

## 2. The decision tree

```
   Problem reported
        │
        ├── Guest or host?
        │       │
        │       ├── Guest
        │       │    ├── VM or CT?
        │       │    │     ├── VM  -> qm status, qm showcmd, the console,
        │       │    │     │           dmesg on the host
        │       │    │     └── CT  -> pct status,
        │       │    │                journalctl -u pve-container@<id>
        │       │
        │       └── Host
        │            ├── Service -> journalctl -u pvedaemon -u pveproxy -u pvestatd
        │            └── Storage -> pvesm status, dmesg -T | tail
        │
        └── Apply the fix, then VERIFY
```

## 3. The guest side

```bash
# A VM
qm status 100
qm showcmd 100
qm guest cmd 100 ping
qm guest exec 100 -- ip -brief a
qm guest exec 100 -- ip route
qm guest exec 100 -- cat /etc/resolv.conf
qm guest exec 100 -- systemctl --failed --no-legend

# A container
pct status 300
pct exec 300 -- ip -brief a
pct exec 300 -- systemctl --failed --no-legend
journalctl -u pve-container@300 -n 50 --no-pager
```

## 4. The host side

```bash
# The services
journalctl -u pvedaemon -u pveproxy -u pvestatd --since "1 hour ago" --no-pager

# The storage
pvesm status
dmesg -T | tail -50

# The kernel
journalctl -k --since "1 hour ago" --no-pager

# The cluster
pvecm status
```

## 5. The most common causes

| Symptom | Most likely cause | First command |
|---|---|---|
| The guest does not boot | The disk is not in the boot order | `qm config <id> \| grep boot` |
| The guest has no network | The bridge is down | `ip a show vmbr0` |
| The guest has no address | dnsmasq is not running | `systemctl status dnsmasq` |
| The guest has an address but no route | The DHCP options are missing | `grep dhcp-option /etc/dnsmasq.d/` |
| The web UI does not load | `pveproxy` is down, or the firewall | `systemctl status pveproxy` |
| The web UI loads but changes do not save | The cluster has no quorum | `pvecm status` |
| A migration is refused | The disk is local | `qm config <id> \| grep scsi0` |
| The backup fails | The guest agent is missing | `qm guest cmd <id> ping` |
| The guest is slow | The storage is full, or the CPU is limited | `pvesm status`, `qm config <id>` |
| The node is unreachable | The bridge took the management IP | `ip a` on the serial console |

## 6. The forensic discipline

For an incident, the order is:

1. **Preserve.** Snapshot the guest before you touch it. The snapshot is
   your evidence.
2. **Contain.** Isolate the guest with a firewall rule - do not shut it
   down. A shutdown destroys the volatile state in memory.
3. **Diagnose.** Work the decision tree.
4. **Eradicate.** Remove the artifact, patch the cause.
5. **Recover.** Restore from a known-clean backup, not from the
   compromised disk.
6. **Review.** Write down what happened.

## 7. What you do

1. Break VM 100 deliberately.
2. Take the forensic snapshot.
3. Work the decision tree and identify the layer.
4. Repair the guest.
5. Verify that it works again.
6. Document the incident in the task log.

## 8. How it is checked

```bash
./exercise.sh
```

## 9. The reference

`solution.md`.
