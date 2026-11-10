#!/bin/bash
# =============================================================================
# 20-proxmox-install.sh - Packer build step: the Proxmox VE packages
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# Preseed postfix so the install does not stop on a dialog.
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string proxmox.seminar.local" | debconf-set-selections

# ifupdown2 replaces ifupdown and gives us ifreload -a for live changes.
# It is installed here but networking.service stays DISABLED in the AMI: until
# the bootstrap switches the network over, systemd-networkd owns eth0 and the
# instance needs its IP to boot.
apt-get install -y proxmox-ve postfix open-iscsi chrony ifupdown2

# Without a subscription the enterprise repository answers 401 on every
# apt update, which breaks unattended upgrades.
if [ -f /etc/apt/sources.list.d/pve-enterprise.sources ]; then
    sed -i 's/^Enabled: yes/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources
fi
if [ -f /etc/apt/sources.list.d/ceph.sources ]; then
    sed -i 's/^Enabled: yes/Enabled: false/' /etc/apt/sources.list.d/ceph.sources
fi

# The installer leaves a pending network file behind. pvenetcommit would move
# it over /etc/network/interfaces at the next boot and silently destroy the
# bridge configuration the bootstrap writes.
rm -f /etc/network/interfaces.new

# The Proxmox kernel replaces the Debian kernel - keeping both leads to
# conflicts on point releases.
apt-get remove -y linux-image-amd64 'linux-image-6.12*' os-prober || true
update-grub

# Keep systemd-networkd in charge of the network inside the AMI.
systemctl disable networking.service 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true
systemctl enable systemd-networkd-wait-online 2>/dev/null || true

# The Proxmox services must come up on the first boot.
systemctl enable pveproxy pvedaemon pvestatd pve-cluster

echo "proxmox packages installed"
