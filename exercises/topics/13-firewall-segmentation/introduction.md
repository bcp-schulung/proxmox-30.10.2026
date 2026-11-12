# Topic 13 - Firewall and Segmentation

**Topic ID:** `13-firewall-segmentation`
**Course reference:** Proxmox VE Security, Day 2 §2 and §3
**Duration:** 60 minutes
**Runs on:** one node

---

## 1. What you learn

Proxmox has three firewall levels, and they are evaluated in a fixed order:

```
   Datacenter Firewall        the cluster-wide policy and rules
        │
        ▼
   Node Firewall              /etc/pve/nodes/<node>/host.fw
        │
        ▼
   VM / CT Firewall           /etc/pve/firewall/<vmid>.fw
```

The most specific match wins, and the default policy of the level applies
when nothing matches.

| Level | File | Scope |
|---|---|---|
| Datacenter | `/etc/pve/cluster/firewall/cluster.fw` | The whole cluster |
| Node | `/etc/pve/nodes/<node>/host.fw` | One node |
| Guest | `/etc/pve/firewall/<vmid>.fw` | One guest |

## 2. Default deny

The rule of the day: **default deny inbound, explicit accept**.

```bash
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT
```

### The order matters

If you enable the default deny *before* writing the rules, you cut yourself
off. The node keeps the connection it already has, but any new connection is
dropped.

> **Write the rules first. Then enable the default deny. Then test.**
>
> And keep a second SSH session open while you test.

## 3. The three levels in practice

```bash
# The datacenter - the cluster-wide baseline
pvesh create /cluster/firewall/rules \
  --action ACCEPT --type in --dport 8006 --proto tcp --source 10.20.0.0/16

# The node - what reaches this node
pvesh create /nodes/pve1/hostfw/rules \
  --action ACCEPT --type in --dport 22 --proto tcp --source 10.20.0.0/16

# The guest - what reaches the workload
pvesh create /nodes/pve1/qemu/100/firewall/rules \
  --action ACCEPT --type in --dport 443 --proto tcp --source 10.10.20.0/24
```

The guest rules need the **node** name in the path, because the guest rules
are stored per node:

```bash
pvesh get /nodes/pve1/qemu/100/firewall/rules
pvesh get /nodes/pve2/qemu/100/firewall/rules
```

The same guest on a different node has a different rule set. That is not a
bug - the guest's traffic enters the cluster through the node it runs on.

## 4. Segmentation with VLANs

The firewall and the VLANs work together:

```bash
qm set 9201 --net0 virtio,bridge=vmbr0,tag=20
pct set 301 --net0 name=eth0,bridge=vmbr0,tag=40,ip=dhcp
```

```
   vmbr0 (VLAN aware)
      │
      ├── tag 20  web tier         10.10.20.0/24
      ├── tag 30  application tier 10.10.30.0/24
      └── tag 40  database tier    10.10.40.0/24
```

The firewall rules then refer to the tier's address range, and the range
only contains the tier. The rule does not have to know the guest's IP
address - it knows the tier.

```bash
# The web tier may reach the database
--source 10.10.20.0/24 --dport 5432
# The database may not reach the web
--source 10.10.20.0/24 --dport 443 --action DROP
```

## 5. The stale rule

> "An `ACCEPT ANY ANY` rule left over from initial testing is one of the
> most common real-world findings in a security review."

```bash
pvesh get /cluster/firewall/rules --output-format json | \
  jq -r '.[] | select(.source=="0.0.0.0/0" or .source=="::/0")'
```

An empty result is the goal.

## 6. What you do

1. Enable the datacenter firewall with a default deny.
2. Add the rules the cluster needs - SSH, the web UI, corosync, NFS, PBS.
3. Add the VLAN tags to the web and the database tiers.
4. Add the guest level rules that let the web tier reach the database tier -
   and only that direction.
5. Review the whole rule set for stale, overly broad rules.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
