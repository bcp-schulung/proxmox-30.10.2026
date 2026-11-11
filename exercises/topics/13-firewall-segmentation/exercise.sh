#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 13: Firewall and Segmentation
# =============================================================================
# Verifies the datacenter firewall, the rule hygiene, the VLAN segmentation
# and the guest level rules.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="13-firewall-segmentation"
EX_TITLE="Topic 13 - Firewall and Segmentation"

# shellcheck source=../../lib/exlib.sh
. "${EX_ROOT_DIR}/lib/exlib.sh"
# shellcheck source=../../lib/scenario.sh
. "${EX_ROOT_DIR}/lib/scenario.sh"

ex_parse_args "$@"

ex_banner
ex_detect_mode
case "${EX_MODE}" in
    local) ex_info "running against the local node ($(hostname))" ;;
    ssh)   ex_info "running against ${EX_SSH_HOST} over SSH" ;;
esac

# =============================================================================
# The datacenter firewall
# =============================================================================
ex_section "The datacenter firewall"

opts="$(ex_out "pvesh get /cluster/firewall/options --output-format json 2>/dev/null")"
ex_assert_contains "the datacenter firewall is enabled" "${opts}" "\"enable\":1"
ex_assert_contains "the inbound policy is DROP" "${opts}" "\"policy_in\":\"DROP\""
ex_assert_contains "the outbound policy is ACCEPT" "${opts}" "\"policy_out\":\"ACCEPT\""

rules="$(ex_out "pvesh get /cluster/firewall/rules --output-format json 2>/dev/null")"

ex_assert_contains "a rule allows the web UI on 8006" "${rules}" "8006"
ex_assert_contains "a rule allows SSH on 22" "${rules}" "\"22\""
ex_assert_contains "a rule allows corosync on 5405-5412" "${rules}" "5405"
ex_assert_contains "a rule allows NFS on 2049" "${rules}" "2049"

# =============================================================================
# The rule hygiene
# =============================================================================
ex_section "The rule hygiene"

# A rule that accepts from everywhere restricts nothing.
ex_assert_not_contains "no rule accepts traffic from 0.0.0.0/0" \
    "${rules}" "\"source\":\"0.0.0.0/0\""
ex_assert_not_contains "no rule accepts traffic from ::/0" \
    "${rules}" "\"source\":\"::/0\""

# A rule without a destination accepts everything on every port.
any_dest="$(ex_out "pvesh get /cluster/firewall/rules --output-format json 2>/dev/null \
    | /opt/exercises/lib/ex-json.sh '[.[] | select(.dport == null and .dest == null)] | length'")"
case "${any_dest}" in
    ''|*[!0-9]*) ex_skip "the rules without a destination cannot be counted" ;;
    *)
        if [ "${any_dest}" -eq 0 ]; then
            ex_pass "every rule has a destination"
        else
            ex_fail "every rule has a destination (${any_dest} rules accept everything)"
        fi
        ;;
esac

# =============================================================================
# The segmentation
# =============================================================================
ex_section "The segmentation"

net100="$(ex_out "qm config 100 2>/dev/null | grep '^net0:'")"
ex_assert_contains "the web tier VM 100 carries VLAN 20" "${net100}" "tag=20"

net101="$(ex_out "qm config 101 2>/dev/null | grep '^net0:'")"
ex_assert_contains "the web tier VM 101 carries VLAN 20" "${net101}" "tag=20"

net300="$(ex_out "pct config 300 2>/dev/null | grep '^net0:'")"
ex_assert_contains "the application tier CT 300 carries VLAN 30" "${net300}" "tag=30"

net301="$(ex_out "pct config 301 2>/dev/null | grep '^net0:'")"
ex_assert_contains "the database tier CT 301 carries VLAN 40" "${net301}" "tag=40"

vlan="$(ex_out "bridge vlan show 2>/dev/null")"
ex_assert_not_empty "the bridge reports its VLAN table" "${vlan}"

# =============================================================================
# The guest level rules
# =============================================================================
ex_section "The guest level rules"

vmfw="$(ex_out "cat /etc/pve/firewall/100.fw 2>/dev/null")"
ex_assert_not_empty "VM 100 has its own firewall rules" "${vmfw}"

# The web tier reaches the database tier.
dbrule="$(ex_out "cat /etc/pve/firewall/100.fw 2>/dev/null | grep -E '5432|3306'")"
ex_assert_not_empty "a rule lets the web tier reach the database tier" "${dbrule}"

# The database tier does not reach the web tier.
denyrule="$(ex_out "cat /etc/pve/firewall/301.fw 2>/dev/null | grep -i 'DROP'")"
ex_assert_not_empty "a rule denies the database tier access to the web tier" "${denyrule}"

# The guest rules have to be enabled and have a default deny.
if [ -n "${vmfw}" ]; then
    ex_assert_contains "the guest firewall is enabled" "${vmfw}" "enable: 1"
fi

ex_summary
exit $?
