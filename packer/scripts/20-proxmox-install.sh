#!/bin/bash
# =============================================================================
# 20-proxmox-install.sh - build step: the Proxmox VE packages
# =============================================================================
#
# The script is called by build-runner.sh. It runs the package downloads
# detached on the instance, so that a drop of the SSH connection does not
# abort the build, and waits for the result.
# =============================================================================
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG="/var/log/pve-install.log"
MARKER="/var/log/pve-install.rc"

# The Proxmox installation resets the sudoers configuration, which takes the
# passwordless sudo away from the admin user. The rule is written again
# here, and the finalize step writes it into the AMI.
printf 'admin ALL=(ALL) NOPASSWD:ALL\n' | sudo tee /etc/sudoers.d/90-lab-admin >/dev/null
sudo chmod 440 /etc/sudoers.d/90-lab-admin

# Preseed postfix so the install does not stop on a dialog.
echo "postfix postfix/main_mailer_type select Local only" | sudo debconf-set-selections
echo "postfix postfix/mailname string proxmox.seminar.local" | sudo debconf-set-selections

# Without a subscription the enterprise repository answers 401 on every
# apt update, which breaks unattended upgrades.
sudo sed -i 's/^Enabled: yes/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources 2>/dev/null || true
sudo sed -i 's/^Enabled: yes/Enabled: false/' /etc/apt/sources.list.d/ceph.sources 2>/dev/null || true

# -----------------------------------------------------------------------------
# The install, detached on the instance.
# -----------------------------------------------------------------------------
cat > /tmp/pve-install-step.sh << 'INSTALL_EOF'
#!/bin/bash
set -x
export DEBIAN_FRONTEND=noninteractive

# The package install is the long part.
apt-get -o Acquire::Retries=3 install -y proxmox-ve postfix open-iscsi chrony ifupdown2
rc=$?
if [ "${rc}" -ne 0 ]; then
    echo "the first install attempt failed with ${rc} - retrying"
    apt-get -o Acquire::Retries=3 install -y proxmox-ve postfix open-iscsi chrony ifupdown2
    rc=$?
fi

# The installer leaves a pending network file behind. pvenetcommit would move
# it over /etc/network/interfaces at the next boot and silently destroy the
# bridge configuration the bootstrap writes.
rm -f /etc/network/interfaces.new

# The Debian kernels were already removed in the kernel step, so that GRUB
# boots the Proxmox kernel. GRUB is regenerated here as well, because the
# Proxmox installation can add its own kernel hooks.
update-grub

# Keep systemd-networkd in charge of the network inside the AMI.
systemctl disable networking.service 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true
systemctl enable systemd-networkd-wait-online 2>/dev/null || true

# The Proxmox services must come up on the first boot.
systemctl enable pveproxy pvedaemon pvestatd pve-cluster

# -----------------------------------------------------------------------------
# The Proxmox host firewall - THE CRITICAL STEP
#
# Proxmox VE 9 ships with pve-firewall enabled and the default host policy
# for INPUT set to DROP. A node that has just been installed therefore drops
# every inbound connection - including SSH.
#
# This is fatal for an AMI: as soon as the instance boots into the Proxmox
# kernel, pve-firewall starts and SSH is gone. The node can never be
# finished, and the administrator can never log in.
#
# The firewall is therefore masked in the AMI. The node is reachable from
# the first boot, and the bootstrap script enables the firewall again and
# writes the lab's port-specific rules over SSH or SSM.
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
echo "host firewall rules written to ${FW_DIR}/host.fw"

# Mask the service so that it does not start at boot. The bootstrap
# unmasks it and applies the final rules.
systemctl mask pve-firewall 2>/dev/null || true
systemctl stop pve-firewall 2>/dev/null || true
systemctl disable pve-firewall 2>/dev/null || true
echo "pve-firewall masked"

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

# Make sure the SSM agent is enabled. The Proxmox installation can disable
# services it does not know about.
systemctl enable amazon-ssm-agent 2>/dev/null || systemctl enable ssm-agent 2>/dev/null || true
echo "the SSM agent is enabled"

# The stale netplan configuration of the build machine has to go. It matches
# a MAC address that no instance that is launched from the AMI will ever
# have, so it would leave every cloned instance without a network.
rm -f /etc/netplan/*.yaml
echo "the stale netplan configuration is removed"

echo "the install step finished with ${rc}"
printf '%s' "${rc}" > /var/log/pve-install.rc
INSTALL_EOF

sudo chmod +x /tmp/pve-install-step.sh
sudo rm -f "${MARKER}" "${LOG}"
sudo sh -c "nohup setsid /tmp/pve-install-step.sh > '${LOG}' 2>&1 &"
sleep 3

echo "The Proxmox install runs in the background on the instance."
echo "Log: ${LOG}"

DEADLINE=$(( $(date +%s) + 3600 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    if sudo test -s "${MARKER}"; then
        rc="$(sudo cat "${MARKER}")"
        echo "--- the install finished with exit status ${rc} ---"
        if [ "${rc}" != "0" ]; then
            sudo tail -40 "${LOG}" || true
            exit 1
        fi
        exit 0
    fi
    sudo tail -2 "${LOG}" 2>/dev/null || true
    sleep 15
done

echo "ERROR: the install did not finish in time"
sudo tail -40 "${LOG}" || true
exit 1
