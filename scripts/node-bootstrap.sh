#!/bin/bash
# =============================================================================
# node-bootstrap.sh - configure a Proxmox VE node for the AWS seminar lab
# =============================================================================
# Executed on the node over SSH by provision.sh. Idempotent: re-running it
# converges on the desired configuration rather than duplicating it.
#
# Usage:
#   node-bootstrap.sh --name pve1 \
#                     --mgmt-ip 10.20.0.10 --mgmt-gw 10.20.0.1 --mgmt-cidr 24 \
#                     --guest-cidr 10.10.10.0/24 --guest-gw 10.10.10.1 \
#                     --dhcp-start 10.10.10.100 --dhcp-end 10.10.10.200 \
#                     --data-device /dev/nvme1n1 \
#                     --dns 169.254.169.253 \
#                     --routes "10.10.20.0/24=10.20.0.11,10.10.30.0/24=10.20.0.12"
#
# What it does:
#   1. hostname + /etc/hosts  (Proxmox refuses to start on a loopback hostname)
#   2. packages: dnsmasq, nfs-client, lvm2, open-iscsi, chrony
#   3. LVM-thin volume group on the data volume -> 'local-lvm'
#   4. network: eth0 keeps the management IP, vmbr0 becomes the guest overlay
#   5. dnsmasq DHCP for the guest overlay
#   6. NAT + forwarding + segmentation rules for the guest overlay
#   7. time synchronisation (critical for corosync and the cluster certificates)
# =============================================================================
set -euo pipefail

LOG_TAG="bootstrap"

NODE_NAME=""; MGMT_IP=""; MGMT_GW=""; MGMT_CIDR="24"
GUEST_CIDR=""; GUEST_GW=""; DHCP_START=""; DHCP_END=""
DATA_DEVICE=""; DNS_SERVER="169.254.169.253"
EXTRA_ROUTES=""; TIME_SYNC="169.254.169.123"
ROOT_PASSWORD=""
REBOOT_REQUIRED=0

log() { printf '[%s] %s\n' "${LOG_TAG}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${LOG_TAG}" "$*" >&2; }
err() { printf '[%s] ERROR: %s\n' "${LOG_TAG}" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)         NODE_NAME="$2"; shift 2 ;;
        --mgmt-ip)      MGMT_IP="$2"; shift 2 ;;
        --mgmt-gw)      MGMT_GW="$2"; shift 2 ;;
        --mgmt-cidr)    MGMT_CIDR="$2"; shift 2 ;;
        --guest-cidr)   GUEST_CIDR="$2"; shift 2 ;;
        --guest-gw)     GUEST_GW="$2"; shift 2 ;;
        --dhcp-start)   DHCP_START="$2"; shift 2 ;;
        --dhcp-end)     DHCP_END="$2"; shift 2 ;;
        --data-device)  DATA_DEVICE="$2"; shift 2 ;;
        --dns)          DNS_SERVER="$2"; shift 2 ;;
        --routes)       EXTRA_ROUTES="$2"; shift 2 ;;
        --time-sync)    TIME_SYNC="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        *)              err "Unknown argument: $1" ;;
    esac
done

[ -n "${NODE_NAME}" ] || err "--name is required"
[ -n "${MGMT_IP}" ] || err "--mgmt-ip is required"
[ -n "${GUEST_CIDR}" ] || err "--guest-cidr is required"
[ -n "${GUEST_GW}" ] || err "--guest-gw is required"

# The guest overlay prefix length (e.g. 24) used by dnsmasq.
GUEST_PREFIX="${GUEST_CIDR#*/}"

# -----------------------------------------------------------------------------
# 1. Identity
# -----------------------------------------------------------------------------
log "Setting hostname to ${NODE_NAME}"
hostnamectl set-hostname "${NODE_NAME}" 2>/dev/null || echo "${NODE_NAME}" > /etc/hostname

# Proxmox refuses to start pve-cluster when the hostname resolves to a
# loopback address, so remove the 127.0.1.1 mapping and add the real one.
sed -i '/^127\.0\.1\.1/d' /etc/hosts || true
if ! grep -q "[[:space:]]${NODE_NAME}\([[:space:]]\|\$\)" /etc/hosts; then
    printf '%s\t%s %s.seminar.local %s\n' "${MGMT_IP}" "${NODE_NAME}" "${NODE_NAME}" "${NODE_NAME}" >> /etc/hosts
fi
hostname -F /etc/hostname 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Packages
# -----------------------------------------------------------------------------
log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || warn "apt-get update failed (continuing)"
apt-get install -y -qq dnsmasq nfs-common lvm2 open-iscsi chrony curl >/dev/null 2>&1 \
    || warn "some packages failed to install"

