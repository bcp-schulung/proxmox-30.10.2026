# Topic 19 - Updates and Maintenance

**Topic ID:** `19-updates-maintenance`
**Course reference:** Proxmox VE Introduction, Day 3 §6 "Updates, Upgrades &
the Subscription Model"
**Duration:** 30 minutes
**Runs on:** one node (the procedure applies to all three)

---

## 1. What you learn

A Proxmox cluster is upgraded **one node at a time**, and the node has to
leave the HA service before it reboots.

## 2. The repositories

| Repository | Stability | Cost |
|---|---|---|
| `enterprise` | Most tested, released later | Requires a paid subscription |
| `no-subscription` | Current, community tested | Free |
| `pvetest` | Bleeding edge | Free, never for production |

The `pvetest` repository is for the people who want to test the next
release. It is explicitly not for production, and a package from it can
break the cluster.

## 3. The upgrade procedure

```bash
# 1. What is the current state?
pveversion -v

# 2. What is available?
apt update
apt list --upgradable

# 3. Check for a kernel change - this is what forces the reboot
pveversion | grep -o 'pve-manager/[0-9]*/[0-9a-z]*' 
```

### The order matters

```
   1. apt update && apt full-upgrade
   2. Did the kernel change?
        NO  -> the node is done, move to the next one
        YES -> drain the HA, reboot, wait, then move to the next node
   3. Only one node at a time
   4. The cluster stays quorate throughout
```

**Only one node at a time.** With three nodes, one node at a time keeps the
quorum. With two nodes, one node at a time means the cluster loses quorum
during the upgrade - and `pmxcfs` goes read-only.

## 4. The HA-aware reboot

```bash
# Before the reboot
ha-manager crm-command node-maintenance enable pve1
```

Wait until the resources have moved away:

```bash
ha-manager status
```

```bash
# The reboot
reboot
```

```bash
# After the node is back
ha-manager crm-command node-maintenance disable pve1
```

Without the maintenance mode, the reboot looks like a node failure and the
CRM restarts everything unnecessarily.

## 5. The update check

```bash
# What is installed
pveversion -v

# What is available
apt update && apt list --upgradable

# The PVE specific packages
dpkg -l | grep -E 'pve|proxmox' | grep '^ii'
```

## 6. The vulnerability angle

```bash
# The security-relevant updates
apt-get --just-print upgrade 2>/dev/null | grep -i security

# The installed versions
dpkg -l | grep -E 'pve-manager|proxmox-ve|pve-kernel|qemu-server'

# The kernel
uname -r
```

The patch policy from the security course:

> Define an explicit patch SLA - critical CVEs within 48 hours, others
> within the next maintenance window.

## 7. What you do

1. Check the installed version and the available updates.
2. Verify that the repository is the right one.
3. Apply the updates.
4. Determine whether a reboot is needed.
5. If it is, take the node out of the HA service, reboot, and put it back.

## 8. How it is checked

```bash
./exercise.sh
```

## 9. The reference

`solution.md`.
