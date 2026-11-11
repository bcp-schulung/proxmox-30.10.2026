#!/bin/bash
# =============================================================================
# lab-netcheck.sh - make sure the node has a network and an SSH server
# =============================================================================
#
# The boot-time network configuration (lab-network.service) runs early, so
# that the Proxmox services, the SSM agent and the SSH server all come up
# with an address.
#
# This script is the safety net that runs a little later. It checks whether
# the node really has an address and whether the SSH server is listening. If
# not, it repairs the situation.
#
# Without this safety net, a single early failure - for example a race
# between the unit and the network device - would leave a node that boots
# but that can neither be reached over SSH nor register with the Systems
# Manager. Such a node is useless for a seminar.
# =============================================================================
set -uo pipefail

log() { printf '[lab-netcheck] %s\n' "$*"; }

MGMT_IF=""
SSH_OK=0

# -----------------------------------------------------------------------------
# 1. Wait for the interface.
# -----------------------------------------------------------------------------
for _ in $(seq 1 60); do
    for dev in /sys/class/net/*; do
        [ -e "${dev}" ] || continue
        name="$(basename "${dev}")"
        [ "${name}" = "lo" ] && continue
        MGMT_IF="${name}"
        break
    done
    [ -n "${MGMT_IF}" ] && break
    sleep 2
done

if [ -z "${MGMT_IF}" ]; then
    log "ERROR: no network interface found"
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. Wait for an address.
# -----------------------------------------------------------------------------
for _ in $(seq 1 60); do
    if ip -4 addr show dev "${MGMT_IF}" 2>/dev/null | grep -q "inet "; then
        break
    fi
    sleep 2
done

if ! ip -4 addr show dev "${MGMT_IF}" 2>/dev/null | grep -q "inet "; then
    log "the interface ${MGMT_IF} has no address - the network configuration is applied again"
    /usr/local/sbin/lab-network.sh || true

    for _ in $(seq 1 30); do
        if ip -4 addr show dev "${MGMT_IF}" 2>/dev/null | grep -q "inet "; then
            break
        fi
        sleep 2
    done
fi

if ip -4 addr show dev "${MGMT_IF}" 2>/dev/null | grep -q "inet "; then
    log "the interface ${MGMT_IF} has an address"
else
    log "ERROR: the interface ${MGMT_IF} still has no address"
fi

# -----------------------------------------------------------------------------
# 3. DNS.
# -----------------------------------------------------------------------------
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    log "resolv.conf configured"
fi

# -----------------------------------------------------------------------------
# 4. The SSH server.
# -----------------------------------------------------------------------------
systemctl enable ssh >/dev/null 2>&1 || true

if systemctl is-active --quiet ssh; then
    SSH_OK=1
    log "the SSH server is running"
else
    log "the SSH server is not running - it is started"
    systemctl restart ssh >/dev/null 2>&1 || true
    sleep 3
    if systemctl is-active --quiet ssh; then
        SSH_OK=1
        log "the SSH server is running now"
    else
        log "ERROR: the SSH server could not be started"
    fi
fi

# -----------------------------------------------------------------------------
# 5. The SSM agent.
#
# The agent is the only way to reach a node from a network that does not
# allow inbound connections, so it is checked as well.
# -----------------------------------------------------------------------------
systemctl enable amazon-ssm-agent >/dev/null 2>&1 || true
if ! systemctl is-active --quiet amazon-ssm-agent; then
    log "the SSM agent is not running - it is started"
    systemctl restart amazon-ssm-agent >/dev/null 2>&1 || true
    sleep 3
    systemctl is-active --quiet amazon-ssm-agent && log "the SSM agent is running now" \
        || log "WARN: the SSM agent could not be started"
fi

if [ "${SSH_OK}" = "1" ]; then
    log "the node is reachable"
    exit 0
fi

exit 1
