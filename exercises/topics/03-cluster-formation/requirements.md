# Requirements - Topic 03: Cluster Formation

**Topic ID:** `03-cluster-formation`

---

## The cluster

- [ ] The cluster is called `prod-cluster`.
- [ ] `pvecm status` reports exactly 3 members.
- [ ] `pvecm status` reports `Quorate: Yes`.
- [ ] The quorum is 2.
- [ ] `pvecm nodes` lists `pve1`, `pve2` and `pve3`.
- [ ] All three members are in the state `Member`.

## The services

- [ ] `pve-cluster` is running on all three nodes.
- [ ] `corosync` is running on all three nodes.

## The SSH keys

- [ ] Every node has an SSH key in `/root/.ssh/`.
- [ ] Every node knows the host key of the other two nodes
      (`/root/.ssh/known_hosts`).

## The shared configuration

- [ ] `/etc/pve` is mounted as `fuse.pmxcfs` on all three nodes.
- [ ] A file written into `/etc/pve` on one node is visible on the other two
      nodes.
- [ ] The test file is removed again afterwards.

---

## Notes

**The host key check is not optional.** Without it the join fails with
`Host key verification failed`, and a student who does not understand why
will spend twenty minutes on it. The `known_hosts` file of a node that is
not yet clustered is a plain file in `/root/.ssh/`, and it is *not* the same
file as the cluster one in `/etc/pve/priv/known_hosts`.

**The "visible on the other nodes" check** is the one that proves the
cluster filesystem really works. It only passes on a quorate cluster - on a
cluster without quorum, `pmxcfs` goes read-only and the write fails.
