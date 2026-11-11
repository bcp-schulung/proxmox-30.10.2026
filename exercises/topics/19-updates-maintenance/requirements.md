# Requirements - Topic 19: Updates and Maintenance

**Topic ID:** `19-updates-maintenance`

---

## The repository

- [ ] The `no-subscription` repository is configured.
- [ ] The `enterprise` repository is absent (unless the node is licensed).
- [ ] The `pvetest` repository is **not** configured - it must never be on a
      production node.

## The state

- [ ] `pveversion` reports the installed version.
- [ ] `pveversion -v` lists the installed packages.
- [ ] `apt update` completes without an error.
- [ ] There are no pending package updates that require a kernel change
      without the node having been rebooted - the running kernel matches the
      installed one.

## The maintenance procedure

- [ ] The `pve-ha` service is running on the node.
- [ ] The HA resources that run on this node can be relocated - the
      `ha-manager status` output lists the resources.
- [ ] The node's HA maintenance state can be read and set.

---

## Notes

**The kernel check is the interesting one.** A node that has been updated
but not rebooted is running the old kernel with the new user space. That
is a legitimate state - Proxmox deliberately allows it - but it means a
kernel level fix is not yet in effect. The check compares the running
kernel with the installed one.

**The `pvetest` check** is a policy check. The `pvetest` repository carries
packages that have not been tested for production. A node with `pvetest`
configured will eventually install a package that breaks the cluster.

**The HA checks** exist because the maintenance procedure depends on them.
A node that cannot be taken out of the HA service cannot be rebooted
safely.
