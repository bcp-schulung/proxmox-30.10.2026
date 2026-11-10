#!/bin/bash
# =============================================================================
# 40-pbs-install.sh - Packer build step: Proxmox Backup Server
# =============================================================================
# Follows https://pbs.proxmox.com/docs/installation.html
# PBS 4.x is based on Debian 13 (Trixie) and keeps the Debian kernel.
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

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

sudo apt-get update
sudo apt-get install -y proxmox-backup-server

# Without a subscription the enterprise repository returns 401 on every
# apt update.
if [ -f /etc/apt/sources.list.d/pbs-enterprise.sources ]; then
sudo sed -i 's/^Enabled: yes/Enabled: false/' /etc/apt/sources.list.d/pbs-enterprise.sources
fi

sudo systemctl enable proxmox-backup.service proxmox-backup-proxy.service

# The datastore directory lives on a dedicated EBS volume that is attached at
# launch time and mounted by the provisioning script.
sudo mkdir -p /var/lib/proxmox-backup/datastore

sudo apt-get -y autoremove
sudo apt-get -y clean
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /tmp/* /var/tmp/*
sudo rm -f /root/.ssh/known_hosts

echo "proxmox backup server installed"
