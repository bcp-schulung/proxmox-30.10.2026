#!/bin/bash
# =============================================================================
# 10-proxmox-repo.sh - build step: the Proxmox repository and kernel
# =============================================================================
# Follows https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
# The official installer ISO cannot be used on EC2 - the Debian route is the
# supported way to install Proxmox VE on a cloud instance.
#
# The script is called by build-runner.sh. It runs the package downloads
# detached on the instance, so that a drop of the SSH connection does not
# abort the build, and waits for the result.
# =============================================================================
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG="/var/log/pve-kernel.log"
MARKER="/var/log/pve-kernel.rc"

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

# -----------------------------------------------------------------------------
# The kernel install, detached on the instance.
# -----------------------------------------------------------------------------
cat > /tmp/pve-kernel-step.sh << 'KERNEL_EOF'
#!/bin/bash
set -x
export DEBIAN_FRONTEND=noninteractive

apt-get -o Acquire::Retries=3 update
rc=$?

apt-get -o Acquire::Retries=3 -y full-upgrade
rc=$?

# grub-pc fails on EC2. The instance boots from an NVMe EBS volume, and
# grub-pc cannot work out the install device on its own - it asks for it
# interactively ("You must correct your GRUB install devices before
# proceeding"), which fails the build in a non-interactive session.
#
# The Debian cloud image boots UEFI (grub-efi is already installed), so
# grub-pc is not needed at all. It only comes in as a dependency of
# proxmox-default-kernel. The cleanest fix is to let it install without
# writing anything to disk.
echo "grub-pc grub-pc/install_devices multiselect" | debconf-set-selections
echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections
echo "grub-pc grub-pc/force_confdef boolean true" | debconf-set-selections
echo "grub-pc grub-pc/force_confold boolean true" | debconf-set-selections
echo "grub-install device /dev/null" | debconf-set-selections
echo "grub-install/install_to_multiboot boolean false" | debconf-set-selections

apt-get -o Acquire::Retries=3 install -y proxmox-default-kernel || true

# grub-pc still fails on the NVMe volume. The image boots UEFI, so remove
# the BIOS boot loader and let dpkg continue - grub-efi is what actually
# boots the instance.
if dpkg --audit 2>/dev/null | grep -q grub-pc; then
    echo "Removing grub-pc - the image boots UEFI"
    dpkg --remove --force-all grub-pc >/dev/null 2>&1 || true
    apt-get remove -y --purge grub-pc grub-pc-bin >/dev/null 2>&1 || true
    dpkg --configure -a || true
fi

if dpkg --audit 2>/dev/null | grep -q .; then
    echo "dpkg still reports problems:"
    dpkg --audit
    rc=1
fi

# The kernel that is now installed must be able to boot the root volume.
# Make sure the virtio drivers are in the initramfs.
cat > /etc/initramfs-tools/modules << 'MODULES_EOF'
virtio_blk
virtio_net
virtio_scsi
virtio_pci
virtio_console
MODULES_EOF
update-initramfs -u -k all

# -----------------------------------------------------------------------------
# Boot the Proxmox kernel
#
# The Debian cloud image uses a single generic GRUB entry ("Debian GNU/Linux")
# that points at the newest installed kernel. The Proxmox kernel is therefore
# not selectable on its own - the Debian kernels have to go, so that the
# entry points at the Proxmox one.
#
# The Debian kernels are removed and GRUB is regenerated, so that the
# instance boots the Proxmox kernel after the reboot.
# -----------------------------------------------------------------------------
echo "removing the Debian kernels so that GRUB boots the Proxmox kernel"
apt-get remove -y --purge 'linux-image-6.12*' 'linux-image-amd64' os-prober || true
dpkg --configure -a || true

update-grub
echo "the kernels in the GRUB menu:"
grep -E "^menuentry" /boot/grub/grub.cfg

# The Proxmox kernel has to be in the menu, otherwise the instance would
# come back on the Debian kernel.
if ! grep -q "pve" /boot/grub/grub.cfg; then
    echo "ERROR: the Proxmox kernel is not in the GRUB menu"
    ls -1 /boot/vmlinuz-*
    rc=1
fi

# The Proxmox kernel has to be the default entry.
sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub
grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=0' >> /etc/default/grub

echo "the kernel step finished with ${rc}"
printf '%s' "${rc}" > /var/log/pve-kernel.rc
KERNEL_EOF

sudo chmod +x /tmp/pve-kernel-step.sh
sudo rm -f "${MARKER}" "${LOG}"

# The redirection has to go through sudo as well: the shell opens the log
# file before sudo runs, and /var/log is not writable by the admin user.
sudo sh -c "nohup setsid /tmp/pve-kernel-step.sh > '${LOG}' 2>&1 &"
sleep 3

echo "The Proxmox kernel install runs in the background on the instance."
echo "Log: ${LOG}"

# Wait for the result.
DEADLINE=$(( $(date +%s) + 2400 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    if sudo test -s "${MARKER}"; then
        rc="$(sudo cat "${MARKER}")"
        echo "--- the kernel step finished with exit status ${rc} ---"
        if [ "${rc}" != "0" ]; then
            sudo tail -40 "${LOG}" || true
            exit 1
        fi
        exit 0
    fi
    sudo tail -2 "${LOG}" 2>/dev/null || true
    sleep 15
done

echo "ERROR: the kernel install did not finish in time"
sudo tail -40 "${LOG}" || true
exit 1
