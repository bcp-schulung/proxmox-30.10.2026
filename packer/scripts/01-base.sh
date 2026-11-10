#!/bin/bash
# =============================================================================
# 01-base.sh - Packer build step: base packages and cloud-init hardening
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# The Debian cloud image ships with an unprivileged "admin" account. The
# harness logs in as that user, so it needs passwordless sudo.
if ! sudo grep -q '^admin ALL=' /etc/sudoers 2>/dev/null; then
    echo 'admin ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-lab-admin >/dev/null
    sudo chmod 440 /etc/sudoers.d/90-lab-admin
fi

sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y \
    ca-certificates curl wget gnupg \
    chrony qemu-guest-agent \
    initramfs-tools lvm2

# -----------------------------------------------------------------------------
# cloud-init must not fight the lab scripts.
#
#   manage_etc_hosts: false   - the bootstrap writes /etc/hosts itself with the
#                               node name mapped to its management IP. If
#                               cloud-init manages it, the Proxmox requirement
#                               "the hostname must not resolve to a loopback
#                               address" is violated on every boot.
#   preserve_hostname: true   - the bootstrap sets the node name.
#   network.config: disabled  - netplan/systemd-networkd keep configuring the
#                               interface until the bootstrap switches to
#                               ifupdown2.
# -----------------------------------------------------------------------------
sudo mkdir -p /etc/cloud/cloud.cfg.d
sudo tee /etc/cloud/cloud.cfg.d/99-pve-lab.cfg >/dev/null << 'EOF'
manage_etc_hosts: false
preserve_hostname: true
network:
  config: disabled
EOF

# Time synchronisation matters for corosync and the cluster certificates.
sudo tee /etc/chrony/chrony.conf >/dev/null << 'EOF'
pool 169.254.169.123 iburst minpoll 4 maxpoll 4
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
sudo systemctl enable chrony
sudo systemctl restart chrony

echo "base setup complete"
