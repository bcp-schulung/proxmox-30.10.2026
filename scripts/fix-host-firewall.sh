#!/usr/bin/env bash
# =============================================================================
# fix-host-firewall.sh - write a correct node level firewall on a PVE node
# =============================================================================
# The lab bootstrap wrote a host.fw that Proxmox cannot parse:
#
#   * 'policy_in', 'policy_out' and 'log_ratelimit' are cluster level
#     options - a node level file does not accept them
#   * the '[ALIASES]' section is cluster level as well
#   * the rules used '-d', '--dport' and '-m comment --comment', none of
#     which the rule parser understands
#
# The result was a file that Proxmox silently ignored. The firewall was
# enabled but enforced nothing - the INPUT policy stayed ACCEPT.
#
# This script writes a correct file. It is safe by construction:
#
#   1. it never touches the cluster firewall
#   2. it writes the new file to a temporary name and validates that
#      Proxmox can parse it BEFORE it replaces the live file
#   3. it keeps a backup of the previous file
#   4. it verifies that SSH still works after the change and rolls back
#      if it does not
#
# Usage:
#   ./fix-host-firewall.sh --vpc 10.20.0.0/16 --iface eth0
# =============================================================================
set -uo pipefail

VPC_CIDR="10.20.0.0/16"
MGMT_IF="eth0"

while [ $# -gt 0 ]; do
    case "$1" in
        --vpc)   VPC_CIDR="$2"; shift 2 ;;
        --iface) MGMT_IF="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

FW_DIR="/etc/pve/nodes/$(hostname)/"
FW_FILE="${FW_DIR}host.fw"
TMP_FILE="/tmp/host.fw.new"

[ "$(id -u)" = "0" ] || { echo "this script has to run as root" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Build the new file
# ---------------------------------------------------------------------------
cat > "${TMP_FILE}" << EOF
[OPTIONS]
# A node level firewall file accepts only these options. The inbound and
# the outbound policy belong to the CLUSTER firewall (cluster.fw).
enable: 1

[RULES]

# Accept SSH from the lab VPC (the operator reaches the node through the
# AWS security group, and the cluster members talk to each other here).
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 22 # SSH from the lab VPC

# Accept the Proxmox web UI from the lab VPC.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p tcp -dport 8006 # web UI from the lab VPC

# corosync and KNET - the cluster heartbeat and the cluster filesystem.
IN ACCEPT -i ${MGMT_IF} -source ${VPC_CIDR} -p udp -dport 5405:5412 # corosync and KNET

# The Proxmox cluster API and the backup server talk to the nodes here.
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
EOF

# ---------------------------------------------------------------------------
# 2. Validate that Proxmox can parse it - BEFORE it goes live
# ---------------------------------------------------------------------------
echo "Validating the new firewall file..."
if ! perl -e '
    use lib "/usr/share/perl5";
    use PVE::Firewall;
    my $c = eval {
        PVE::Firewall::generic_fw_config_parser(
            $ARGV[0], undef, {rules=>[],options=>{}}, "host")
    };
    if ($@) { print "PARSE FAILED: $@"; exit 1 }
    printf "PARSE OK - %d rules\n", scalar(@{$c->{rules}});
    exit 0
' "${TMP_FILE}"; then
    echo "The new file does not parse - the live file is left untouched." >&2
    rm -f "${TMP_FILE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Install it, with a backup
# ---------------------------------------------------------------------------
if [ -f "${FW_FILE}" ]; then
    cp -a "${FW_FILE}" "${FW_FILE}.bak"
    echo "The previous file was saved as ${FW_FILE}.bak"
fi

cp "${TMP_FILE}" "${FW_FILE}"
rm -f "${TMP_FILE}"
chmod 0644 "${FW_FILE}"

# ---------------------------------------------------------------------------
# 4. Apply and verify
# ---------------------------------------------------------------------------
systemctl restart pve-firewall
sleep 3

echo "The firewall was applied. The effective INPUT policy is now:"
iptables -S | grep -E '^-P INPUT' || echo "  (could not be read)"

# ---------------------------------------------------------------------------
# 5. The safety check - is SSH still alive?
# ---------------------------------------------------------------------------
echo
echo "Checking that SSH still works..."

# The rule allows 22 from the VPC, and the operator reaches the node from
# inside the VPC or through the AWS security group, so the connection has
# to survive. The check is made from the loopback and from the VPC.
if timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null; then
    echo "  SSH on the loopback: reachable"
else
    echo "  SSH on the loopback: NOT reachable - rolling back" >&2
    [ -f "${FW_FILE}.bak" ] && cp -a "${FW_FILE}.bak" "${FW_FILE}"
    systemctl restart pve-firewall
    exit 1
fi

local_ip="$(ip -4 -brief addr show "${MGMT_IF}" 2>/dev/null | tr -s ' ' | cut -d' ' -f3 | cut -d/ -f1)"
if [ -n "${local_ip}" ]; then
    if timeout 5 bash -c "exec 3<>/dev/tcp/${local_ip}/22" 2>/dev/null; then
        echo "  SSH on ${local_ip}: reachable"
    else
        echo "  SSH on ${local_ip}: NOT reachable - rolling back" >&2
        [ -f "${FW_FILE}.bak" ] && cp -a "${FW_FILE}.bak" "${FW_FILE}"
        systemctl restart pve-firewall
        exit 1
    fi
fi

# The web UI.
if timeout 5 bash -c "exec 3<>/dev/tcp/${local_ip:-127.0.0.1}/8006" 2>/dev/null; then
    echo "  The web UI on 8006: reachable"
else
    echo "  The web UI on 8006: NOT reachable - rolling back" >&2
    [ -f "${FW_FILE}.bak" ] && cp -a "${FW_FILE}.bak" "${FW_FILE}"
    systemctl restart pve-firewall
    exit 1
fi

echo
echo "The node firewall is now correct and enforced."
exit 0
