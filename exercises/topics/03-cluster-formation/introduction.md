# Topic 03 - Cluster Formation

**Topic ID:** `03-cluster-formation`
**Course reference:** Proxmox VE Introduction, Day 1, §6 "Datacenter, Node &
Cluster Concepts"
**Duration:** 60 minutes
**Runs on:** all three nodes

---

## 1. What you learn

A single Proxmox VE node is a fully functional hypervisor. Joining nodes into
a cluster adds three things:

1. **A shared configuration** - `/etc/pve` becomes a replicated database
2. **Live migration** - a guest can move between the nodes
3. **High availability** - a guest can be restarted on another node

And it costs one thing: **quorum**.

## 2. The quorum

Corosync implements a quorum-based membership protocol. The cluster needs a
majority of its members to agree before it accepts configuration changes.

| Cluster size | Quorum | A node failure |
|---|---|---|
| 1 | 1 | the node is gone, the cluster is gone |
| 2 | 2 | **any** failure loses quorum - this size is a mistake |
| 3 | 2 | one node can fail, the cluster survives |
| 4 | 3 | one node can fail |
| 5 | 3 | two nodes can fail |

A two node cluster is the classic beginner mistake. The moment one node
fails, the survivor loses quorum, `pmxcfs` goes read-only, and the
configuration is frozen. A three node cluster survives the loss of one node.

## 3. The two addresses

Each member has two addresses in the cluster:

- the **link address** (`link0`) - the address the members use to talk to
  each other. Corosync runs over UDP 5405-5412 on it.
- the **ring address** (`ring0`) - the address the members use to vote. It
  has to be on the same subnet for every member, because the members
  exchange votes directly.

In the lab, the link address and the ring address are the VPC address of
the node on `eth0`.

## 4. The join

```bash
# On the first node
pvecm create prod-cluster --link0 10.20.0.41

# On the second node
pvecm add 10.20.0.41 --link0 10.20.0.33 --use_ssh
```

`--use_ssh` makes the join authenticate over SSH instead of asking for the
root password of the seed node. It requires two things:

- the joining node has an SSH key
- the joining node knows the **host key** of the seed node

The second point is the one that catches everybody. A node that is not yet
in a cluster has no cluster filesystem, so it has no
`/etc/pve/priv/known_hosts`. The join fails with:

```
ERROR: Host key verification failed.
```

The fix is to fetch the host key from the seed node itself:

```bash
ssh-keyscan -T 10 -t rsa,ecdsa,ed25519 10.20.0.41 >> /root/.ssh/known_hosts
```

## 5. The fingerprint

`pvecm add` asks for the fingerprint of the cluster CA. It protects you
against joining the wrong cluster:

```
Please enter the fingerprint for the CA certificate: XX:XX:XX:...
```

You read it from the first node:

```bash
pvecm updatecerts --fingerprint
```

If the two do not match, you are about to join a different cluster - stop
and find out why.

## 6. What you do

1. Distribute the SSH host keys so the join can authenticate.
2. Create the cluster `prod-cluster` on `pve1`.
3. Join `pve2` and `pve3`.
4. Verify the quorum and the membership.
5. Demonstrate that the configuration is now shared.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
