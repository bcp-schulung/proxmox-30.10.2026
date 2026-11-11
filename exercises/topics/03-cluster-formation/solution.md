# Solution - Topic 03: Cluster Formation

**Topic ID:** `03-cluster-formation`

> **Instructor material.**

---

## 1. Distribute the SSH keys

This has to happen **before** the join, on every node.

```bash
# On pve1, pve2 and pve3 - create a key if there is none
[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519

# On every node - collect the host keys of all three nodes
for n in 10.20.0.41 10.20.0.33 10.20.0.28; do
    ssh-keyscan -T 10 -t rsa,ecdsa,ed25519 "${n}" 2>/dev/null
done | sort -u >> /root/.ssh/known_hosts

# On every node - distribute the public keys, so the nodes can talk to
# each other over SSH without a password
for n in 10.20.0.41 10.20.0.33 10.20.0.28; do
    [ "${n}" = "$(hostname -I | awk '{print $1}')" ] && continue
    ssh-copy-id -i /root/.ssh/id_ed25519.pub root@"${n}" 2>/dev/null || true
done
```

Verify:

```bash
ls -la /root/.ssh/
grep -c "10.20.0" /root/.ssh/known_hosts
ssh -o BatchMode=yes root@10.20.0.33 'hostname'
```

### Why this is needed

`pvecm add --use_ssh` copies the cluster SSH key to the joining node over an
existing SSH connection. It uses `ssh-copy-id` under the hood, and that
command verifies the host key of the target. Without the key in
`known_hosts`, it refuses:

```
/usr/bin/ssh-copy-id: ERROR: Host key verification failed.
```

The cluster's own `known_hosts` file lives in `/etc/pve/priv/known_hosts`,
which only exists **after** the node is in a cluster. A joining node has a
plain file at `/root/.ssh/known_hosts` instead - which is why the key has to
be put there by hand.

## 2. Create the cluster

**On `pve1`:**

```bash
pvecm create prod-cluster --link0 10.20.0.41
```

Expected:

```
INFO: COROSYNC version ring 1.9f
INFO: Preparing Cluster Certificates
INFO: Cluster successfully created
```

### What `--link0` does

`link0` is the address the members use for the corosync traffic - the
heartbeat and the `pmxcfs` replication. It has to be an address the other
members can reach.

In this lab the management interface (`eth0`, `10.20.0.41`) carries it. The
guest overlay is **not** used for the cluster link: the overlay subnets
differ per node, and a cluster link that only works over the overlay would
break as soon as the routing between the nodes was misconfigured.

## 3. Read the fingerprint

**On `pve1`:**

```bash
pvecm updatecerts --fingerprint
```

```
Cluster fingerprint: XX:XX:XX:XX:...
```

Write it down. The joining nodes need it.

## 4. Join the second node

**On `pve2`:**

```bash
pvecm add 10.20.0.41 --link0 10.20.0.33 --use_ssh
```

```
Please enter the fingerprint for the CA certificate: XX:XX:XX:...
INFO: SSH key for root@10.20.0.41 already exists - ignoring
INFO: Adding node to the cluster
INFO: New node added to the cluster
```

## 5. Join the third node

**On `pve3`:**

```bash
pvecm add 10.20.0.41 --link0 10.20.0.28 --use_ssh
```

## 6. Verify

**On any node:**

```bash
pvecm status
```

```
Quorum information
------------------
    Nodes:             3
    Node ID:           0x00000001
    Ring ID:           1.9f
    Quorum:            2
    Flags:             Quorate
    Membership information
----------------------
    Node ID             Name                 State
    0x00000001         pve1 (10.20.0.41)     Member
    0x00000002         pve2 (10.20.0.33)     Member
    0x00000003         pve3 (10.20.0.28)     Member
```

```bash
pvecm nodes
```

### The flags

| Flag | Meaning |
|---|---|
| `Quorate` | The cluster has a majority - it accepts configuration changes |
| `Activity blocked` | The cluster is running but is not accepting changes |
| `Waiting for new configuration` | A configuration change is in flight |
| `Config change made, please restart local node` | The node has to be restarted to pick it up |

## 7. Demonstrate the shared configuration

**On `pve1`:**

```bash
echo "written on pve1" > /etc/pve/cluster-demo.txt
```

**On `pve2` and `pve3`:**

```bash
cat /etc/pve/cluster-demo.txt
```

Then clean up on any node:

```bash
rm /etc/pve/cluster-demo.txt
```

### What happens without quorum

Stop a node and watch the others:

```bash
pvecm status
```

With two of three members left, the quorum of 2 is still met. The cluster
survives the loss of one node - that is the whole point of three nodes.

With only one member left, the quorum is lost:

```
Flags:             Activity blocked
```

and `pmxcfs` goes read-only. Every configuration change fails. This is the
split-brain protection: a node that cannot reach a majority must not accept
changes, because it cannot know whether they were already made elsewhere.

## 8. The complete sequence

```bash
# On every node
ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
for n in 10.20.0.41 10.20.0.33 10.20.0.28; do
    ssh-keyscan -T 10 -t rsa,ecdsa,ed25519 "${n}" 2>/dev/null
done | sort -u >> /root/.ssh/known_hosts

# On pve1
pvecm create prod-cluster --link0 10.20.0.41
pvecm updatecerts --fingerprint      # note the fingerprint

# On pve2
pvecm add 10.20.0.41 --link0 10.20.0.33 --use_ssh

# On pve3
pvecm add 10.20.0.41 --link0 10.20.0.28 --use_ssh

# On any node
pvecm status
pvecm nodes
```

## 9. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `Host key verification failed` | The seed node's host key is unknown | `ssh-keyscan` into `/root/.ssh/known_hosts` |
| `The fingerprint does not match` | The wrong cluster, or a stale fingerprint | `pvecm updatecerts --fingerprint` on the seed node |
| `cannot create 2-node cluster with this IP` | A duplicate link address | Every node needs its own `--link0` |
| The join hangs at "Waiting for ring ID" | The UDP ports are blocked | Check the firewall rules for 5405-5412 |
| The node joins and immediately leaves | The clocks disagree | Synchronise the time before joining |
| `pmxcfs is read-only` | The cluster has no quorum | `pvecm status` - how many members are up? |
