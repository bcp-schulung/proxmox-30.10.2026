# Requirements - Topic 02: The Platform Architecture

**Topic ID:** `02-platform-architecture`

---

## The services

- [ ] `pveproxy` is running and listening on port 8006.
- [ ] `pvedaemon` is running.
- [ ] `pvestatd` is running.
- [ ] `pve-cluster` is running.
- [ ] `corosync` is running.
- [ ] The Proxmox API answers on `https://<node>:8006/api2/json/version`.

## The cluster filesystem

- [ ] `/etc/pve` is mounted as `fuse.pmxcfs`.
- [ ] The directory `/etc/pve/qemu-server` exists and contains the VM
      configurations.
- [ ] The directory `/etc/pve/lxc` exists.
- [ ] `/etc/pve/storage.cfg` exists and is readable.
- [ ] `/etc/pve/priv` exists and is **not** world readable.

## The three ways to do the same thing

- [ ] `qm list` returns the guest list.
- [ ] `pvesh get /nodes/<node>/qemu` returns the same guests.
- [ ] `pvesh get /cluster/resources --type vm` returns the same guests.
- [ ] The two ways agree on the number of guests.

## The replication

- [ ] A file written into `/etc/pve` on one node is visible on the other
      nodes within a second.
- [ ] The file is removed again afterwards - the exercise does not leave
      rubbish in the cluster configuration.

## The QEMU process

- [ ] At least one guest is running.
- [ ] `qm showcmd <vmid>` prints a QEMU command line.
- [ ] A process matching that command line exists in the process list.

---

## Notes

**The `/etc/pve/priv` check is a security check.** The directory holds the
cluster keys, the storage passwords and the API token secrets. It is a
FUSE mount with stricter permissions than a normal directory - `priv/` is
not replicated in a readable form, and it is only readable on the node that
holds the relevant secret. If it were world readable, every guest of the
cluster would be one `cat` away from the storage credentials.

**The replication check is the one that proves the cluster works.** It is
also the check that fails most often when the cluster is not quorate.
