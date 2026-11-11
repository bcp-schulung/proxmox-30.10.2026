#!/bin/bash
# =============================================================================
# 01-base.sh - Packer build step: base packages and cloud-init hardening
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# The apt calls are retried, because the link to the package mirrors
# occasionally drops and a plain apt invocation would abort the build.
apt_retry() {
    local attempt=1
    local max=5
    while [ "${attempt}" -le "${max}" ]; do
        echo "--- apt attempt ${attempt}/${max}: apt-get $* ---"
        if sudo apt-get -o Acquire::Retries=3 "$@"; then
            return 0
        fi
        echo "WARN: apt-get $* failed - retrying in 10 seconds"
        attempt=$((attempt + 1))
        sleep 10
    done
    echo "ERROR: apt-get $* failed after ${max} attempts"
    return 1
}

# The Debian cloud image ships with an unprivileged "admin" account. The
# harness logs in as that user, so it needs passwordless sudo.
if ! sudo grep -q '^admin ALL=' /etc/sudoers 2>/dev/null; then
    echo 'admin ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-lab-admin >/dev/null
    sudo chmod 440 /etc/sudoers.d/90-lab-admin
fi

apt_retry update
apt_retry -y upgrade
apt_retry install -y \
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
#
# The network configuration of cloud-init is disabled. The cloud-init
# network stage waits for the network to come up, and it hangs for over two
# minutes when there is no network file - which is exactly the situation
# in an AMI, because the netplan file of the build machine matches a MAC
# address that no instance has.
#
# The lab-network.sh script configures the network at every boot instead.
# It matches the interface by name, so that it works for every instance that
# is launched from the AMI.
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
