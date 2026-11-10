#!/bin/bash
# =============================================================================
# 01-base.sh - Packer build step: base packages and cloud-init hardening
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# The Debian cloud image ships with an unprivileged "admin" account. The
# harness logs in as that user, so it needs passwordless sudo.
if ! grep -q '^admin ALL=' /etc/sudoers 2>/dev/null; then
    echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-lab-admin
    chmod 440 /etc/sudoers.d/90-lab-admin
fi

apt-get update
apt-get -y upgrade
apt-get install -y \
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
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-pve-lab.cfg << 'EOF'
manage_etc_hosts: false
preserve_hostname: true
network:
  config: disabled
EOF

# Time synchronisation matters for corosync and the cluster certificates.
cat > /etc/chrony/chrony.conf << 'EOF'
pool 169.254.169.123 iburst minpoll 4 maxpoll 4
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable chrony
systemctl restart chrony

echo "base setup complete"
