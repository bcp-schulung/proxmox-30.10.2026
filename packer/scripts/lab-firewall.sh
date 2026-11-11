#!/bin/bash
# =============================================================================
# lab-firewall.sh - write the Proxmox host firewall rules at boot
# =============================================================================
#
# /etc/pve is a pmxcfs mount. It is created at boot by pve-cluster and is
# NOT part of the file system that an AMI snapshot captures. A host.fw that
# was written during the image build therefore does not exist on an instance
# that was launched from that AMI.
#
# The rules are written here, at every boot, before the firewall service is
# started. The service stays masked until the bootstrap script has replaced
# these rules with the final, port-specific ones.
# =============================================================================
set -uo pipefail

log() { printf '[lab-firewall] %s\n' "$*"; }

NODE_NAME="$(hostname)"

# -----------------------------------------------------------------------------
# 1. Wait for the pmxcfs mount.
#
# The cluster filesystem is created by pve-cluster. The rules can only be
# written once /etc/pve/nodes exists.
# -----------------------------------------------------------------------------
for _ in $(seq 1 60); do
    if [ -d /etc/pve/nodes ] && [ -d "/etc/pve/nodes/${NODE_NAME}" ]; then
        break
    fi
    sleep 2
done

if [ ! -d "/etc/pve/nodes/${NODE_NAME}" ]; then
    log "ERROR: /etc/pve/nodes/${NODE_NAME} does not exist"
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. The bootstrap marker.
#
# A marker file records that the bootstrap has run. Once it exists, the
# rules that the bootstrap wrote are the real rules, and this script must
# not touch them.
#
# The order matters. The rules used to be written first and the marker was
# checked afterwards, which meant that every reboot overwrote the
# port-specific rules of the bootstrap with the generic ones below. The
# firewall then dropped every inbound connection that did not come from
# the VPC - including the SSH connection of the operator.
# -----------------------------------------------------------------------------
BOOTSTRAP_MARKER="/etc/lab/bootstrap-done"

if [ -f "${BOOTSTRAP_MARKER}" ]; then
    log "the bootstrap has run - the firewall keeps the rules of the bootstrap"
    exit 0
fi

# -----------------------------------------------------------------------------
# 3. Write the rules.
#
# These are the rules for a node that has not been bootstrapped yet. They
# accept everything from the lab VPC, so that the cluster members and the
# helper instances can reach the node, and they accept the operator.
# -----------------------------------------------------------------------------
FW_DIR="/etc/pve/nodes/${NODE_NAME}"
cat > "${FW_DIR}/host.fw" << 'FW_EOF'
[OPTIONS]
# The INPUT policy stays DROP - only the rules below are accepted.
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

log "the host firewall rules are written to ${FW_DIR}/host.fw"

# -----------------------------------------------------------------------------
# 4. Keep the firewall service masked.
#
# Proxmox VE 9 ships with pve-firewall enabled and the default host policy
# for INPUT set to DROP. A node that has just been installed therefore drops
# every inbound connection - including SSH.
#
# The service is masked in the AMI, so that the node is reachable from the
# first boot. The bootstrap script unmaskes it and applies the final rules.
# -----------------------------------------------------------------------------
systemctl mask pve-firewall 2>/dev/null || true
systemctl stop pve-firewall 2>/dev/null || true

log "pve-firewall is masked"
exit 0
