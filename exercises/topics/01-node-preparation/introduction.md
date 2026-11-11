# Topic 01 - Node Preparation

**Topic ID:** `01-node-preparation`
**Course reference:** Proxmox VE Introduction, Day 1, §4 "Installation & Initial
Configuration"
**Duration:** 45 minutes
**Runs on:** one node (`pve1`)

---

## 1. What you learn

A Proxmox VE node is a Debian system with a specific set of packages, a
specific repository layout and a specific set of services. Before a node can
join a cluster, three things have to be true:

1. it has the right **identity** - a hostname that resolves to its own
   address and not to a loopback address
2. it has the right **time** - corosync and the cluster certificates depend
   on it
3. it has the right **package sources** - an unlicensed node with the
   enterprise repository configured cannot run `apt update` at all

On top of that sits the **host firewall**, which is the first line of defence
and the first thing that can lock you out of your own node.

## 2. Why the identity matters

Proxmox refuses to start the `pve-cluster` service when the hostname
resolves to a loopback address. Debian's default `/etc/hosts` contains:

```
127.0.1.1   hostname
```

The Proxmox packages add a check for exactly this. The symptom is a node
that boots, has an address, answers `ping`, but never joins a cluster and
shows an endless restart of `pve-cluster` in `journalctl`.

The fix is to remove the loopback line and map the hostname to the node's real
address.

## 3. Why the time matters

Two things in the cluster break when the clock drifts:

- **Corosync.** The cluster members compare their clocks and drop a member
  whose drift exceeds a threshold. A node with a wrong clock leaves the
  cluster the moment it joins.
- **The cluster certificates.** The certificate authority and the node
  certificates carry validity periods. If the nodes disagree about the time,
  the certificates appear to be expired on one node and valid on another.

The threshold is surprisingly small - a few seconds is enough. A node whose
clock was never synchronised is the single most common cause of a cluster
join that fails for no visible reason.

## 4. The repositories

Proxmox ships three repository flavours:

| Repository | Stability | Cost |
|---|---|---|
| `enterprise` | Most tested, released later | Needs a subscription |
| `no-subscription` | Current, community tested | Free |
| `pvetest` | Bleeding edge | Free, never for production |

Without a subscription the `enterprise` repository returns HTTP 401 for every
package index. That breaks `apt update` completely - and on a node where
`apt update` is broken, unattended upgrades and the `pve-upgrade` tooling do
not work either.

## 5. The host firewall

Proxmox VE 9 ships with the `pve-firewall` service enabled and a default
inbound policy of `DROP`. A freshly installed node therefore drops every
inbound connection, including SSH, until the rules are written.

**The order is the whole point.** Write the rules first, then switch the
policy. If you do it the other way round, you lose the connection to the node
while you are setting it up.

```bash
# 1. The rules
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 22 --proto tcp --source "${OPERATOR}/32"

# 2. Only now the default deny
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP
```

The node-level firewall in `/etc/pve/nodes/<node>/host.fw` takes precedence
over the datacenter rules for traffic addressed to the node itself.

## 6. What you do

On `pve1`:

1. Set the hostname and fix `/etc/hosts`.
2. Synchronise the time and verify it.
3. Configure the `no-subscription` repository and remove the enterprise one.
4. Write the firewall rules for SSH and the web UI, then enable the default
   deny.
5. Verify every step.

## 7. How it is checked

```bash
./exercise.sh
```

The checks are the same ones the instructor runs. They cover the identity,
the clock, the repositories, the firewall policy and the firewall rules.

## 8. The reference

`solution.md` has the exact command sequence with the reasoning. Read it after
you have tried it yourself - the value is in the comparison.
