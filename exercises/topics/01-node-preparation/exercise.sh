#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 01: Node Preparation
# =============================================================================
# Verifies that the node is correctly identified, synchronised, configured
# with a usable package source and protected by the host firewall.
#
# Usage:
#   ./exercise.sh
#   ./exercise.sh --verbose
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="01-node-preparation"
EX_TITLE="Topic 01 - Node Preparation"

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
# Identity
# =============================================================================
ex_section "Identity"

local_hostname="$(ex_out "hostname")"
ex_assert_contains "the hostname is a lab node name" "${local_hostname}" "pve"

hosts="$(ex_out "cat /etc/hosts")"
ex_assert_not_contains "/etc/hosts has no 127.0.1.1 line" "${hosts}" "127.0.1.1"
ex_assert_contains "/etc/hosts maps the node to a routable address" \
    "${hosts}" "10.20.0."

resolved="$(ex_out "getent hosts ${local_hostname} 2>/dev/null | cut -d' ' -f1 | head -1")"
ex_assert_not_contains "the hostname does not resolve to a loopback address" \
    "${resolved}" "127.0."

# =============================================================================
# Time
# =============================================================================
ex_section "Time synchronisation"

ntp="$(ex_out "timedatectl show -p NTPSynchronized --value 2>/dev/null")"
ex_assert_eq "the clock is synchronised" "yes" "${ntp}"

drift="$(ex_out "chronyc tracking 2>/dev/null | grep -i 'System time' | cut -d' ' -f4")"
if [ -n "${drift}" ]; then
    drift_seconds="${drift%%.*}"
    case "${drift_seconds}" in
        ''|*[!0-9]*) ex_fail "the clock drift is measurable (got '${drift}')" ;;
        *) ex_assert_le "the clock drift is below 2 seconds" "${drift_seconds}" "1" ;;
    esac
else
    ex_skip "the clock drift cannot be measured (chronyc is not available)"
fi

# =============================================================================
# Package sources
# =============================================================================
ex_section "Package sources"

# Proxmox VE 9 writes the repositories in the deb822 format, as
# '/etc/apt/sources.list.d/pve-<repo>.sources'. Older installations use the
# one-line '.list' format. Both are accepted here.
#
# The file name is not fixed - the Proxmox installer calls it
# 'pve-install-repo.sources', a hand-made configuration often calls it
# 'pve-no-subscription.sources'. The CONTENT is what matters.
sources="$(ex_out "ls /etc/apt/sources.list.d/ 2>/dev/null")"
ex_assert_contains "a Proxmox repository file exists" \
    "${sources}" "pve-"

# The content of every repository file, so that the check does not depend
# on the file name.
repo_content="$(ex_out "cat /etc/apt/sources.list.d/pve-* 2>/dev/null")"

ex_assert_contains "the no-subscription repository is configured" \
    "${repo_content}" "pve-no-subscription"
ex_assert_not_contains "the enterprise repository is removed" \
    "${repo_content}" "pve-enterprise"

ex_assert_contains "the repository points at the trixie suite" \
    "${repo_content}" "trixie"
ex_assert_contains "the repository uses the no-subscription component" \
    "${repo_content}" "pve-no-subscription"

if ex_ok "apt-get update -qq >/dev/null 2>&1"; then
    ex_pass "apt update completes without an error"
else
    ex_fail "apt update completes without an error"
fi

# =============================================================================
# Host firewall
# =============================================================================
ex_section "Host firewall"

# The firewall has two levels:
#
#   /etc/pve/cluster/firewall/cluster.fw   the cluster wide rules and the
#                                          inbound / outbound policy
#   /etc/pve/nodes/<node>/host.fw          the rules for this node
#
# The two levels accept DIFFERENT things:
#
#   * the cluster file accepts [OPTIONS] with 'policy_in' and 'policy_out',
#     plus the [ALIASES], [GROUPS] and [IPSET] sections
#   * the node file accepts [OPTIONS] with 'enable' and the rule set - it
#     does NOT accept 'policy_in' or 'policy_out'
#
# A node file that carries the cluster options is unparseable, and
# Proxmox then ignores the whole file. The firewall stays "enabled" but
# enforces nothing - which is worse than having no firewall at all,
# because it looks like it is working.
#
# The checks below verify that the effective configuration really parses
# and that the rules that matter are present.

hostfw="$(ex_out "cat /etc/pve/nodes/\$(hostname)/host.fw 2>/dev/null")"
clusterfw="$(ex_out "cat /etc/pve/cluster/firewall/cluster.fw 2>/dev/null")"

if [ -n "${hostfw}" ]; then
    ex_pass "the node firewall file exists"
else
    ex_fail "the node firewall file exists"
fi

# The node file has to be parseable. The API returns an error when it is
# not, and that error is the whole point of this check.
parse_error="$(ex_out "pvesh get /nodes/\$(hostname)/firewall/rules --output-format json 2>&1 \
    | grep -i 'can.t parse\|unable to parse' | head -1")"
if [ -z "${parse_error}" ]; then
    ex_pass "the node firewall file is parseable"
else
    ex_fail "the node firewall file is parseable: ${parse_error}"
fi

# The rules that the cluster needs. They may live at either level.
rules="${hostfw} ${clusterfw}"

ex_assert_contains "a rule allows SSH on port 22" "${rules}" "dport 22"
ex_assert_contains "a rule allows the web UI on port 8006" "${rules}" "dport 8006"
ex_assert_contains "a rule allows corosync on UDP 5405-5412" "${rules}" "5405:5412"
ex_assert_contains "a rule allows NFS on port 2049" "${rules}" "dport 2049"
ex_assert_contains "a rule allows the backup server on port 8007" "${rules}" "dport 8007"

# A rule that accepts from everywhere restricts nothing.
ex_assert_not_contains "no rule accepts traffic from 0.0.0.0/0" \
    "${rules}" "0.0.0.0/0"
ex_assert_not_contains "no rule accepts traffic from ::/0" \
    "${rules}" "::/0"

# The node file must not carry the cluster level options - they make the
# file unparseable.
ex_assert_not_contains "the node file has no cluster level policy_in" \
    "${hostfw}" "policy_in"
ex_assert_not_contains "the node file has no cluster level policy_out" \
    "${hostfw}" "policy_out"

firewall_state="$(ex_out "systemctl is-active pve-firewall 2>/dev/null")"
ex_assert_eq "the pve-firewall service is running" "active" "${firewall_state}"

# =============================================================================
# Platform health
# =============================================================================
ex_section "Platform health"

pveversion="$(ex_out "pveversion 2>/dev/null | head -1")"
ex_assert_not_empty "a Proxmox VE version is reported" "${pveversion}"
ex_assert_contains "the Proxmox version is 9.x" "${pveversion}" "9.2"

for svc in pveproxy pvedaemon pvestatd; do
    state="$(ex_out "systemctl is-active ${svc} 2>/dev/null")"
    ex_assert_eq "the ${svc} service is running" "active" "${state}"
done

ex_summary
exit $?
