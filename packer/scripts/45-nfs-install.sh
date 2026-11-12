#!/bin/bash
# =============================================================================
# 45-nfs-install.sh - build step: the shared NFS storage server
# =============================================================================
#
# The NFS server is a small Debian instance with an extra EBS volume that is
# exported over NFSv4. The Proxmox nodes mount it as the shared storage.
#
# The script runs as root inside the detached build step.
# =============================================================================
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# -----------------------------------------------------------------------------
# The NFS server
# -----------------------------------------------------------------------------
apt-get -o Acquire::Retries=3 update
# The kernel NFS server is what the seminar uses. It is the classic
# nfs-kernel-server package with NFSv4 support, which is what the Proxmox
# nodes mount.
apt-get -o Acquire::Retries=3 install -y nfs-kernel-server
rc=$?

systemctl enable nfs-server 2>/dev/null || true

# The export directory. The data volume is mounted over it at launch time.
mkdir -p /srv/nfs/lab

# -----------------------------------------------------------------------------
# The boot-time network configuration
#
# The Debian cloud image writes a netplan configuration that matches the MAC
# address of the machine the image was built on. Every instance that is
# launched from the AMI snapshot gets a different MAC address, so the match
# fails and the node has no network at all: no SSH, no SSM agent, and no
# NFS exports that the Proxmox nodes can mount.
#
# The script replaces it with a name-based match, and it runs at every boot.
# -----------------------------------------------------------------------------
install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-network.sh" /usr/local/sbin/lab-network.sh
install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-netcheck.sh" /usr/local/sbin/lab-netcheck.sh
install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-detached.sh" /usr/local/sbin/lab-detached

cat > /etc/systemd/system/lab-network.service << 'UNIT_EOF'
[Unit]
Description=Configure the management interface of the lab node
#
# The unit must not wait for network-online.target. That target waits for
# systemd-networkd-wait-online, which fails when there is no network file
# yet - and a unit that is ordered before that target is then never
# scheduled at all.
#
# The unit also must not order itself before the SSH server or the SSM
# agent. If this unit failed or hung, those services would never start and
# the node would be unreachable. The lab-netcheck service is the safety
# net that starts them.
After=systemd-networkd.service
Requires=systemd-networkd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lab-network.sh
# The script has to finish quickly. It writes the configuration and asks
# the network service to apply it - it does not wait for the address.
# The lab-netcheck service waits for the address and repairs the node if
# it never comes.
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/lab-netcheck.service << 'UNIT_EOF'
[Unit]
Description=Check that the node has a network and an SSH server
#
# The unit runs after the network configuration and repairs the node if
# something went wrong: no address, no SSH server, no SSM agent.
After=lab-network.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lab-netcheck.sh
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT_EOF

# -----------------------------------------------------------------------------
# Bake the network configuration into the image.
#
# systemd-networkd enumerates the links when it starts and matches every
# link against the .network files it knows. A file that is only written at
# runtime - in /run/systemd/network - is missing at that moment, so the
# interface stays DOWN and the boot waits for the network.
#
# The file is therefore written to /etc/systemd/network now, where it
# becomes part of the image. It matches every plausible name of the
# management interface, so it works for every instance type.
# -----------------------------------------------------------------------------
sudo mkdir -p /etc/systemd/network
sudo tee /etc/systemd/network/10-lab-network.network >/dev/null << 'NETWORKD_EOF'
[Match]
Name=en* eth* enp*

[Network]
DHCP=yes
IPv6AcceptRA=yes
IPv6UseDNS=yes

[DHCP]
RouteMetric=100
UseMTU=true
NETWORKD_EOF

# The netplan configuration of the build machine is removed: it holds the
# MAC address of the build machine, which matches no instance. The
# networkd file above is the configuration that every instance uses.
sudo rm -f /etc/netplan/*.yaml
sudo mkdir -p /etc/netplan
sudo tee /etc/netplan/10-lab-network.yaml >/dev/null << 'NETPLAN_EOF'
network:
  version: 2
  renderer: networkd
NETPLAN_EOF

systemctl daemon-reload
systemctl enable lab-network.service lab-netcheck.service
echo "the boot-time network units are installed"

# -----------------------------------------------------------------------------
# The SSM agent
#
# The SSM agent is the only way to reach a node from a network that does not
# allow inbound connections, so it must survive the cleanup below.
# -----------------------------------------------------------------------------
apt-get install -y --reinstall amazon-ssm-agent 2>/dev/null || apt-get install -y amazon-ssm-agent 2>/dev/null || true
apt-mark hold amazon-ssm-agent 2>/dev/null || true
systemctl enable amazon-ssm-agent

# -----------------------------------------------------------------------------
# DNS
# -----------------------------------------------------------------------------
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
fi
echo "resolv.conf configured"

# The stale netplan configuration of the build machine has to go.
rm -f /etc/netplan/*.yaml

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
apt-get -y autoremove
apt-get -y clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*
rm -f /root/.ssh/known_hosts
history -c 2>/dev/null || true

if [ ! -x /usr/bin/amazon-ssm-agent ]; then
    echo "ERROR: the SSM agent is missing from the AMI - the node would be unreachable"
    exit 1
fi
echo "the SSM agent is in place"

echo "the NFS server is installed"
exit "${rc}"
