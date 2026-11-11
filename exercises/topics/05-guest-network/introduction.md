# Topic 05 - The Guest Network

**Topic ID:** `05-guest-network`
**Course reference:** Proxmox VE Introduction, Day 1 §9 "Networking Basics"
**Duration:** 60 minutes
**Runs on:** all three nodes (the bridge is per node)

---

## 1. What you learn

Proxmox networking is Linux networking. A `vmbr0` is an ordinary Linux
bridge, a `tap100i0` is an ordinary tap device, and a container's `eth0` is
an ordinary veth pair. Nothing about it is magic - which is exactly why you
can reason about it with `ip`, `bridge` and `tcpdump`.

## 2. The three layers

```
   AWS VPC 10.20.0.0/16
      │
      ├── eth0 (10.20.0.41)   management, corosync, web UI, NFS, PBS
      │
      └── vmbr0 (10.10.10.1)  the guest overlay
            │
            ├── tap100i0   VM 100
            ├── tap101i0   VM 101
            └── veth300i0  CT 300
```

**The management interface is not bridged.** On real hardware the management
IP usually sits on `vmbr0` and the physical NIC is enslaved to the bridge.
In this lab `eth0` keeps the VPC address and `vmbr0` is a bridge *without* a
physical port.

The reason is AWS. AWS routes traffic to a network interface using the
addresses that belong to that interface. A Linux bridge takes a MAC address
of its own, and AWS drops traffic whose source MAC is not the one registered
on the ENI. A bridge that owns its own MAC address would take the node
offline - and you would have no way back in.

What this changes for you:

- the guest bridge has no wire to the outside world
- the node provides DHCP, routing and NAT for the guests
- everything else - VLAN tags, `bridge vlan show`, `bridge link` - behaves
  exactly as it does on hardware

## 3. One overlay subnet per node

| Node | Overlay | Gateway |
|---|---|---|
| pve1 | `10.10.10.0/24` | `10.10.10.1` |
| pve2 | `10.10.20.0/24` | `10.10.20.1` |
| pve3 | `10.10.30.0/24` | `10.10.30.1` |

If all three nodes used `10.10.10.0/24`, a guest on `pve1` sending to
`10.10.10.60` (a guest on `pve2`) would find the address directly connected
on its own `vmbr0`, answer the ARP itself, and the packet would never leave
the node. The per-node subnets make the routing between the nodes explicit.

## 4. The VLAN-aware bridge

```bash
auto vmbr0
iface vmbr0 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
```

`bridge-vlan-aware yes` is the switch to a VLAN-aware bridge. On such a
bridge, every port is a trunk port by default, and the untagged VLAN is
added explicitly:

```bash
bridge vlan show
```

```
port    vlan
vmbr0   1 PVID Egress Untagged
        10
```

Without `bridge-vlan-aware yes`, a single bridge can only carry one untagged
segment - and every VLAN would need its own bridge.

## 5. What the node provides

| Service | Where |
|---|---|
| DHCP | `dnsmasq`, bound to `vmbr0` |
| Routing | `net.ipv4.ip_forward` |
| NAT | `iptables -t nat -A POSTROUTING ... -j MASQUERADE` |
| DNS | `dnsmasq` forwards to the upstream resolver |

### The two RETURN rules

```bash
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -d 10.10.0.0/16 -j RETURN
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -d 10.20.0.0/16 -j RETURN
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
```

The two `RETURN` rules come **before** the masquerade. They say: traffic
inside the overlay and traffic to the VPC is not NATed.

Without them, a guest on `pve1` could not reach a guest on `pve2` at its own
address - the reply would come back to the masqueraded address and be
dropped.

## 6. What you do

On each node:

1. Configure the `vmbr0` bridge with the node's own overlay range.
2. Configure `dnsmasq` to serve DHCP on the bridge.
3. Add the routes to the other overlay subnets.
4. Install the NAT and forwarding rules.
5. Verify with `ip a`, `bridge vlan show` and `ip route`.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
