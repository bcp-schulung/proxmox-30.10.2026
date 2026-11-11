#!/bin/bash
# =============================================================================
# 30-pve-finalize.sh - build step: kernel, initramfs, GRUB, firewall, cleanup
# =============================================================================
#
# The script is called by build-runner.sh and runs as root.
# =============================================================================
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# -----------------------------------------------------------------------------
# initramfs - the root volume is an NVMe EBS device, so virtio_blk must be
# available before the root filesystem can be mounted.
# -----------------------------------------------------------------------------
cat > /etc/initramfs-tools/modules << 'MODULES_EOF'
virtio_blk
virtio_net
virtio_scsi
virtio_pci
virtio_console
MODULES_EOF
update-initramfs -u -k all

# -----------------------------------------------------------------------------
# GRUB - the serial console gives us a way in when SSH is not available yet.
# -----------------------------------------------------------------------------
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200n8"|' /etc/default/grub
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || \
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200n8"' >> /etc/default/grub
grep -q '^GRUB_TERMINAL=' /etc/default/grub || echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=5|' /etc/default/grub
grep -q '^GRUB_TIMEOUT=' /etc/default/grub || echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
update-grub

# The AMI must boot the Proxmox kernel. Only one kernel is left after the
# Debian kernel was removed, so entry 0 is the Proxmox one.
echo "installed kernels:"
ls -1 /boot/vmlinuz-*
ls -1 /boot/initrd.img-*

# -----------------------------------------------------------------------------
# The Proxmox host firewall
#
# Proxmox VE 9 ships with pve-firewall enabled and the default host policy
# for INPUT set to DROP. A node that has just been installed therefore drops
# every inbound connection - including SSH.
#
# The firewall is masked in the AMI, so that the node is reachable from the
# first boot. The rule file is still written here, so that the bootstrap
# only has to unmask the service and restart it.
# -----------------------------------------------------------------------------
FW_DIR="/etc/pve/nodes/$(hostname)"
mkdir -p "${FW_DIR}"
cat > "${FW_DIR}/host.fw" << 'FW_EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
log_ratelimit: enable=1,burst=5,rate=1/second

[ALIASES]
# The VPC address range of the seminar lab.
LAB-VPC 10.20.0.0/16

[RULES]

# Accept everything from the lab VPC. The bootstrap replaces this with the
# final, port-specific rules.
IN ACCEPT -d LAB-VPC -m comment --comment "Everything from the lab VPC"

# Accept ICMP so that path MTU discovery works.
IN ACCEPT -p icmp -m comment --comment "ICMP"
FW_EOF

# The service stays masked - that is what makes the node reachable.
systemctl mask pve-firewall 2>/dev/null || true
systemctl stop pve-firewall 2>/dev/null || true
echo "host firewall configured in ${FW_DIR}/host.fw (pve-firewall is masked)"

# -----------------------------------------------------------------------------
# DNS
#
# The Proxmox packages replace the Debian networking stack with ifupdown2,
# and systemd-resolved then no longer has a usable stub resolver. The
# consequence is an empty /etc/resolv.conf, so no name resolves - which
# breaks apt and every other network operation.
#
# The VPC resolver (169.254.169.253) resolves both the internal service
# names and the public S3 endpoints.
# -----------------------------------------------------------------------------
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
fi
echo "resolv.conf configured"

# -----------------------------------------------------------------------------
# The passwordless sudo rule for the admin user
#
# The Proxmox installation resets the sudoers configuration. The harness
# logs in as admin and needs sudo without a password, so the rule is
# written again here - this is the version that ends up in the AMI.
# -----------------------------------------------------------------------------
printf 'admin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-lab-admin
chmod 440 /etc/sudoers.d/90-lab-admin
echo "the passwordless sudo rule for admin is in place"

# -----------------------------------------------------------------------------
# The boot-time network configuration
#
# The Debian cloud image writes a netplan configuration that matches the MAC
# address of the machine the image was built on. Every instance that is
# launched from the AMI snapshot gets a different MAC address, so the match
# fails and the node has no network at all: no SSH, no SSM agent, no cluster.
#
# The script replaces it with a name-based match, and it runs at every boot.
# -----------------------------------------------------------------------------
install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-network.sh" /usr/local/sbin/lab-network.sh
install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-netcheck.sh" /usr/local/sbin/lab-netcheck.sh
install -m 0755 "${PACKER_SCRIPTS_DIR:-/opt/lab-build}/lab-firewall.sh" /usr/local/sbin/lab-firewall.sh

cat > /etc/systemd/system/lab-network.service << 'UNIT_EOF'
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

cat > /etc/systemd/system/lab-firewall.service << 'UNIT_EOF'
[Unit]
Description=Write the Proxmox host firewall rules
After=pve-cluster.service
Requires=pve-cluster.service
Before=pve-firewall.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lab-firewall.sh
TimeoutStartSec=180

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
mkdir -p /etc/systemd/network
tee /etc/systemd/network/10-lab-network.network >/dev/null << 'NETWORKD_EOF'
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
rm -f /etc/netplan/*.yaml
mkdir -p /etc/netplan
tee /etc/netplan/10-lab-network.yaml >/dev/null << 'NETPLAN_EOF'
network:
  version: 2
  renderer: networkd
NETPLAN_EOF

systemctl daemon-reload
systemctl enable lab-network.service lab-firewall.service lab-netcheck.service
echo "the boot-time network and firewall units are installed"

# -----------------------------------------------------------------------------
# Services and leftovers
# -----------------------------------------------------------------------------
systemctl enable pveproxy pvedaemon pvestatd pve-cluster ssh chrony
systemctl disable networking.service 2>/dev/null || true

# The AWS cloud-init agent must not reconfigure the network.
systemctl enable cloud-init-local cloud-init cloud-config cloud-final 2>/dev/null || true

# Remove the leftover network file one final time.
rm -f /etc/network/interfaces.new

# The SSM agent has to be enabled explicitly and must survive the cleanup
# below: apt-get autoremove removes packages that were installed as a
# dependency of another package, and the agent must never disappear from
# the AMI - it is the only way to reach a node from a network that does not
# allow inbound connections.
apt-get install -y --reinstall amazon-ssm-agent 2>/dev/null || apt-get install -y amazon-ssm-agent 2>/dev/null || true
apt-mark hold amazon-ssm-agent 2>/dev/null || true
systemctl enable amazon-ssm-agent
echo "the SSM agent is installed, held and enabled"

# The build unit must not run again.
systemctl disable lab-ami-build.service 2>/dev/null || true
rm -f /etc/systemd/system/lab-ami-build.service

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
# The SSM agent is held, so autoremove leaves it alone. It is verified
# afterwards, because a missing agent means an unreachable node.
apt-get -y autoremove
apt-get -y clean
rm -rf /var/lib/apt/lists/*

# The stale netplan file with the MAC address of the build machine must
# go, so that the boot-time script starts from a clean slate.
rm -f /etc/netplan/*.yaml

if [ ! -x /usr/bin/amazon-ssm-agent ]; then
    echo "ERROR: the SSM agent is missing from the AMI - the node would be unreachable"
    exit 1
fi
echo "the SSM agent is in place"

rm -rf /tmp/* /var/tmp/*
rm -f /root/.ssh/known_hosts
history -c 2>/dev/null || true

echo "finalize complete"
