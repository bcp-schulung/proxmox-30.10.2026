# Solution - Topic 13: Firewall and Segmentation

**Topic ID:** `13-firewall-segmentation`

> **Instructor material.**

---

## 1. The datacenter rules - FIRST

```bash
VPC="10.20.0.0/16"
OPERATOR="203.0.113.10"

# The operator
pvesh create /cluster/firewall/rules \
  --action ACCEPT --type in --dport 22   --proto tcp --source "${OPERATOR}/32" \
  --comment "SSH from the operator"

pvesh create /cluster/firewall/rules \
  --action ACCEPT --type in --dport 8006 --proto tcp --source "${OPERATOR}/32" \
  --comment "web UI from the operator"

# The cluster itself
pvesh create /cluster/firewall/rules \
  --action ACCEPT --type in --dport "5405:5412" --proto udp --source "${VPC}" \
  --comment "corosync and KNET"

pvesh create /cluster/firewall/rules \
  --action ACCEPT --type in --dport 2049 --proto tcp --source "${VPC}" \
  --comment "NFS client"

pvesh create /cluster/firewall/rules \
  --action ACCEPT --type in --dport 8007 --proto tcp --source "${VPC}" \
  --comment "Proxmox Backup Server"
```

## 2. THEN the default deny

```bash
pvesh set /cluster/firewall/options \
  --enable 1 --policy_in DROP --policy_out ACCEPT
```

> **Do not swap these two steps.** With the default deny first, the node
> drops every new connection - including the one you are using to fix it.
> The existing connection usually survives, but you do not want to find out
> on a remote node.

> **Keep a second SSH session open** while you test. If the first one dies,
> the second one is your way back.

## 3. Verify

```bash
pvesh get /cluster/firewall/options
pvesh get /cluster/firewall/rules
```

```json
[
  {
    "pos": 0,
    "type": "in",
    "action": "ACCEPT",
    "proto": "tcp",
    "dport": "22",
    "source": "203.0.113.10/32",
    "comment": "SSH from the operator"
  },
  ...
]
```

## 4. The node level

```bash
pvesh create /nodes/pve1/hostfw/rules \
  --action ACCEPT --type in --dport 22 --proto tcp --source "${VPC}" \
  --comment "SSH from the cluster"
```

The node firewall lives in `/etc/pve/nodes/pve1/host.fw`. It handles the
traffic that is addressed to the node itself - the SSH daemon, the web UI,
corosync.

## 5. The VLAN tags

```bash
# The web tier
qm set 9201 --net0 virtio,bridge=vmbr0,tag=20
qm set 9202 --net0 virtio,bridge=vmbr0,tag=20

# The application and the database tier
pct set 300 --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp
pct set 301 --net0 name=eth0,bridge=vmbr0,tag=40,ip=dhcp
```

> **A running guest.** Changing the network of a running guest normally
> needs a reboot, because the tag is applied when the tap device is
> created. Proxmox offers the change as a pending update:
> ```bash
> qm set 9201 --net0 virtio,bridge=vmbr0,tag=20 --pending 1
> qm pending 9201
> qm reboot 9201
> ```

Verify:

```bash
bridge vlan show
```

```
port    vlan
vmbr0   1 PVID Egress Untagged
        10
        20
        30
        40
```

## 6. The guest level rules

The guest rules are stored per node, because the traffic enters the cluster
through the node the guest runs on.

```bash
# The web tier reaches the database tier
pvesh create /nodes/pve1/qemu/100/firewall/rules \
  --action ACCEPT --type in --dport 5432 --proto tcp --source 10.10.20.0/24 \
  --comment "web tier -> database tier"

# The database tier does not reach the web tier
pvesh create /nodes/pve1/lxc/301/firewall/rules \
  --action DROP --type in --dport 443 --proto tcp --source 10.10.20.0/24 \
  --comment "database tier -> web tier denied"
```

Verify:

