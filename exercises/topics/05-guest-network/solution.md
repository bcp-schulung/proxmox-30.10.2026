# Solution - Topic 05: The Guest Network

**Topic ID:** `05-guest-network`

> **Instructor material.**
>
> The overlay ranges and the management addresses:

| Node | Management | Overlay | Gateway | Route to pve2 | Route to pve3 |
|---|---|---|---|---|---|
| pve1 | `10.20.0.41` | `10.10.10.0/24` | `10.10.10.1` | `10.10.20.0/24 via 10.20.0.33` | `10.10.30.0/24 via 10.20.0.28` |
| pve2 | `10.20.0.33` | `10.10.20.0/24` | `10.10.20.1` | - | `10.10.30.0/24 via 10.20.0.28` |
| pve3 | `10.20.0.28` | `10.10.30.0/24` | `10.10.30.1` | `10.10.10.0/24 via 10.20.0.41` | - |

---

## 1. The bridge

**On each node.** The interface name and the ranges differ per node.

```bash
# On pve1
MGMT_IF=eth0
MGMT_IP=10.20.0.41
GUEST_CIDR=10.10.10.0/24
GUEST_GW=10.10.10.1
DHCP_START=10.10.10.100
DHCP_END=10.10.10.200
```

Write the configuration:

```bash
cat > /etc/network/interfaces << EOF
# Managed by the seminar lab.
auto lo
iface lo inet loopback

auto ${MGMT_IF}
iface ${MGMT_IF} inet static
    address ${MGMT_IP}/24
    gateway 10.20.0.1
    dns 169.254.169.253

auto vmbr0
iface vmbr0 inet static
    address ${GUEST_GW}/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes

source /etc/network/interfaces.d/*
EOF
```

### Validate before you apply

A broken `interfaces` file means the node comes back without a network - and
on a remote node that means it is gone:

```bash
ifup -s -a -i /root/interfaces.candidate
```

Then apply it:

```bash
ifreload -a
```

> **The `pvenetcommit` trap.** The GUI writes its own network file and
> leaves it as `/etc/network/interfaces.new`. `pvenetcommit` moves that file
> over `/etc/network/interfaces` at the next boot - silently destroying your
> configuration. The lab masks the service:
> ```bash
> systemctl mask pvenetcommit
> rm -f /etc/network/interfaces.new
> ```

## 2. The DHCP server

```bash
cat > /etc/dnsmasq.d/pve-lab.conf << EOF
interface=vmbr0
bind-dynamic
port=0
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
dhcp-option=option:router,${GUEST_GW}
dhcp-option=option:dns-server,${GUEST_GW},169.254.169.253
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

cat > /etc/dnsmasq.d/pve-lab-upstream.conf << EOF
server=169.254.169.253
no-resolv
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq
```

### The netmask has to be dotted

```bash
dhcp-range=10.10.10.100,10.10.10.200,255.255.255.0,12h     # correct
dhcp-range=10.10.10.100,10.10.10.200,24,12h                 # wrong
```

With the prefix length, dnsmasq rejects the line with `bad dhcp-range` and
the DHCP server silently hands out nothing.

## 3. The routes

```bash
# On pve1
ip route replace 10.10.20.0/24 via 10.20.0.33 dev eth0
ip route replace 10.10.30.0/24 via 10.20.0.28 dev eth0

# On pve2
ip route replace 10.10.10.0/24 via 10.20.0.41 dev eth0
ip route replace 10.10.30.0/24 via 10.20.0.28 dev eth0

# On pve3
ip route replace 10.10.10.0/24 via 10.20.0.41 dev eth0
ip route replace 10.10.20.0/24 via 10.20.0.33 dev eth0
```

### Make them persistent

An `ip route` command is lost at the next reboot. Put it in a systemd unit
or in `/etc/network/interfaces`:

```bash
cat > /etc/systemd/system/pve-lab-routes.service << 'EOF'
[Unit]
Description=Guest overlay routes for the seminar lab
After=network.target
Before=pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pve-lab-routes

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/sbin/pve-lab-routes << EOF
#!/bin/bash
ip route replace 10.10.20.0/24 via 10.20.0.33 dev eth0
ip route replace 10.10.30.0/24 via 10.20.0.28 dev eth0
EOF

chmod +x /usr/local/sbin/pve-lab-routes
systemctl enable pve-lab-routes
systemctl start pve-lab-routes
```

## 4. The NAT and the forwarding

