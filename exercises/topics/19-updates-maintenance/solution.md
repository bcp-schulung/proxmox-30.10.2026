# Solution - Topic 19: Updates and Maintenance

**Topic ID:** `19-updates-maintenance`

> **Instructor material.**

---

## 1. The current state

```bash
pveversion
# proxmox-ve/9.2.3/8b3a4b2c1d0e9f8a7b6c5d4e3f2a1b0c

pveversion -v
```

```
proxmox-ve: 9.2.3
pve-manager: 9.2.3
pve-ha: 9.2.3
pve-cluster: 9.2.3
qemu-server: 9.2.3
pve-kernel: 7.0.14-1
pve-qemu-kvm: 9.2.3
proxmox-ve: 9.2.3
```

## 2. The repositories

```bash
ls /etc/apt/sources.list.d/
cat /etc/apt/sources.list.d/pve-no-subscription.list
```

Expected:

```
pve-no-subscription.list
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
```

### The `pvetest` repository

```bash
ls /etc/apt/sources.list.d/ | grep pvetest
```

An empty result is the goal. The `pvetest` repository carries packages that
have not been tested for production use:

```bash
deb http://download.proxmox.com/debian/pve trixie pvetest
```

A node with it configured will eventually install a package that breaks the
cluster - and it will do so at the worst possible moment.

> **With a subscription**, keep the enterprise repository and add the key
> to `/etc/apt/auth.conf.d/`:
> ```bash
> echo "https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg" \
>   > /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
> ```

## 3. The available updates

```bash
apt update
apt list --upgradable
```

```
Listing...
pve-manager/9.2.4-1~trixie1 amd64 [upgradable from: 9.2.3-1]
qemu-server/9.2.4-1~trixie1 amd64 [upgradable from: 9.2.3-1]
```

## 4. Is a reboot needed?

```bash
# The running kernel
uname -r
# 7.0.14-1-pve

# The installed kernels
dpkg -l | grep pve-kernel
# ii  pve-kernel: 7.0.14-1
```

If the installed kernel is newer than the running one, a reboot is needed.

```bash
# The comparison
[ "$(uname -r)" = "$(dpkg-query -W -f='${Version}' pve-kernel | cut -d- -f1)-pve" ] \
  && echo "no reboot needed" || echo "reboot needed"
```

In practice:

```bash
needs_reboot() {
    local running installed
    running="$(uname -r)"
    installed="$(dpkg-query -W -f='${Version}' pve-kernel 2>/dev/null | cut -d- -f1)"
    [ "${running}" != "${installed}-pve" ]
}

if needs_reboot; then
    echo "a reboot is needed"
else
    echo "no reboot needed"
fi
```

## 5. Apply the updates

```bash
apt full-upgrade -y
```

> **`apt full-upgrade` and not `apt upgrade`.** `apt upgrade` keeps the
> old packages around, and `full-upgrade` removes them. On a Proxmox node
> the old kernel has to go, or the next reboot asks a question about which
> kernel to boot.

Watch for the message that tells you a reboot is needed:

```
The following packages will be REMOVED:
  proxmox-ve-0.0-xxxx pve-kernel-7.0.13-1
```

## 6. The HA-aware reboot

```bash
# 1. Take the node out of the HA service
ha-manager crm-command node-maintenance enable pve1
```

```
requesting node maintenance for node 'pve1'
```

```bash
# 2. Wait until the resources have moved away
ha-manager status
```

```
Type     ID          Status    Last HA error
vm       100         started
node    pve1         maintenance
node    pve2         active
node    pve3         active
```

```bash
# 3. Reboot
reboot
```

```bash
# 4. After the node is back
ha-manager crm-command node-maintenance disable pve1
```

```bash
# 5. Verify
pveversion
uname -r
pvecm status
```

### The full cluster procedure

```bash
# On pve1
ha-manager crm-command node-maintenance enable pve1
apt update && apt full-upgrade -y
[ -n "$(apt list --upgradable 2>/dev/null | grep pve-kernel)" ] && reboot
ha-manager crm-command node-maintenance disable pve1

# Wait for pve1 to be back and healthy
pvecm status

# On pve2 - the same
# On pve3 - the same
```

**One node at a time.** With three nodes, one node at a time keeps the
quorum of 2.

### Why the maintenance mode

Without it, the reboot looks exactly like a node failure:

1. The CRM notices that the LRM is gone.
2. The fencing kicks in.
3. The CRM relocates the resources.
4. The node comes back, and the CRM has to move them back.

With the maintenance mode, the CRM knows that the node is coming back and
leaves the resources where they are.

## 7. The vulnerability check

```bash
# The security-relevant updates
apt-get --just-print upgrade 2>/dev/null | grep -iE 'security'

# The installed versions of the critical packages
dpkg -l | grep -E 'pve-manager|proxmox-ve|pve-kernel|qemu-server|openssl' | grep '^ii'

# The kernel
uname -r
```

### The patch SLA

From the security course:

> Define an explicit patch SLA - critical CVEs within 48 hours, others
> within the next maintenance window.

A policy that says "we will patch it eventually" is not a policy an auditor
accepts. The SLA has a number and an owner.

## 8. The reboot check

```bash
# Is a reboot pending?
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required
```

Proxmox does not use the Debian marker file, but it is a useful habit.

## 9. The complete sequence

```bash
# The state
pveversion -v
uname -r
dpkg -l | grep pve-kernel

# The repositories
ls /etc/apt/sources.list.d/
cat /etc/apt/sources.list.d/pve-no-subscription.list

# The updates
apt update
apt list --upgradable

# Apply
ha-manager crm-command node-maintenance enable pve1
apt full-upgrade -y

# The reboot, if the kernel changed
reboot

# After the reboot
ha-manager crm-command node-maintenance disable pve1
pveversion -v
uname -r
pvecm status
```

## 10. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `apt update` returns 401 | The enterprise repository without a subscription | Remove `pve-enterprise.list` |
| The cluster loses quorum during the upgrade | Two nodes were upgraded at once | One node at a time |
| The guests moved during a planned reboot | No maintenance mode | `ha-manager crm-command node-maintenance enable` |
| The kernel did not change after the reboot | The old kernel is still in the boot order | `proxmox-boot-status`, remove the old entry |
| `apt upgrade` left the old packages | `apt upgrade` instead of `full-upgrade` | Use `apt full-upgrade` |
| The node comes back with a broken cluster | It was rebooted while the cluster was not quorate | Check `pvecm status` first |

## 11. The rolling upgrade, as a script

```bash
#!/bin/bash
# Rolling upgrade of a Proxmox cluster, one node at a time.
set -euo pipefail

NODES="pve1 pve2 pve3"

for node in ${NODES}; do
    echo "=== ${node} ==="

    ssh "root@${node}" "ha-manager crm-command node-maintenance enable ${node}"

    ssh "root@${node}" "apt update && apt full-upgrade -y"

    if ssh "root@${node}" "apt list --upgradable 2>/dev/null | grep -q pve-kernel"; then
        echo "rebooting ${node}"
        ssh "root@${node}" "reboot" || true
        sleep 120
    else
        echo "no kernel change - no reboot needed"
    fi

    # Wait for the node to be back
    until ssh -o BatchMode=yes "root@${node}" "pvecm status | grep -q 'Quorate: *Yes'"; do
        sleep 10
    done

    ssh "root@${node}" "ha-manager crm-command node-maintenance disable ${node}"
    sleep 30
done

echo "the cluster is upgraded"
```
