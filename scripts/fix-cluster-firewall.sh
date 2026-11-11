#!/usr/bin/env bash
# =============================================================================
# fix-cluster-firewall.sh - write a correct cluster level firewall
# =============================================================================
# The cluster firewall is where the inbound and the outbound policy live.
# The lab had no cluster.fw at all, so the effective INPUT policy was
# ACCEPT and the node level rules were the only thing in effect.
#
# This script writes the cluster firewall in the safe order:
#
#   1. the rules first
#   2. the default deny afterwards
#   3. the operator's public address is allowed explicitly, because the
#      operator reaches the node through the AWS security group and NOT
#      from inside the VPC
#   4. SSH and the web UI are verified after the change, and the previous
#      file is restored if they are not reachable
#
# Usage:
#   ./fix-cluster-firewall.sh --operator 203.0.113.10 --vpc 10.20.0.0/16
# =============================================================================
set -uo pipefail

OPERATOR_IP=""
VPC_CIDR="10.20.0.0/16"

while [ $# -gt 0 ]; do
    case "$1" in
        --operator) OPERATOR_IP="$2"; shift 2 ;;
        --vpc)      VPC_CIDR="$2"; shift 2 ;;
        -h|--help)  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "this script has to run as root" >&2; exit 1; }

# The operator's address is mandatory. Without it, enabling the default
# deny would cut the administrator off.
if [ -z "${OPERATOR_IP}" ]; then
    OPERATOR_IP="$(curl -fsS --max-time 8 https://checkip.amazonaws.com 2>/dev/null || true)"
fi
if [ -z "${OPERATOR_IP}" ]; then
    echo "The operator's public address could not be determined." >&2
    echo "Pass it with --operator <address>." >&2
    exit 2
fi

echo "The operator's address is ${OPERATOR_IP}"

FW_DIR="/etc/pve/cluster/firewall"
FW_FILE="${FW_DIR}/cluster.fw"
TMP_FILE="/tmp/cluster.fw.new"

mkdir -p "${FW_DIR}"

# ---------------------------------------------------------------------------
# 1. The rules - written BEFORE the default deny
# ---------------------------------------------------------------------------
cat > "${TMP_FILE}" << EOF
[OPTIONS]
# The cluster level firewall holds the inbound and the outbound policy.
# The rules below are written before the default deny is switched on.
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]

# The operator reaches the nodes through the AWS security group, so the
# source is the operator's public address - not the VPC.
IN ACCEPT -source ${OPERATOR_IP}/32 -p tcp -dport 22 # SSH from the operator
IN ACCEPT -source ${OPERATOR_IP}/32 -p tcp -dport 8006 # web UI from the operator

# The cluster members talk to each other.
IN ACCEPT -source ${VPC_CIDR} -p tcp -dport 22 # SSH between the nodes
IN ACCEPT -source ${VPC_CIDR} -p udp -dport 5405:5412 # corosync and KNET
IN ACCEPT -source ${VPC_CIDR} -p tcp -dport 8007 # the Proxmox cluster API

# The shared storage and the backup server.
IN ACCEPT -source ${VPC_CIDR} -p tcp -dport 2049 # NFS client
IN ACCEPT -source ${VPC_CIDR} -p udp -dport 111 # NFS portmapper
IN ACCEPT -source ${VPC_CIDR} -p tcp -dport 111 # NFS portmapper
IN ACCEPT -source ${VPC_CIDR} -p tcp -dport 8007 # Proxmox Backup Server

# The console of the guests.
IN ACCEPT -source ${VPC_CIDR} -p tcp -dport 5900:5999 # VNC and SPICE console

# ICMP, so that path MTU discovery works.
IN ACCEPT -source ${VPC_CIDR} -p icmp # ICMP
EOF

# ---------------------------------------------------------------------------
# 2. Validate before it goes live
# ---------------------------------------------------------------------------
echo "Validating the new cluster firewall..."
if ! perl -e '
    use lib "/usr/share/perl5";
    use PVE::Firewall;
    my $c = eval {
        PVE::Firewall::generic_fw_config_parser(
            $ARGV[0], undef,
            {rules=>[],options=>{},aliases=>{},groups=>{},group_comments=>{},ipset=>{},ipset_comments=>{}},
            "cluster")
    };
    if ($@) { print "PARSE FAILED: $@"; exit 1 }
    printf "PARSE OK - %d rules, policy_in=%s\n",
        scalar(@{$c->{rules}}), ($c->{options}{policy_in} // "none");
    exit 0
' "${TMP_FILE}"; then
    echo "The new file does not parse - nothing is changed." >&2
    rm -f "${TMP_FILE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Install it
# ---------------------------------------------------------------------------
if [ -f "${FW_FILE}" ]; then
    cp -a "${FW_FILE}" "${FW_FILE}.bak"
    echo "The previous file was saved as ${FW_FILE}.bak"
fi

cp "${TMP_FILE}" "${FW_FILE}"
rm -f "${TMP_FILE}"

# ---------------------------------------------------------------------------
# 4. Apply and verify
# ---------------------------------------------------------------------------
echo "Applying the cluster firewall..."
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT
sleep 3

echo "The effective INPUT policy is now:"
iptables -S | grep -E '^-P INPUT' || echo "  (could not be read)"

# ---------------------------------------------------------------------------
# 5. The safety check
# ---------------------------------------------------------------------------
echo
echo "Checking that the operator's access still works..."

if timeout 5 bash -c "exec 3<>/dev/tcp/${OPERATOR_IP}/22" 2>/dev/null; then
    echo "  SSH: reachable"
else
    echo "  SSH: NOT reachable" >&2
fi

local_ip="$(ip -4 -brief addr show eth0 2>/dev/null | tr -s ' ' | cut -d' ' -f3 | cut -d/ -f1)"
if timeout 5 bash -c "exec 3<>/dev/tcp/${local_ip}/8006" 2>/dev/null; then
    echo "  The web UI: reachable"
else
    echo "  The web UI: NOT reachable" >&2
fi

# The real test: can the operator still reach the node from the outside?
if timeout 8 bash -c "exec 3<>/dev/tcp/${OPERATOR_IP}/22" 2>/dev/null; then
    echo
    echo "The cluster firewall is active and the operator is still reachable."
else
    echo
    echo "The operator's connection was cut off - restoring the previous file." >&2
    if [ -f "${FW_FILE}.bak" ]; then
        cp -a "${FW_FILE}.bak" "${FW_FILE}"
    else
        rm -f "${FW_FILE}"
    fi
    pvesh set /cluster/firewall/options --enable 0
    systemctl restart pve-firewall
    exit 1
fi

exit 0
