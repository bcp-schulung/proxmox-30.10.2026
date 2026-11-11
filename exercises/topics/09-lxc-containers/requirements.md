# Requirements - Topic 09: LXC Containers

**Topic ID:** `09-lxc-containers`

---

## The template

- [ ] A container template for Debian 13 exists in the shared storage.
- [ ] The template is listed by `pvesm list nfs-lab --content vztmpl`.

## The three containers

For each of `300 app01`, `301 db01` and `302 cache01`:

- [ ] The container exists.
- [ ] Its hostname is correct.
- [ ] It is **unprivileged** (`unprivileged: 1`).
- [ ] It has `nesting=1` in its features.
- [ ] Its rootfs is on the shared storage `nfs-lab`.
- [ ] Its network is on `vmbr0` with the correct VLAN tag.
- [ ] It is running.

| Container | Hostname | VLAN | Tier |
|---|---|---|---|
| 300 | `app01` | 30 | application |
| 301 | `db01` | 40 | database |
| 302 | `cache01` | 30 | operations |

## Inside the container

- [ ] `pct exec 300 -- cat /proc/version` shows the **host** kernel - the
      container has no kernel of its own.
- [ ] `pct exec 300 -- cat /proc/1/cgroup` shows a non-empty cgroup path -
      the container is limited by cgroups.
- [ ] `pct exec 300 -- ip -brief a` shows an address on the overlay.
- [ ] The guest agent is running inside the container.

---

## Notes

**The `/proc/version` check is the proof that a container is not a VM.** A
virtual machine shows its own kernel version. A container shows the host's.
That single line explains the entire difference between the two
technologies.

**The `unprivileged: 1` check is a security check.** A privileged container
maps the container's root to the host's root. A breakout from a privileged
container is a root shell on the hypervisor - and the hypervisor controls
every other guest. Since Proxmox VE 9 the default is unprivileged, and
there is no good reason to turn it off for a workload you control.
