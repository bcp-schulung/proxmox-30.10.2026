#!/bin/bash
# =============================================================================
# lab-network.sh - configure the management interface of a lab node
# =============================================================================
#
# The Debian cloud image writes a netplan configuration that matches the MAC
# address of the machine it was built on:
#
#   ethernets:
#     enp39s0:
#       match:
#         macaddress: "02:ff:cf:03:1e:f7"
#
# An AMI snapshot keeps that file, but every instance that is launched from
# the snapshot gets a DIFFERENT MAC address. The match therefore fails, no
# interface is configured, and the node has no network at all: no SSH, no
# SSM agent, no cluster.
#
# This script replaces the MAC-matched file with a name-based match, which
# works for every instance that is launched from the AMI. It is run at boot
# by lab-network.service, before the Proxmox services start.
# =============================================================================
set -uo pipefail

NETPLAN_DIR="/etc/netplan"

log() { printf '[lab-network] %s\n' "$*"; }

# -----------------------------------------------------------------------------
# 1. Inspect the existing configuration.
#
# Every file that cloud-init or the image build wrote can contain a MAC
# address that only matches the build machine, so all of them are checked.
# A file that matches the current interface is kept - cloud-init writes one
# on the first boot of every instance, and that one is correct.
# -----------------------------------------------------------------------------
MGMT_MAC=""
KEPT_CONFIG=0

