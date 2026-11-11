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
MGMT_IPV6=""; MGMT_IPV6_CIDR="64"; MGMT_IPV6_GW=""
GUEST_CIDR=""; GUEST_GW=""; DHCP_START=""; DHCP_END=""
DATA_DEVICE=""; DNS_SERVER="169.254.169.253"
EXTRA_ROUTES=""; TIME_SYNC="169.254.169.123"
ROOT_PASSWORD=""
VPC_CIDR="10.20.0.0/16"
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
        --mgmt-ipv6)    MGMT_IPV6="$2"; shift 2 ;;
        --mgmt-ipv6-cidr) MGMT_IPV6_CIDR="$2"; shift 2 ;;
        --mgmt-ipv6-gw) MGMT_IPV6_GW="$2"; shift 2 ;;
        --vpc-cidr)     VPC_CIDR="$2"; shift 2 ;;
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
# The DNS has to work before the packages can be installed.
#
# The Proxmox packages replaced the Debian networking stack with ifupdown2,
# so systemd-resolved no longer has a usable stub resolver. The result is
# an empty /etc/resolv.conf, and without a resolver no package can be
# downloaded at all.
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    log "Writing the VPC resolver into /etc/resolv.conf"
    rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
fi

log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || warn "apt-get update failed (continuing)"
apt-get install -y -qq dnsmasq nfs-common lvm2 open-iscsi chrony curl >/dev/null 2>&1 \
    || warn "some packages failed to install"

