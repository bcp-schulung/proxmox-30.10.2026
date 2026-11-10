#!/bin/bash
# =============================================================================
# 30-pve-finalize.sh - Packer build step: kernel, initramfs, GRUB, cleanup
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# initramfs - the root volume is an NVMe EBS device, so virtio_blk must be
# available before the root filesystem can be mounted.
# -----------------------------------------------------------------------------
cat > /etc/initramfs-tools/modules << 'EOF'
virtio_blk
virtio_net
virtio_scsi
virtio_pci
virtio_console
EOF
update-initramfs -u -k all

# -----------------------------------------------------------------------------
# GRUB - the serial console gives us a way in when SSH is not available yet.
# -----------------------------------------------------------------------------
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200n8"|' /etc/default/grub
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || \
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200n8"' >> /etc/default/grub
grep -q '^GRUB_TERMINAL=' /etc/default/grub || echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=5|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=5|' /etc/default/grub 2>/dev/null || true
grep -q '^GRUB_TIMEOUT=' /etc/default/grub || echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
update-grub

# The AMI must boot the Proxmox kernel. Only one kernel is left after the
# Debian kernel was removed, so entry 0 is the Proxmox one.
KERNEL_COUNT="$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)"
echo "installed kernels: ${KERNEL_COUNT}"
ls -1 /boot/vmlinuz-*
ls -1 /boot/initrd.img-*

# -----------------------------------------------------------------------------
# Services and leftovers
# -----------------------------------------------------------------------------
systemctl enable pveproxy pvedaemon pvestatd pve-cluster ssh chrony
systemctl disable networking.service 2>/dev/null || true

# The AWS cloud-init agent must not reconfigure the network.
systemctl enable cloud-init-local cloud-init cloud-config cloud-final 2>/dev/null || true

# Remove the leftover network file one final time.
rm -f /etc/network/interfaces.new

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
apt-get -y autoremove
apt-get -y clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*
rm -f /root/.ssh/known_hosts
history -c 2>/dev/null || true

echo "finalize complete"
