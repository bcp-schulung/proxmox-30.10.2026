#!/bin/bash
# =============================================================================
# 40-pbs-install.sh - build step: Proxmox Backup Server
# =============================================================================
#
# Follows https://pbs.proxmox.com/docs/installation.html
# PBS 4.x is based on Debian 13 (Trixie) and keeps the Debian kernel.
#
# The script runs as root inside the detached build step.
# =============================================================================
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

sudo wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -O /usr/share/keyrings/proxmox-archive-keyring.gpg
sudo chmod 644 /usr/share/keyrings/proxmox-archive-keyring.gpg

echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" \
    | sha256sum -c -

sudo tee /etc/apt/sources.list.d/pbs.sources >/dev/null << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt-get -o Acquire::Retries=3 update

# Without a subscription the enterprise repository returns 401 on every
# apt update.
if [ -f /etc/apt/sources.list.d/pbs-enterprise.sources ]; then
sed -i 's/^Enabled: yes/Enabled: false/' /etc/apt/sources.list.d/pbs-enterprise.sources
fi

apt-get -o Acquire::Retries=3 install -y proxmox-backup-server
rc=$?

sudo systemctl enable proxmox-backup.service proxmox-backup-proxy.service

# The datastore directory lives on a dedicated EBS volume that is attached at
# launch time and mounted by the provisioning script.
sudo mkdir -p /var/lib/proxmox-backup/datastore

# -----------------------------------------------------------------------------
# The boot-time network configuration
#
# The Debian cloud image writes a netplan configuration that matches the MAC
# address of the machine the image was built on. Every instance that is
# launched from the AMI snapshot gets a different MAC address, so the match
# fails and the node has no network at all: no SSH, no SSM agent, no NFS
# exports that the Proxmox nodes can mount.
#
# The script replaces it with a name-based match, and it runs at every boot.
# -----------------------------------------------------------------------------
sudo install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-network.sh" /usr/local/sbin/lab-network.sh
install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-netcheck.sh" /usr/local/sbin/lab-netcheck.sh

sudo tee /etc/systemd/system/lab-network.service >/dev/null << 'UNIT_EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable lab-network.service lab-netcheck.service
echo "the boot-time network unit is installed"

# -----------------------------------------------------------------------------
# The SSM agent
#
# The SSM agent is the only way to reach a node from a network that does not
# allow inbound connections, so it must survive the cleanup below.
# -----------------------------------------------------------------------------
apt-get install -y --reinstall amazon-ssm-agent 2>/dev/null || apt-get install -y amazon-ssm-agent 2>/dev/null || true
apt-mark hold amazon-ssm-agent 2>/dev/null || true
sudo systemctl enable amazon-ssm-agent

# -----------------------------------------------------------------------------
# DNS
#
# The Proxmox packages replace the Debian networking stack with ifupdown2,
# and systemd-resolved then no longer has a usable stub resolver. The
# consequence is an empty /etc/resolv.conf, so that no name resolves.
# -----------------------------------------------------------------------------
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    sudo rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' | sudo tee /etc/resolv.conf >/dev/null
    sudo chmod 644 /etc/resolv.conf
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

echo "proxmox backup server installed"
exit "${rc}"