```bash
pvesh get /nodes/pve1/qemu/100/firewall/rules
cat /etc/pve/firewall/9201.fw
cat /etc/pve/firewall/301.fw
```

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -p tcp -s 10.10.20.0/24 --dport 5432 -i net0
```

> **The guest rules live in `/etc/pve/firewall/<vmid>.fw`** and are
> replicated by the cluster filesystem. The `pvesh` path needs the node
> name, the file does not.

## 7. The rule hygiene review

```bash
# The rules that accept from everywhere
pvesh get /cluster/firewall/rules --output-format json | \
  jq -r '.[] | select(.source=="0.0.0.0/0" or .source=="::/0") | .pos'

# The rules that accept everything
pvesh get /cluster/firewall/rules --output-format json | \
  jq -r '.[] | select(.dport==null and .dest==null) | .pos'

# All the guest rules
for f in /etc/pve/firewall/*.fw; do
    echo "== ${f}"
    cat "${f}"
done
```

An empty result from the first two queries is the goal.

### A stale rule in the wild

```
IN ACCEPT -p tcp -dport 8006                      <- accepts from everywhere
IN ACCEPT -p tcp -s 10.20.0.0/16 --dport 22      <- correct
IN ACCEPT -p udp -s 0.0.0.0/0 --dport 5405:5412 <- accepts from everywhere
```

The first and the third were left over from the initial setup. They are not
dangerous in this lab, but in a production cluster the third one would let
anyone on the internet reach the corosync port.

## 8. The complete sequence

```bash
# 1. The rules
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 22 --proto tcp --source "${OPERATOR}/32"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 8006 --proto tcp --source "${OPERATOR}/32"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport "5405:5412" --proto udp --source "${VPC}"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 2049 --proto tcp --source "${VPC}"

# 2. The default deny
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT

# 3. The VLAN tags
qm set 9201 --net0 virtio,bridge=vmbr0,tag=20
qm set 9202 --net0 virtio,bridge=vmbr0,tag=20
pct set 300 --net0 name=eth0,bridge=vmbr0,tag=30,ip=dhcp
pct set 301 --net0 name=eth0,bridge=vmbr0,tag=40,ip=dhcp

# 4. The guest rules
pvesh create /nodes/pve1/qemu/100/firewall/rules \
  --action ACCEPT --type in --dport 5432 --proto tcp --source 10.10.20.0/24
pvesh create /nodes/pve1/lxc/301/firewall/rules \
  --action DROP --type in --dport 443 --proto tcp --source 10.10.20.0/24

# 5. The review
pvesh get /cluster/firewall/rules
```

## 9. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The node is unreachable after enabling the firewall | The default deny came before the rules | Write the rules first; recover over the serial console |
| The web UI works but the cluster does not | The corosync ports are not allowed | Add the rule for UDP 5405-5412 |
| The guests lose the shared storage | The NFS port is not allowed | Add the rule for TCP 2049 |
| The rules do not have any effect | The guest firewall is enabled with its own default deny | Check `/etc/pve/firewall/<vmid>.fw` |
| The VLAN tag is set but the traffic still flows | The tag needs a reboot to take effect | `qm set ... --pending 1` and reboot |
| The guest rules are on the wrong node | The rules are per node | `pvesh create /nodes/pve2/qemu/100/firewall/rules` |

## 10. The design question for the students

> Which rules belong at the datacenter level and which belong on the guest?

The answer that a good design produces:

| Rule | Level | Why |
|---|---|---|
| SSH from the operator | Datacenter | It applies to every node |
| The web UI from the operator | Datacenter | Same |
| corosync between the nodes | Datacenter | It is cluster traffic |
| NFS to the storage | Datacenter | It applies to every node |
| The web tier reaches the database | Guest | It is a workload relationship |
| The database reaches nothing | Guest | It is a workload relationship |

A rule that belongs to the guest does not belong at the datacenter level,
because it would then apply to the cluster's own traffic as well.
