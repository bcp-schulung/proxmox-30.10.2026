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

sources="$(ex_out "ls /etc/apt/sources.list.d/ 2>/dev/null")"
ex_assert_contains "the no-subscription repository is configured" \
    "${sources}" "pve-no-subscription"
ex_assert_not_contains "the enterprise repository is removed" \
    "${sources}" "pve-enterprise"

repo_line="$(ex_out "cat /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null")"
ex_assert_contains "the repository points at the trixie suite" "${repo_line}" "trixie"
ex_assert_contains "the repository uses the no-subscription component" \
    "${repo_line}" "pve-no-subscription"

if ex_ok "apt-get update -qq >/dev/null 2>&1"; then
    ex_pass "apt update completes without an error"
else
    ex_fail "apt update completes without an error"
fi

# =============================================================================
# Host firewall
# =============================================================================
ex_section "Host firewall"

opts="$(ex_out "pvesh get /cluster/firewall/options --output-format json 2>/dev/null")"
ex_assert_contains "the firewall is enabled" "${opts}" "\"enable\":1"
ex_assert_contains "the inbound policy is DROP" "${opts}" "\"policy_in\":\"DROP\""
ex_assert_contains "the outbound policy is ACCEPT" "${opts}" "\"policy_out\":\"ACCEPT\""

rules="$(ex_out "pvesh get /cluster/firewall/rules --output-format json 2>/dev/null")"

ex_assert_contains "a rule allows SSH on port 22" "${rules}" "22"
ex_assert_contains "a rule allows the web UI on port 8006" "${rules}" "8006"
ex_assert_contains "a rule allows corosync on UDP 5405-5412" "${rules}" "5405"
ex_assert_contains "a rule allows NFS on port 2049" "${rules}" "2049"
ex_assert_contains "a rule allows the backup server on port 8007" "${rules}" "8007"

# A rule that accepts from everywhere restricts nothing.
ex_assert_not_contains "no rule accepts traffic from 0.0.0.0/0" \
    "${rules}" "\"source\":\"0.0.0.0/0\""
ex_assert_not_contains "no rule accepts traffic from ::/0" \
    "${rules}" "\"source\":\"::/0\""

firewall_state="$(ex_out "systemctl is-active pve-firewall 2>/dev/null")"
ex_assert_eq "the pve-firewall service is running" "active" "${firewall_state}"

# =============================================================================
# Platform health
# =============================================================================
ex_section "Platform health"

pveversion="$(ex_out "pveversion 2>/dev/null | head -1")"
ex_assert_not_empty "a Proxmox VE version is reported" "${pveversion}"
ex_assert_contains "the Proxmox version is 9.x" "${pveversion}" "proxmox-ve/9."

for svc in pveproxy pvedaemon pvestatd; do
    state="$(ex_out "systemctl is-active ${svc} 2>/dev/null")"
    ex_assert_eq "the ${svc} service is running" "active" "${state}"
done

ex_summary
exit $?