# -----------------------------------------------------------------------------
# 3. Storage: LVM-thin pool for 'local-lvm'
# -----------------------------------------------------------------------------
if [ -n "${DATA_DEVICE}" ] && [ -b "${DATA_DEVICE}" ]; then
    if pvs "${DATA_DEVICE}" >/dev/null 2>&1; then
        log "Physical volume ${DATA_DEVICE} already initialised"
    else
        log "Creating physical volume on ${DATA_DEVICE}"
        pvcreate "${DATA_DEVICE}"
    fi
    if vgs pve >/dev/null 2>&1; then
        log "Volume group 'pve' already exists"
    else
        log "Creating volume group 'pve'"
        vgcreate pve "${DATA_DEVICE}"
    fi
    if lvs pve/data >/dev/null 2>&1; then
        log "Thin pool 'data' already exists"
    else
        log "Creating thin pool 'data'"
        # Leave headroom so the pool metadata can be grown later.
        lvcreate -L 95%FREE -T pve/data
    fi
else
    warn "Data device '${DATA_DEVICE}' is not present - skipping local-lvm setup"
fi

# -----------------------------------------------------------------------------
# 4. Network
#
#    eth0   : management interface, keeps the VPC IP (never bridged, so a
#             bridge misconfiguration can never lock us out of the node)
#    vmbr0  : guest overlay bridge. It intentionally has no physical port:
#             AWS routes only to ENI-owned IPs, so guests cannot use VPC
#             addresses directly. The host provides DHCP, routing and NAT.
# -----------------------------------------------------------------------------
MGMT_IF="eth0"
if [ ! -e "/sys/class/net/${MGMT_IF}" ]; then
    for candidate in /sys/class/net/*; do
        name="$(basename "${candidate}")"
        [ "${name}" = "lo" ] && continue
        MGMT_IF="${name}"
        break
    done
fi
log "Management interface: ${MGMT_IF}"

cat > /root/interfaces.candidate << EOF
# Managed by the Proxmox seminar lab bootstrap - do not edit in the GUI.
auto lo
iface lo inet loopback

auto ${MGMT_IF}
iface ${MGMT_IF} inet static
    address ${MGMT_IP}/${MGMT_CIDR}
    gateway ${MGMT_GW}
    dns ${DNS_SERVER}

auto vmbr0
iface vmbr0 inet static
    address ${GUEST_GW}/${GUEST_PREFIX}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes

source /etc/network/interfaces.d/*
EOF

# Validate before installing. A broken interfaces file means the node comes
# back without a network, so this has to be checked while the current
# configuration is still in place.
log "Validating the network configuration"
mkdir -p /run/network
if ifup -s -a -i /root/interfaces.candidate 2>&1 | grep -q '^error:'; then
    log_warn "the candidate configuration failed validation - retrying without 'bridge-ports none'"
    sed -i '/bridge-ports none/d' /root/interfaces.candidate
    if ifup -s -a -i /root/interfaces.candidate 2>&1 | grep -q '^error:'; then
        err "the network configuration is invalid - aborting before the reboot"
    fi
fi
install -m 0644 /root/interfaces.candidate /etc/network/interfaces
log "Network configuration installed"

# The installer leaves a pending file behind; pvenetcommit would overwrite our
# configuration with it at the next boot.
rm -f /etc/network/interfaces.new

# Hand the interface over from systemd-networkd / netplan to ifupdown2.
if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-networkd.service'; then
    log "Disabling systemd-networkd"
    systemctl disable --now systemd-networkd.socket systemd-networkd.service 2>/dev/null || true
    systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved.service'; then
    log "Disabling systemd-resolved"
    systemctl disable --now systemd-resolved.service 2>/dev/null || true
fi
if [ -d /etc/netplan ]; then
    mkdir -p /etc/netplan.disabled
    mv /etc/netplan/*.yaml /etc/netplan.disabled/ 2>/dev/null || true
fi
rm -f /etc/resolv.conf
printf 'nameserver %s\nnameserver 1.1.1.1\n' "${DNS_SERVER}" > /etc/resolv.conf

systemctl enable networking.service >/dev/null 2>&1 || true
REBOOT_REQUIRED=1

# -----------------------------------------------------------------------------
# 5. dnsmasq - DHCP for the guest overlay
# -----------------------------------------------------------------------------
log "Configuring dnsmasq for ${GUEST_CIDR}"
cat > /etc/dnsmasq.d/pve-lab.conf << EOF
# Guest overlay DHCP for the Proxmox seminar lab
interface=vmbr0
bind-dynamic
port=0
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},${GUEST_PREFIX},12h
dhcp-option=option:router,${GUEST_GW}
dhcp-option=option:dns-server,${GUEST_GW},${DNS_SERVER}
dhcp-option=option:ntp-server,${TIME_SYNC}
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

cat > /etc/dnsmasq.d/pve-lab-upstream.conf << EOF
server=${DNS_SERVER}
no-resolv
EOF

systemctl enable dnsmasq >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 6. NAT, forwarding and segmentation
# -----------------------------------------------------------------------------
log "Installing the guest overlay NAT/forwarding rules"
cat > /usr/local/sbin/pve-lab-netfilter << 'NETFILTER_EOF'
#!/bin/bash
# Guest overlay NAT and segmentation rules for the Proxmox seminar lab.
# Idempotent - safe to run repeatedly.
set -u

GUEST_CIDR="${1:-10.10.10.0/24}"
UPLINK="${2:-eth0}"
OVERLAY_RANGE="${3:-10.10.0.0/16}"
VPC_CIDR="${4:-10.20.0.0/16}"

# --- filter table ---
iptables -C FORWARD -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j ACCEPT
iptables -C FORWARD -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j DROP 2>/dev/null || \
    iptables -I FORWARD 2 -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j DROP
iptables -C FORWARD -s "${GUEST_CIDR}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 3 -s "${GUEST_CIDR}" -j ACCEPT
iptables -C FORWARD -d "${GUEST_CIDR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 4 -d "${GUEST_CIDR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -i vmbr0 -p udp --dport 67 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -i vmbr0 -p udp --dport 67 -j ACCEPT
iptables -C INPUT -i vmbr0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -i vmbr0 -p tcp --dport 53 -j ACCEPT
iptables -C INPUT -i vmbr0 -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 3 -i vmbr0 -p udp --dport 53 -j ACCEPT

# --- nat table ---
# Keep overlay-to-overlay traffic un-NATed so guests on different nodes can
# talk to each other directly.
iptables -t nat -C POSTROUTING -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j RETURN 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${GUEST_CIDR}" -d "${OVERLAY_RANGE}" -j RETURN
iptables -t nat -C POSTROUTING -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j RETURN 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${GUEST_CIDR}" -d "${VPC_CIDR}" -j RETURN
iptables -t nat -C POSTROUTING -s "${GUEST_CIDR}" -o "${UPLINK}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${GUEST_CIDR}" -o "${UPLINK}" -j MASQUERADE

# --- forwarding ---
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null

exit 0
NETFILTER_EOF
chmod +x /usr/local/sbin/pve-lab-netfilter

cat > /etc/systemd/system/pve-lab-netfilter.service << 'UNIT_EOF'
[Unit]
Description=Proxmox lab guest overlay NAT and segmentation rules
After=network.target
Before=pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pve-lab-netfilter %i
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/pve-lab-netfilter.service.d/override.conf 2>/dev/null << 'OVERRIDE_EOF'
[Service]
ExecStart=
ExecStart=/usr/local/sbin/pve-lab-netfilter 10.10.10.0/24 eth0 10.10.0.0/16 10.20.0.0/16
OVERRIDE_EOF
mkdir -p /etc/systemd/system/pve-lab-netfilter.service.d
cat > /etc/systemd/system/pve-lab-netfilter.service.d/override.conf << OVERRIDE_EOF
[Service]
ExecStart=
ExecStart=/usr/local/sbin/pve-lab-netfilter ${GUEST_CIDR} ${MGMT_IF} 10.10.0.0/16 ${VPC_CIDR:-10.20.0.0/16}
OVERRIDE_EOF

systemctl daemon-reload
systemctl enable pve-lab-netfilter >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 7. Routes to the overlay subnets of the other nodes
# -----------------------------------------------------------------------------
if [ -n "${EXTRA_ROUTES}" ]; then
    log "Adding static routes to the overlay subnets of the other nodes"
    OLDIFS="$IFS"
    IFS=','
    for entry in ${EXTRA_ROUTES}; do
        cidr="${entry%%=*}"
        gw="${entry#*=}"
        [ -n "${cidr}" ] && [ -n "${gw}" ] || continue
        ip route replace "${cidr}" via "${gw}" dev "${MGMT_IF}" 2>/dev/null || \
            warn "Could not add route ${cidr} via ${gw}"
        log "  route ${cidr} via ${gw}"
    done
    IFS="$OLDIFS"
fi

# -----------------------------------------------------------------------------
# 8. Time synchronisation - corosync and the cluster certificates depend on it
# -----------------------------------------------------------------------------
log "Configuring chrony"
cat > /etc/chrony/chrony.conf << EOF
pool ${TIME_SYNC} iburst minpoll 4 maxpoll 4
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 9. Proxmox housekeeping
# -----------------------------------------------------------------------------
# The GUI writes its own network file; we manage the network out of band, so
# stop pvenetcommit from overwriting /etc/network/interfaces at boot.
systemctl mask pvenetcommit.service >/dev/null 2>&1 || true
rm -f /etc/network/interfaces.new

# Enable the Proxmox firewall and the cluster services.
systemctl enable pveproxy pvedaemon pvestatd pve-cluster ssh >/dev/null 2>&1 || true

# The hostname only became resolvable in this script, so the Proxmox services
# have to be restarted to pick it up.
log "Restarting the Proxmox services"
systemctl restart pve-cluster 2>/dev/null || true
systemctl restart pveproxy pvedaemon pvestatd 2>/dev/null || true

# Set the root password used for the web UI and the cluster join.
if [ -n "${ROOT_PASSWORD}" ]; then
    log "Setting the root password"
    printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
fi

log "Bootstrap finished (reboot required: ${REBOOT_REQUIRED})"
exit 0