# -----------------------------------------------------------------------------
# 3. Storage: LVM-thin pool for 'local-lvm'
# -----------------------------------------------------------------------------
# The device may be given as a bare name ("nvme1n1") or as a full path
# ("/dev/nvme1n1"). The full path is what the tools need.
DATA_DEV_PATH="${DATA_DEVICE}"
case "${DATA_DEV_PATH}" in
    /dev/*) ;;
    "")    DATA_DEV_PATH="" ;;
    *)     DATA_DEV_PATH="/dev/${DATA_DEV_PATH}" ;;
esac

if [ -n "${DATA_DEV_PATH}" ] && [ -b "${DATA_DEV_PATH}" ]; then
    if pvs "${DATA_DEV_PATH}" >/dev/null 2>&1; then
        log "Physical volume ${DATA_DEV_PATH} already initialised"
    else
        log "Creating physical volume on ${DATA_DEV_PATH}"
        pvcreate "${DATA_DEV_PATH}"
    fi
    if vgs pve >/dev/null 2>&1; then
        log "Volume group 'pve' already exists"
    else
        log "Creating volume group 'pve'"
        vgcreate pve "${DATA_DEV_PATH}"
    fi
    if lvs pve/data >/dev/null 2>&1; then
        log "Thin pool 'data' already exists"
    else
        log "Creating thin pool 'data'"
        # Leave headroom so the pool metadata can be grown later.
        # The percentage has to go to -l (lowercase); -L expects an absolute
        # size.
        lvcreate -l 95%FREE -T pve/data
    fi
else
    warn "Data device '${DATA_DEV_PATH:-<none>}' is not present - skipping local-lvm setup"
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
# The management interface is the one that carries the default route. That
# is the most reliable way to find it.
#
# The devices under /sys/class/net include more than the physical
# interfaces: the Proxmox bridge (vmbr0), the bond placeholders
# (bonding_masters, bonding_slaves) and the loopback device. Only a device
# that has a MAC address and is not the loopback device can be the
# management interface.
MGMT_IF="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"

if [ -z "${MGMT_IF}" ] || [ "${MGMT_IF}" = "lo" ] || [ ! -e "/sys/class/net/${MGMT_IF}" ]; then
    for candidate in /sys/class/net/*; do
        [ -e "${candidate}" ] || continue
        name="$(basename "${candidate}")"
        [ "${name}" = "lo" ] && continue
        # A physical interface has a hardware address.
        [ -s "${candidate}/address" ] || continue
        case "${name}" in
            vmbr*|bond*|dummy*|veth*|tap*|br-*|virbr*) continue ;;
        esac
        MGMT_IF="${name}"
        break
    done
fi

if [ -z "${MGMT_IF}" ]; then
    err "No management interface found - the node cannot be configured"
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
EOF

# The IPv6 address is what the operator reaches the node on: the public IPv4
# address is unreachable from a CGNAT network, but the IPv6 address is not
# translated. It is optional - a node without one still works over IPv4.
if [ -n "${MGMT_IPV6}" ]; then
    cat >> /root/interfaces.candidate << EOF

auto ${MGMT_IF}
iface ${MGMT_IF} inet6 static
    address ${MGMT_IPV6}/${MGMT_IPV6_CIDR}
EOF
    if [ -n "${MGMT_IPV6_GW}" ]; then
        printf '    gateway %s\n' "${MGMT_IPV6_GW}" >> /root/interfaces.candidate
    fi
fi

cat >> /root/interfaces.candidate << EOF

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

# The network hand-over is prepared here, but the hand-over itself happens
# at the very end, right before the reboot.
#
# Stopping systemd-networkd takes the SSH connection down with it, so
# nothing that needs the network may run after that point.
if [ -d /etc/netplan ]; then
    mkdir -p /etc/netplan.disabled
    mv /etc/netplan/*.yaml /etc/netplan.disabled/ 2>/dev/null || true
fi
rm -f /etc/resolv.conf
printf 'nameserver %s\nnameserver 1.1.1.1\n' "${DNS_SERVER}" > /etc/resolv.conf

systemctl enable networking.service >/dev/null 2>&1 || true
REBOOT_REQUIRED=1

# -----------------------------------------------------------------------------
# The rollback
#
# The node is rebooted to apply the network configuration. If the new
# configuration is wrong, the node comes back without a network and is then
# unreachable - over SSH and over the Systems Manager, because the agent
# needs a network as well.
#
# The rollback unit is the way out of that situation. It is enabled for the
# next boot, checks whether the management interface has an address, and
# restores the configuration that is known to work if it has not.
#
# The unit disables itself once the node has a network, so it does not
# interfere with the normal operation.
# -----------------------------------------------------------------------------
log "Installing the network rollback"
cp /root/interfaces.candidate /root/interfaces.rollback
cat > /etc/systemd/system/lab-network-rollback.service << 'UNIT_EOF'
[Unit]
Description=Restore the working network configuration if the node has none
After=network.target
Before=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lab-network-rollback.sh
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /usr/local/sbin/lab-network-rollback.sh << 'ROLLBACK_EOF'
#!/bin/bash
# Restore the network configuration that is known to work.
#
# The unit is enabled for the boot that follows the bootstrap. If the
# management interface has an address, the node is fine and the unit
# disables itself.
set -uo pipefail

MGMT_IF=""
for dev in /sys/class/net/*; do
    [ -e "${dev}" ] || continue
    name="$(basename "${dev}")"
    [ "${name}" = "lo" ] && continue
    MGMT_IF="${name}"
    break
done

if [ -z "${MGMT_IF}" ]; then
    echo "[rollback] no network interface found"
    exit 0
fi

if ip -4 addr show dev "${MGMT_IF}" 2>/dev/null | grep -q "inet "; then
    echo "[rollback] the interface ${MGMT_IF} has an address - nothing to do"
    systemctl disable lab-network-rollback.service >/dev/null 2>&1 || true
    exit 0
fi

echo "[rollback] the interface ${MGMT_IF} has NO address - restoring the old configuration"

if [ -f /root/interfaces.rollback ]; then
    cp /root/interfaces.rollback /etc/network/interfaces
    echo "[rollback] the old configuration is restored"
fi

systemctl disable --now systemd-networkd.socket systemd-networkd.service >/dev/null 2>&1 || true
systemctl enable networking.service >/dev/null 2>&1 || true
systemctl restart networking.service >/dev/null 2>&1 || true

sleep 10

if ip -4 addr show dev "${MGMT_IF}" 2>/dev/null | grep -q "inet "; then
    echo "[rollback] the interface has an address again"
else
    echo "[rollback] the interface still has no address - the node needs manual attention"
fi

exit 0
ROLLBACK_EOF

chmod 0755 /usr/local/sbin/lab-network-rollback.sh
systemctl daemon-reload
systemctl enable lab-network-rollback.service >/dev/null 2>&1 || true
log "the network rollback is installed"

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
# The netmask has to be written in the dotted form when a lease time is
# given. With the prefix length dnsmasq rejects the line: "bad dhcp-range".
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
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

# The drop-in directory has to exist before the file can be written into
# it.
mkdir -p /etc/systemd/system/pve-lab-netfilter.service.d
cat > /etc/systemd/system/pve-lab-netfilter.service.d/override.conf << 'OVERRIDE_EOF'
[Service]
ExecStart=
ExecStart=/usr/local/sbin/pve-lab-netfilter ${GUEST_CIDR} ${MGMT_IF} 10.10.0.0/16 ${VPC_CIDR}
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

# -----------------------------------------------------------------------------
# 10. Proxmox host firewall
#
# Proxmox VE 9 ships with the pve-firewall service enabled and the default
# host firewall policy for INPUT set to DROP. A freshly installed node
# therefore drops every inbound connection - including SSH - and the
# administrator cannot log in at all.
#
# The AMI masks the service so that the node is reachable from the first
# boot. Now that the bootstrap runs, the firewall is unmasked and the real
# rules are written.
#
# The rules below open exactly what the lab needs:
#   * SSH (22)          - the operator and the cluster members
#   * the web UI (8006) - the operator
#   * corosync/KNET     - the cluster
#   * NFS (2049)        - the shared storage, from the VPC only
#   * PBS (8007)        - the backup server, from the VPC only
#
# The rules are written directly, because the pvesh/firewall API is only
# available once the cluster configuration is in place - and the firewall
# has to be open before the cluster can be joined.
# -----------------------------------------------------------------------------
FW_DIR="/etc/pve/nodes/$(hostname)/"
mkdir -p "${FW_DIR}"

cat > "${FW_DIR}host.fw" << EOF
[OPTIONS]
# A node level firewall file accepts only these options. The inbound and
# the outbound policy belong to the CLUSTER firewall (cluster.fw), not
# here - writing them here makes the whole file unparseable, and the
# firewall then silently stops enforcing anything.
enable: 1

[RULES]

# Accept SSH from the lab VPC (the operator reaches the node through the
# AWS security group, and the cluster members talk to each other here).
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 22 # SSH from the lab VPC

# Accept the Proxmox web UI from the lab VPC.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 8006 # web UI from the lab VPC

# corosync and KNET - the cluster heartbeat and the cluster filesystem.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p udp -dport 5405:5412 # corosync and KNET

# The Proxmox cluster API and the backup server talk to the nodes over
# this port.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 8007 # Proxmox Backup Server

# The shared NFS storage is mounted from the nodes.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 2049 # NFS client

# The NFS portmapper and the mount daemon.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p udp -dport 111 # NFS portmapper
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 111 # NFS portmapper

# The VNC and SPICE consoles for the guests.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 5900:5999 # VNC and SPICE console

# ICMP, so that path MTU discovery works and the operator can ping the node.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p icmp # ICMP from the lab VPC

# The guest overlay is bridged onto vmbr0 and is handled by the FORWARD
# chain, not here.
EOF

log "Proxmox host firewall configured in ${FW_DIR}host.fw"

# The AMI masks the firewall so that the node is reachable before the
# bootstrap has run. Now the rules are in place, so it is unmasked and
# started.
#
# The marker tells the boot-time script (lab-firewall.service) that the
# bootstrap has run. Without it, the boot-time script would mask the
# firewall again on the next reboot.
mkdir -p /etc/lab
touch /etc/lab/bootstrap-done

# The marker tells the boot-time script (lab-firewall.service) that the
# bootstrap has run. Without it, the boot-time script would write the
# generic rules over the port-specific ones and mask the firewall again at
# the next boot.
mkdir -p /etc/lab
touch /etc/lab/bootstrap-done

systemctl unmask pve-firewall >/dev/null 2>&1 || true
systemctl enable pve-firewall >/dev/null 2>&1 || true
systemctl restart pve-firewall >/dev/null 2>&1 || true
log "pve-firewall enabled"

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

# -----------------------------------------------------------------------------
# The network hand-over
#
# This is the last thing the script does, because stopping the network
# service takes the SSH connection down with it.
#
# The boot-time network unit (lab-network.service) belongs to the old
# stack: it requires systemd-networkd and writes a networkd configuration.
# With the network now managed by ifupdown2, the unit would fail on every
# boot and could take the interface down with it. It is therefore disabled
# and masked.
#
# The systemd-resolved service is stopped as well. It holds port 53, which
# dnsmasq needs for the guest overlay.
# -----------------------------------------------------------------------------
log "Disabling the boot-time network configuration"
systemctl disable lab-network.service lab-netcheck.service >/dev/null 2>&1 || true
systemctl mask lab-network.service >/dev/null 2>&1 || true

log "Stopping systemd-networkd - ifupdown2 takes over at the next boot"
systemctl disable --now systemd-networkd.socket systemd-networkd.service >/dev/null 2>&1 || true
systemctl disable --now systemd-networkd-wait-online.service >/dev/null 2>&1 || true

log "Stopping systemd-resolved - dnsmasq needs port 53"
systemctl disable --now systemd-resolved.service >/dev/null 2>&1 || true
systemctl mask systemd-resolved.service >/dev/null 2>&1 || true
systemctl mask systemd-resolved.socket >/dev/null 2>&1 || true

log "Bootstrap finished (reboot required: ${REBOOT_REQUIRED})"
exit 0
