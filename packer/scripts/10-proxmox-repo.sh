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
sudo wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -O /usr/share/keyrings/proxmox-archive-keyring.gpg
sudo chmod 644 /usr/share/keyrings/proxmox-archive-keyring.gpg

# Verify the keyring against the published checksum.
echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" \
    | sha256sum -c -

sudo tee /etc/apt/sources.list.d/pve-install-repo.sources >/dev/null << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

sudo apt-get update
sudo apt-get -y full-upgrade

# The Proxmox kernel has to be installed and booted before the Proxmox
# packages are installed - some packages depend on its kernel features.
#
# grub-pc fails on EC2. The instance boots from an NVMe EBS volume, and
# grub-pc cannot work out the install device on its own - it asks for it
# interactively ("You must correct your GRUB install devices before
# proceeding"), which fails the build in a non-interactive session.
#
# The Debian cloud image boots UEFI (grub-efi is already installed), so
# grub-pc is not needed at all. It only comes in as a dependency of
# proxmox-default-kernel. The cleanest fix is to let it install without
# writing anything to disk.
echo "grub-pc grub-pc/install_devices multiselect" | sudo debconf-set-selections
echo "grub-pc grub-pc/install_devices_empty boolean true" | sudo debconf-set-selections
echo "grub-pc grub-pc/force_confdef boolean true" | sudo debconf-set-selections
echo "grub-pc grub-pc/force_confold boolean true" | sudo debconf-set-selections
echo "grub-install device /dev/null" | sudo debconf-set-selections
echo "grub-install/install_to_multiboot boolean false" | sudo debconf-set-selections

sudo apt-get install -y proxmox-default-kernel || true

# grub-pc still fails on the NVMe volume. The image boots UEFI, so remove
# the BIOS boot loader and let dpkg continue - grub-efi is what actually
# boots the instance.
if sudo dpkg --audit 2>/dev/null | grep -q grub-pc; then
    echo "Removing grub-pc - the image boots UEFI"
    sudo dpkg --remove --force-all grub-pc >/dev/null 2>&1 || true
    sudo apt-get remove -y --purge grub-pc grub-pc-bin >/dev/null 2>&1 || true
    sudo dpkg --configure -a || true
fi

if sudo dpkg --audit 2>/dev/null | grep -q .; then
    echo "dpkg still reports problems:"
    sudo dpkg --audit
    exit 1
fi

# The kernel that is now installed must be able to boot the root volume.
# Make sure the virtio drivers are in the initramfs.
sudo tee /etc/initramfs-tools/modules >/dev/null << 'EOF'
virtio_blk
virtio_net
virtio_scsi
virtio_pci
virtio_console
EOF
sudo update-initramfs -u -k all

echo "proxmox repository and kernel installed"
