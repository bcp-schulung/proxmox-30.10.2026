# Solution - Topic 01: Node Preparation

**Topic ID:** `01-node-preparation`

> **Instructor material.** The exact command sequence.

---

## 1. The identity

```bash
hostnamectl set-hostname pve1

# Remove the loopback mapping. Proxmox refuses to start pve-cluster with it.
sed -i '/^127\.0\.1\.1/d' /etc/hosts

# Map the hostname to the node's own management address.
grep -q 'pve1' /etc/hosts || \
  echo "10.20.0.41 pve1 pve1.seminar.local pve1" >> /etc/hosts
```

Verify:

```bash
hostname
cat /etc/hosts
getent hosts pve1        # must return 10.20.0.41, never 127.0.1.1
```

### Why this is not optional

The Proxmox packages ship a check in `pve-cluster`:

```bash
# What the check looks for
getent hosts "$(hostname)" | grep -q '127\.0\.1\.1'
```

If the hostname resolves to a loopback address, the service refuses to start
and the node never becomes a cluster member. The symptom is confusing: the
node has an address, `ping` works, but `pvecm add` never gets anywhere and
`journalctl -u pve-cluster` shows a restart loop.

## 2. The time

```bash
timedatectl set-ntp true
timedatectl status

# The drift against the time source
chronyc tracking
```

Expected:

```
Reference ID    : A9FEA9FE (refid)
Stratum         : 3
Ref time (UTC)  : Tue Nov 10 09:12:44 2026
System time     : 0.000000123 seconds fast of NTP time
Leap status     : Normal
```

### What a large drift does

Corosync compares the member clocks against each other. A member that is
more than a few seconds out is considered unhealthy and is removed from the
ring. The result is a cluster that forms and then immediately falls apart
again.

The same clock also signs the cluster certificates. If `pve1` believes it is
in 2027 and `pve2` believes it is in 2026, the node certificates appear
expired on one side and the join fails with a TLS error that mentions
nothing about the time.

## 3. The repositories

```bash
cat > /etc/apt/sources.list.d/pve-no-subscription.list << 'EOF'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

rm -f /etc/apt/sources.list.d/pve-enterprise.list

apt update
```

Expected:

```
Get:1 http://download.proxmox.com/debian/pve trixie/pve-no-subscription amd64 Packages [117 kB]
Fetched 117 kB in 1s (117 kB/s)
Reading package lists... Done
```

### The 401

Without a subscription, the enterprise repository answers every request with
`HTTP/1.1 401 Unauthorized`. The symptom is:

```
E: Failed to fetch http://download.proxmox.com/debian/pve/dists/trixie/enterprise/binary-amd64/Packages
  401  Unauthorized
```

Every `apt` command then fails - not just the update. The node stops
receiving security patches, and `pveversion -v` cannot report whether the
installed packages are current.

> **With a subscription?** Keep the enterprise list and add the
> subscription key to `/etc/apt/auth.conf.d/`. The verification in this
> exercise expects the no-subscription repository, so remove the enterprise
> list if the node is unlicensed.

## 4. The host firewall

### The rules first

```bash
OPERATOR="203.0.113.10"     # the address the operator connects from
VPC="10.20.0.0/16"

# The operator
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 22    --proto tcp --source "${OPERATOR}/32" \
  --comment "SSH from the operator"

pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 8006  --proto tcp --source "${OPERATOR}/32" \
  --comment "web UI from the operator"

# The cluster itself
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport "5405:5412" --proto udp --source "${VPC}" \
  --comment "corosync and KNET"

pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 2049  --proto tcp --source "${VPC}" \
  --comment "NFS client"

pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 8007  --proto tcp --source "${VPC}" \
  --comment "Proxmox Backup Server"
```

### Then the default deny

```bash
pvesh set /cluster/firewall/options \
  --enable 1 --policy_in DROP --policy_out ACCEPT
```

### Then verify

```bash
pvesh get /cluster/firewall/options
pvesh get /cluster/firewall/rules
systemctl status pve-firewall --no-pager
```

> **Keep an SSH session open while you test.** If the rules turn out to be
> wrong, the second session is your way back in. On a node you can reach
> over the serial console or over the cloud console, this is less dramatic -
> but the habit is worth keeping.

### The node-level firewall

The datacenter rules apply to the forwarded traffic between the guests. The
traffic addressed to the node itself is handled by
`/etc/pve/nodes/<node>/host.fw`:

```bash
cat /etc/pve/nodes/$(hostname)/host.fw
```

The lab's node bootstrap already writes a correct set of rules there. If a
student replaced the file, restore it:

```bash
cat > /etc/pve/nodes/$(hostname)/host.fw << 'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
log_ratelimit: enable=1,burst=5,rate=1/second

[ALIASES]
LAB-VPC 10.20.0.0/16

[RULES]
IN ACCEPT -p tcp -d 10.20.0.0/16 --dport 22 -i eth0 -m comment --comment "SSH"
IN ACCEPT -p tcp -d 10.20.0.0/16 --dport 8006 -i eth0 -m comment --comment "web UI"
IN ACCEPT -p udp -d 10.20.0.0/16 --dport 5405:5412 -i eth0 -m comment --comment "corosync"
IN ACCEPT -p tcp -d 10.20.0.0/16 --dport 2049 -i eth0 -m comment --comment "NFS"
IN ACCEPT -p tcp -d 10.20.0.0/16 --dport 8007 -i eth0 -m comment --comment "PBS"
IN ACCEPT -p tcp -d 10.20.0.0/16 --dport 5900:5999 -i eth0 -m comment --comment "console"
IN ACCEPT -p icmp -d 10.20.0.0/16 -i eth0 -m comment --comment "ICMP"
EOF
systemctl restart pve-firewall
```

## 5. The platform health

```bash
pveversion -v | head -5
systemctl status pveproxy pvedaemon pvestatd --no-pager
```

Expected:

```
proxmox-ve/9.2.3/8b3a4b2c1d0e9f8a7b6c5d4e3f2a1b0c
```

## 6. The complete sequence

```bash
hostnamectl set-hostname pve1
sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo "10.20.0.41 pve1 pve1.seminar.local pve1" >> /etc/hosts

timedatectl set-ntp true

echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
rm -f /etc/apt/sources.list.d/pve-enterprise.list
apt update

pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 22 --proto tcp --source "${OPERATOR}/32"
pvesh create /cluster/firewall/rules --action ACCEPT --type in \
  --dport 8006 --proto tcp --source "${OPERATOR}/32"
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT
```

## 7. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `pve-cluster` restarts in a loop | The hostname resolves to `127.0.1.1` | Remove the loopback line from `/etc/hosts` |
| The join fails and the log mentions a certificate | The clocks disagree | Synchronise the time on every node |
| `apt update` returns 401 | The enterprise repository is still configured | Remove `pve-enterprise.list` |
| The node is unreachable after enabling the firewall | The policy was set before the rules | Write the rules first; recover over the serial console |
| The web UI is reachable but the API is not | Port 8006 is allowed, 8007 is not | Add the rule for 8007 |
