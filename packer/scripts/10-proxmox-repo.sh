#!/bin/bash
# =============================================================================
# 10-proxmox-repo.sh - Packer build step: Proxmox repository and kernel
# =============================================================================
# Follows https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
# The official installer ISO cannot be used on EC2 - the Debian route is the
# supported way to install Proxmox VE on a cloud instance.
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# The Proxmox archive keyring for Debian Trixie.
wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -O /usr/share/keyrings/proxmox-archive-keyring.gpg
chmod 644 /usr/share/keyrings/proxmox-archive-keyring.gpg

# Verify the keyring against the published checksum.
echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" \
    | sha256sum -c -

cat > /etc/apt/sources.list.d/pve-install-repo.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt-get update
apt-get -y full-upgrade

# The Proxmox kernel has to be installed and booted before the Proxmox
# packages are installed - some packages depend on its kernel features.
apt-get install -y proxmox-default-kernel

# The kernel that is now installed must be able to boot the root volume.
# Make sure the virtio drivers are in the initramfs.
cat > /etc/initramfs-tools/modules << 'EOF'
virtio_blk
virtio_net
virtio_scsi
virtio_pci
virtio_console
EOF
update-initramfs -u -k all

echo "proxmox repository and kernel installed"
