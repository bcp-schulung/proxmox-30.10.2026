# Solution - Topic 17: Troubleshooting

**Topic ID:** `17-troubleshooting`

> **Instructor material.**

---

## 1. Break a guest

The guest agent is the best thing to break, because it produces a realistic
symptom: the host cannot talk to the guest any more, but the guest is
running perfectly.

```bash
qm guest exec 9201 -- systemctl stop qemu-guest-agent
```

The symptom from the host:

```bash
qm guest cmd 9201 ping
# VM 9201 qemu-guest-agent is not running
```

## 2. Preserve the evidence - FIRST

```bash
qm snapshot 9201 incident --description "guest agent not responding - before the diagnosis"
```

> **Do this before you diagnose.** A repair can overwrite the evidence. The
> snapshot is the only copy of the state as it was found.

## 3. Work the decision tree

### Step 1: guest or host?

```bash
qm status 9201
# status: running
```

The guest is running. Now, is the host healthy?

```bash
systemctl is-active pveproxy pvedaemon pvestatd
# active
# active
# active

pvesm status
# Name        Type     Status   ...
# local-lvm   lvm-thin active   ...
# nfs-lab     nfs      active   ...
# pbs-main    pbs      active   ...
```

The host is healthy. The problem is in the guest.

### Step 2: VM or CT?

```bash
qm status 9201
qm showcmd 9201 | head -5
```

The QEMU process is running with the right devices.

### Step 3: the guest agent

```bash
qm guest cmd 9201 ping
# VM 9201 qemu-guest-agent is not running
```

That is the diagnosis: the guest agent is stopped. The guest itself is
fine.

### The alternative route - the console

When the agent does not answer, you cannot use `qm guest exec`. Use the
console:

```bash
qm console 9201
# press escape twice to get to the login prompt
```

Or check the QEMU log:

```bash
qm guest cmd 9201 ping
qm set 9201 --delete agent       # not a fix - a way to test
```

### The host log, for completeness

```bash
journalctl -u pveproxy --since "10 min ago" --no-pager | tail -20
dmesg -T | tail -30
```

Nothing relevant on the host - which confirms the diagnosis.

## 4. Repair it

```bash
# The agent is stopped - start it again
qm guest exec 9201 -- systemctl start qemu-guest-agent
```

If the agent itself does not answer, you cannot run `qm guest exec`. Use the
console instead:

```bash
qm console 9201
# login, then:
systemctl start qemu-guest-agent
```

Or reboot the guest:

```bash
qm reboot 9201
```

## 5. Verify

```bash
qm guest cmd 9201 ping
# pong

qm guest exec 9201 -- systemctl is-active qemu-guest-agent
# active

qm guest exec 9201 -- hostname
qm guest exec 9201 -- systemctl --failed --no-legend
```

## 6. Document it

```bash
pvesh get /cluster/log --limit 100 --output-format json | \
  jq -r '.[] | select(.cmd | test("vms/9201")) | "\(.time | strftime("%Y-%m-%d %H:%M:%S")) \(.username) \(.cmd)"'
```

```
2026-11-10 10:02:11 root@pam qm snapshot 9201 incident --description guest agent not responding
2026-11-10 10:05:44 root@pam qm guest exec 9201 -- systemctl start qemu-guest-agent
```

### The write-up

```
Incident: the guest agent of debian13-run-pve1 (VM 9201) stopped responding
Layer:    guest (the host services, the storage and the cluster were healthy)
Evidence: the snapshot 'incident', taken before the repair
Diagnosis: qm guest cmd 9201 ping failed, qm status 9201 showed 'running',
           the host services were all active -> the fault was inside the guest
Fix:      systemctl start qemu-guest-agent inside the guest
Result:   qm guest cmd 9201 ping answers again
```

## 7. The other scenarios

### The guest does not boot

```bash
qm status 9201                     # stopped
qm config 9201 | grep '^boot:'     # order=scsi0
qm showcmd 9201 | head -5
qm console 9201                    # what does the console show?
```

| The console shows | The cause |
|---|---|
| The bootloader menu | The boot order is wrong |
| "No bootable device" | The disk is not attached, or the EFI disk is missing |
| A kernel panic | The disk was changed underneath a running guest |
| The PXE boot | The boot order points at the network |

### The guest has no network

```bash
qm guest exec 9201 -- ip -brief a
qm guest exec 9201 -- ip route
qm guest exec 9201 -- cat /etc/resolv.conf
```

```bash
# On the host
ip -brief addr show vmbr0
systemctl status dnsmasq
grep dhcp-range /etc/dnsmasq.d/pve-lab.conf
```

| The observation | The cause |
|---|---|
| No address at all | dnsmasq is down, or the range is wrong |
| An address, no default route | The `option:router` is missing |
| An address, no DNS | The `option:dns-server` is missing, or the upstream is unreachable |

### The web UI does not load

```bash
systemctl status pveproxy --no-pager
ss -tlnp | grep 8006
pvesh get /cluster/firewall/options
```

### The changes do not save

```bash
pvecm status
```

Without quorum, `pmxcfs` is read-only and every configuration change fails
with a lock timeout. This is the single most common "the Proxmox UI is
broken" cause in a cluster.

### The migration is refused

```bash
qm config 9201 | grep scsi0
```

```
migrate VMs with local disks are not supported
```

The disk is on `local-lvm`. Move it to the shared storage.

## 8. The full IR cycle, for the students

```
   Detect      the SIEM alert or the user report
      │
      ▼
   Contain     isolate the node or the guest with a firewall rule -
      │        do NOT shut it down, that destroys the memory state
      ▼
   Preserve    snapshot the guest, copy the logs
      │
      ▼
   Diagnose    work the decision tree - guest or host?
      │
      ▼
   Eradicate   remove the malicious artifact, patch the cause
      │
      ▼
   Recover     restore from a known-clean backup, not from the
      │        compromised disk; revoke the tokens, rotate the credentials
      ▼
   Review      write it down, and change the process so it does not
                happen again
```

## 9. The complete sequence

```bash
# Break it
qm guest exec 9201 -- systemctl stop qemu-guest-agent

# Preserve
qm snapshot 9201 incident --description "guest agent not responding - before the diagnosis"

# Diagnose
qm status 9201
systemctl is-active pveproxy pvedaemon pvestatd
pvesm status
qm guest cmd 9201 ping

# Repair
qm guest exec 9201 -- systemctl start qemu-guest-agent

# Verify
qm guest cmd 9201 ping
qm guest exec 9201 -- systemctl is-active qemu-guest-agent

# Document
pvesh get /cluster/log --limit 100 --output-format json | \
  jq -r '.[] | select(.cmd | test("vms/9201")) | .cmd'
```

## 10. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The guest cannot be reached with `qm guest exec` | The agent is down | Use the console, or `qm reboot` |
| The repair destroyed the evidence | The snapshot was taken afterwards | Always snapshot first |
| The cluster was blamed for a guest problem | The decision tree was skipped | Check `qm status` and the host services first |
| The guest was shut down during an incident | Containment used a shutdown | Use a firewall rule to isolate it |
| The fix was never verified | The repair was assumed | Always verify with a functional test |