for cfg in "${NETPLAN_DIR}"/*.yaml; do
    [ -e "${cfg}" ] || continue

    # The MAC address that the file matches.
    mac="$(grep -oE 'macaddress:[[:space:]]*"[0-9a-fA-F:]+"' "${cfg}" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')"

    if [ -z "${mac}" ]; then
        # No MAC match - the file works for every interface.
        log "${cfg} has no MAC match and is kept"
        KEPT_CONFIG=1
        continue
    fi

    # The MAC of the interface that carries the default route.
    if [ -z "${MGMT_MAC}" ]; then
        for dev in /sys/class/net/*; do
            [ -e "${dev}" ] || continue
            [ "$(basename "${dev}")" = "lo" ] && continue
            if ip -o link show "$(basename "${dev}")" 2>/dev/null | grep -q "ether"; then
                MGMT_MAC="$(cat "${dev}/address" 2>/dev/null)"
                break
            fi
        done
    fi

    if [ -n "${MGMT_MAC}" ] && [ "${mac}" = "${MGMT_MAC}" ]; then
        log "${cfg} matches the interface ${MGMT_MAC} and is kept"
        KEPT_CONFIG=1
        continue
    fi

    log "${cfg} matches the MAC address ${mac} of another machine and is removed"
    rm -f "${cfg}"
done

rm -f /etc/network/interfaces.new 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Find the management interface.
#
# On EC2 the interface is either eth0 (with the classic naming) or enpXsY
# (with the predictable naming that systemd uses). The kernel names differ
# between instance types, so the interface is found by looking at the
# devices that are not the loopback device.
# -----------------------------------------------------------------------------
find_mgmt_if() {
    local dev

    # The interface that carries the default route is the management
    # interface. This is the most reliable way to find it.
    dev="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "${dev}" ] && [ "${dev}" != "lo" ]; then
        printf '%s' "${dev}"
        return 0
    fi

    # Fall back to the first non-loopback device that is up.
    for dev in /sys/class/net/*; do
        [ -e "${dev}" ] || continue
        local name
        name="$(basename "${dev}")"
        [ "${name}" = "lo" ] && continue
        printf '%s' "${name}"
        return 0
    done

    return 1
}

MGMT_IF="$(find_mgmt_if)"

if [ -z "${MGMT_IF}" ]; then
    log "ERROR: no management interface found"
    exit 1
fi

log "the management interface is ${MGMT_IF}"

# -----------------------------------------------------------------------------
# 3. Write the configuration.
#
# The interface is matched by name, so that the configuration works for
# every instance that is launched from the AMI. A set-name is not used, so
# that the interface keeps the name the kernel gave it.
#
# A configuration that was already found to be correct is left alone: the
# one that cloud-init writes on the first boot is per-instance and better
# than a generic one.
# -----------------------------------------------------------------------------
# 3. Write the configuration.
#
# Two files are written:
#
#   /etc/netplan/10-lab-network.yaml  the declarative configuration, so that
#                                    the file is there for the next boot
#   /run/systemd/network/10-lab-network.network
#                                    the networkd configuration that
#                                    systemd-networkd actually reads
#
# The second file is the important one. The netplan generator only runs at
# boot, before this script, and it renders whatever was in /etc/netplan at
# that moment - which, in an AMI, is the configuration of the build machine.
# Writing the networkd file directly means the interface is configured no
# matter when the script runs.
#
# The interface is matched by name, so that the configuration works for
# every instance that is launched from the AMI.
#
# A configuration that was already found to be correct is left alone: the
# one that cloud-init writes on the first boot is per-instance and better
# than a generic one.
# -----------------------------------------------------------------------------
# The networkd configuration is written to TWO directories:
#
#   /etc/systemd/network/10-lab-network.network   the persistent copy
#   /run/systemd/network/10-lab-network.network   the copy for this boot
#
# The persistent copy is the important one. It is baked into the AMI, so
# that systemd-networkd already finds a matching file when it enumerates
# the links at boot. Without it the interface stays DOWN, cloud-init waits
# 130 seconds for the network, and the whole boot is late.
#
# A file that only lives in /run is gone after every reboot, so the
# interface would lose its configuration on every boot.
NETWORKD_ETC_DIR="/etc/systemd/network"
NETWORKD_RUN_DIR="/run/systemd/network"
mkdir -p "${NETWORKD_ETC_DIR}" "${NETWORKD_RUN_DIR}"

if [ "${KEPT_CONFIG:-0}" = "1" ]; then
    log "a matching configuration is already in place"
else
cat > "${NETPLAN_DIR}/10-lab-network.yaml" << EOF
network:
  version: 2
  ethernets:
    ${MGMT_IF}:
      dhcp4: true
      dhcp6: true
      dhcp6-overrides:
        use-dns: true
  renderer: networkd
EOF
chmod 600 "${NETPLAN_DIR}/10-lab-network.yaml"

log "the netplan configuration is written"
fi

# The file matches EVERY non-loopback interface, not just the one that
# was found. The name of the interface can differ between instance types
# (ens5, eth0, enpXsY), and a file that names the wrong interface is
# simply not used.
#
# The file is written to the persistent directory and to the runtime
# directory, so that it is in place for this boot and for every boot
# that follows.
write_networkd_file() {
    local dir="$1"

    cat > "${dir}/10-lab-network.network" << EOF
[Match]
Name=en* eth* enp*

[Network]
DHCP=yes
IPv6AcceptRA=yes
IPv6UseDNS=yes

[DHCP]
RouteMetric=100
UseMTU=true
EOF
}

write_networkd_file "${NETWORKD_ETC_DIR}"
write_networkd_file "${NETWORKD_RUN_DIR}"

log "the networkd configuration is written"

# -----------------------------------------------------------------------------
# 4. Apply it.
#
# The network service is NOT restarted. A restart drops the interface and
# takes the boot with it: on the backup server the instance hung in the
# boot and never came up.
#
# The reload runs with a timeout. `networkctl reload` waits for the network
# service to acknowledge the new configuration, and it does not answer when
# another service is holding the systemd transaction lock - which is what
# the backup server does during the boot.
#
# `networkctl reconfigure` asks the network service to apply the
# configuration to the interface directly. It does not need the lock.
# -----------------------------------------------------------------------------
if command -v networkctl >/dev/null 2>&1; then
    timeout 20 networkctl reload 2>&1 | sed 's/^/[lab-network] /' || true
    timeout 20 networkctl reconfigure "${MGMT_IF}" 2>&1 | sed 's/^/[lab-network] /' || true
else
    timeout 20 systemctl reload systemd-networkd 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 5. Report the state.
#
# The script does NOT wait for the address. Waiting here was a race with
# the timeout of the unit: the wait lasted 60 seconds and the unit was
# killed after 60 seconds, so the unit was terminated while it was still
# waiting - and the boot log showed a unit that started and never
# finished.
#
# The safety net (lab-netcheck.service) waits for the address and
# repairs the node when it does not come.
# -----------------------------------------------------------------------------
if ip -4 addr show dev "${MGMT_IF}" 2>/dev/null | grep -q "inet "; then
    log "the interface ${MGMT_IF} already has an IPv4 address"
else
    log "the interface ${MGMT_IF} has no address yet - lab-netcheck waits for it"
fi

# -----------------------------------------------------------------------------
# 6. DNS.
#
# The Proxmox packages replace the Debian networking stack with ifupdown2,
# and systemd-resolved then no longer has a usable stub resolver. The
# consequence is an empty /etc/resolv.conf, so that no name resolves.
#
# The VPC resolver (169.254.169.253) resolves both the internal service names
# and the public S3 endpoints.
# -----------------------------------------------------------------------------
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    log "resolv.conf configured"
fi

log "the network is configured"
exit 0