```bash
cat > /usr/local/sbin/pve-lab-netfilter << 'EOF'
#!/bin/bash
# The guest overlay NAT and segmentation rules for the seminar lab.
set -u

GUEST_CIDR="${1:-10.10.10.0/24}"
UPLINK="${2:-eth0}"
OVERLAY_RANGE="${3:-10.10.0.0/16}"
VPC_CIDR="${4:-10.20.0.0/16}"

# --- filter ---
iptables -C FORWARD -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j ACCEPT
iptables -C FORWARD -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j DROP 2>/dev/null || \
    iptables -I FORWARD 2 -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j DROP
iptables -C FORWARD -s "${GUEST_CIDR}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 3 -s "${GUEST_CIDR}" -j ACCEPT
iptables -C FORWARD -d "${GUEST_CIDR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 4 -d "${GUEST_CIDR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -i vmbr0 -p udp --dport 67 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -i vmbr0 -p udp --dport 67 -j ACCEPT
iptables -C INPUT -i vmbr0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -i vmbr0 -p tcp --dport 53 -j ACCEPT

# --- nat ---
# Traffic inside the overlay and traffic to the VPC is not NATed.
iptables -t nat -C POSTROUTING -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j RETURN 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j RETURN
iptables -t nat -C POSTROUTING -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j RETURN 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j RETURN
iptables -t nat -C POSTROUTING -s "${GUEST_CIDR}" -o "${UPLINK}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${GUEST_CIDR}" -o "${UPLINK}" -j MASQUERADE

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.forwarding=1
EOF

chmod +x /usr/local/sbin/pve-lab-netfilter
/usr/local/sbin/pve-lab-netfilter 10.10.10.0/24 eth0 10.10.0.0/16 10.20.0.0/16
```

### Make it persistent

```bash
cat > /etc/systemd/system/pve-lab-netfilter.service << 'EOF'
[Unit]
Description=Guest overlay NAT and segmentation rules
After=network.target
Before=pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pve-lab-netfilter 10.10.10.0/24 eth0 10.10.0.0/16 10.20.0.0/16
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF

systemctl enable pve-lab-netfilter
```

## 5. Verify

```bash
# The bridge
ip -brief addr show vmbr0
bridge vlan show
bridge link

# The DHCP server
systemctl status dnsmasq --no-pager
cat /etc/dnsmasq.d/pve-lab.conf

# The routes
ip route | grep 10.10.

# The NAT
iptables -t nat -S POSTROUTING | grep -E 'RETURN|MASQUERADE'

# The forwarding
cat /proc/sys/net/ipv4/ip_forward
```

Expected on `pve1`:

```
$ ip -brief addr show vmbr0
vmbr0    UP    10.10.10.1/24    <BROADCAST,MULTICAST,UP,LOWER_UP>

$ ip route | grep 10.10
10.10.10.0/24 dev vmbr0 proto kernel scope link src 10.10.10.1
10.10.20.0/24 via 10.20.0.33 dev eth0
10.10.30.0/24 via 10.20.0.28 dev eth0

$ iptables -t nat -S POSTROUTING
-A POSTROUTING -s 10.10.10.0/24 -d 10.10.0.0/16 -j RETURN
-A POSTROUTING -s 10.10.10.0/24 -d 10.20.0.0/16 -j RETURN
-A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
```

## 6. The complete sequence per node

```bash
# The variables - they differ per node
MGMT_IF=eth0
MGMT_IP=10.20.0.41
GUEST_GW=10.10.10.1
DHCP_START=10.10.10.100
DHCP_END=10.10.10.200

# The bridge
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback
auto ${MGMT_IF}
iface ${MGMT_IF} inet static
    address ${MGMT_IP}/24
    gateway 10.20.0.1
auto vmbr0
iface vmbr0 inet static
    address ${GUEST_GW}/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
source /etc/network/interfaces.d/*
EOF
ifreload -a

# The DHCP server
cat > /etc/dnsmasq.d/pve-lab.conf << EOF
interface=vmbr0
bind-dynamic
port=0
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
dhcp-option=option:router,${GUEST_GW}
dhcp-option=option:dns-server,${GUEST_GW},169.254.169.253
EOF
systemctl restart dnsmasq

# The routes
ip route replace 10.10.20.0/24 via 10.20.0.33 dev eth0
ip route replace 10.10.30.0/24 via 10.20.0.28 dev eth0

# The NAT
/usr/local/sbin/pve-lab-netfilter 10.10.10.0/24 eth0 10.10.0.0/16 10.20.0.0/16
```

## 7. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The guest has no address | dnsmasq is not running, or the range is wrong | `systemctl status dnsmasq`, check the range |
| The guest has an address but no default route | The `dhcp-option=option:router` is missing | Add it and restart dnsmasq |
| The guest can ping the outside world but not the other nodes | The `RETURN` rules are missing | Add the two RETURN rules before the masquerade |
| The other nodes are unreachable | The routes are missing or point at the wrong address | `ip route` - the next hop must be a management address |
| `bridge vlan show` shows nothing | The bridge is not VLAN aware | Add `bridge-vlan-aware yes` and reload |
| The node loses its IP after a reboot | `pvenetcommit` overwrote the configuration | `systemctl mask pvenetcommit` |
| The guest cannot resolve anything | dnsmasq has no upstream | `server=169.254.169.253` in the upstream config |
