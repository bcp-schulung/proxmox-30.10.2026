#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 05: The Guest Network
# =============================================================================
# Verifies the bridge, the DHCP server, the routing and the NAT rules.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="05-guest-network"
EX_TITLE="Topic 05 - The Guest Network"

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
# The bridge
# =============================================================================
ex_section "The bridge"

bridges="$(ex_out "ip -brief link show type bridge 2>/dev/null | tr -s ' ' | cut -d' ' -f1")"
ex_assert_contains "the vmbr0 bridge exists" "${bridges}" "vmbr0"

# 'ip -brief' pads the columns, so the address is the field after the
# state - which is either UP or UNKNOWN.
addr="$(ex_out "ip -4 -brief addr show vmbr0 2>/dev/null | tr -s ' ' | cut -d' ' -f3")"
ex_assert_contains "the bridge has an IPv4 address" "${addr}" "10.10."

# The address has to be the gateway of its own range.
if [ -n "${addr}" ]; then
    prefix="${addr#*/}"
    network="$(ex_out "ip route show dev vmbr0 scope link 2>/dev/null | cut -d' ' -f1 | head -1")"
    if [ -n "${network}" ]; then
        expected_gw="${network%/*}"1
        actual_gw="${addr%%/*}"
        ex_assert_eq "the bridge address is the gateway of ${network}" \
            "${expected_gw}" "${actual_gw}"
    else
        ex_skip "the bridge network cannot be determined"
    fi
fi

interfaces="$(ex_out "cat /etc/network/interfaces 2>/dev/null")"
ex_assert_contains "the bridge is VLAN aware" "${interfaces}" "bridge-vlan-aware yes"

vlan_show="$(ex_out "bridge vlan show 2>/dev/null")"
ex_assert_contains "bridge vlan show lists the bridge" "${vlan_show}" "vmbr0"

# The bridge must not have a physical port on EC2 - that would take the
# node's address away with it.
physports="$(ex_out "ls /sys/class/net/vmbr0/brif/ 2>/dev/null | grep -vE '^(tap|veth)' | tr '\n' ' '")"
ex_assert_empty "the bridge has no physical port enslaved" "${physports}"

# =============================================================================
# The DHCP server
# =============================================================================
ex_section "The DHCP server"

state="$(ex_out "systemctl is-active dnsmasq 2>/dev/null")"
ex_assert_eq "dnsmasq is running" "active" "${state}"

conf="$(ex_out "cat /etc/dnsmasq.d/pve-lab.conf 2>/dev/null")"
if [ -z "${conf}" ]; then
    conf="$(ex_out "cat /etc/dnsmasq.d/*.conf 2>/dev/null")"
fi
ex_assert_contains "the configuration binds to vmbr0" "${conf}" "interface=vmbr0"
ex_assert_contains "a DHCP range is defined" "${conf}" "dhcp-range="
ex_assert_contains "the DHCP options hand out the router" "${conf}" "option:router"
ex_assert_contains "the DHCP options hand out the DNS server" "${conf}" "option:dns-server"

# The range has to be inside the bridge's own subnet.
range="$(ex_out "grep -h dhcp-range /etc/dnsmasq.d/*.conf 2>/dev/null | head -1")"
if [ -n "${range}" ]; then
    range_start="$(printf '%s' "${range}" | sed -n 's/.*dhcp-range=\([0-9.]*\).*/\1/p')"
    if [ -n "${range_start}" ] && [ -n "${addr}" ]; then
        bridge_ip="${addr%%/*}"
        case "${range_start}" in
            "${bridge_ip%%.*}".*)
                ex_pass "the DHCP range is inside the bridge subnet"
                ;;
            *)
                ex_fail "the DHCP range (${range_start}) is inside the bridge subnet"
                ;;
        esac
    else
        ex_skip "the DHCP range cannot be compared with the bridge address"
    fi
else
    ex_fail "a DHCP range is defined"
fi

# =============================================================================
# The routing
# =============================================================================
ex_section "The routing"

forward="$(ex_out "cat /proc/sys/net/ipv4/ip_forward 2>/dev/null")"
ex_assert_eq "IP forwarding is enabled" "1" "${forward}"

routes="$(ex_out "ip route 2>/dev/null | grep -c '10\.10\.[0-9]*\.0/24'")"
ex_assert_ge "routes to the other overlay subnets exist" "${routes}" "2"

# The routes have to point at a management address, not at the gateway of
# the other bridge.
bad_route="$(ex_out "ip route 2>/dev/null | grep '10\.10\.' | grep -E 'via 10\.10\.'")"
ex_assert_empty "no route points at another node's bridge address" "${bad_route}"

# The other two overlay subnets have to be covered.
for net in 10.10.20.0/24 10.10.30.0/24; do
    if ex_out "ip route 2>/dev/null | grep -q '${net}'"; then
        ex_pass "a route to ${net} exists"
    else
        ex_fail "a route to ${net} exists"
    fi
done

# =============================================================================
# The NAT
# =============================================================================
ex_section "The NAT"

nat="$(ex_out "iptables -t nat -S POSTROUTING 2>/dev/null")"

masq="$(printf '%s' "${nat}" | grep -c MASQUERADE)"
ex_assert_ge "a masquerade rule exists" "${masq}" "1"

overlay_return="$(printf '%s' "${nat}" | grep -c '10\.10\.0\.0/16.*RETURN')"
ex_assert_ge "a RETURN rule protects the overlay range" "${overlay_return}" "1"

vpc_return="$(printf '%s' "${nat}" | grep -c '10\.20\.0\.0/16.*RETURN')"
ex_assert_ge "a RETURN rule protects the VPC range" "${vpc_return}" "1"

# The RETURN rules have to come before the masquerade.
masq_line="$(printf '%s' "${nat}" | grep -n MASQUERADE | head -1 | cut -d: -f1)"
overlay_line="$(printf '%s' "${nat}" | grep -n '10\.10\.0\.0/16.*RETURN' | head -1 | cut -d: -f1)"
if [ -n "${masq_line}" ] && [ -n "${overlay_line}" ]; then
    if [ "${overlay_line}" -lt "${masq_line}" ]; then
        ex_pass "the RETURN rule comes before the masquerade rule"
    else
        ex_fail "the RETURN rule comes before the masquerade rule"
    fi
else
    ex_skip "the rule order cannot be determined"
fi

# =============================================================================
# The consistency between the nodes
# =============================================================================
ex_section "The consistency between the nodes"

remote_cidrs="$(ex_remote_members "ip -4 -brief addr show vmbr0" | grep -oE '10\.10\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')"

local_cidr="$(printf '%s' "${addr}" | grep -oE '10\.10\.[0-9]+' | head -1)"

if [ -n "${remote_cidrs}" ] && [ -n "${local_cidr}" ]; then
    clash=0
    for r in ${remote_cidrs}; do
        if [ "${r}" = "${local_cidr}" ]; then
            clash=1
        fi
    done
    if [ "${clash}" -eq 0 ]; then
        ex_pass "the nodes use different overlay subnets (${local_cidr} here, ${remote_cidrs} elsewhere)"
    else
        ex_fail "the nodes use different overlay subnets (${local_cidr} is used more than once)"
    fi
else
    ex_skip "the overlay subnets of the other nodes cannot be compared"
fi

ex_summary
exit $?
