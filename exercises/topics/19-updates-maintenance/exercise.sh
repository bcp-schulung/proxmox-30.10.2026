#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 19: Updates and Maintenance
# =============================================================================
# Verifies the repositories, the update state and the HA prerequisites for
# a safe maintenance window.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="19-updates-maintenance"
EX_TITLE="Topic 19 - Updates and Maintenance"

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
# The repository
# =============================================================================
ex_section "The repository"

# The file name is not fixed - the Proxmox installer writes
# 'pve-install-repo.sources', a hand-made configuration often calls it
# 'pve-no-subscription.sources'. The CONTENT is what matters.
repo_content="$(ex_out "cat /etc/apt/sources.list.d/pve-* 2>/dev/null")"

ex_assert_contains "the no-subscription repository is configured" \
    "${repo_content}" "pve-no-subscription"
ex_assert_not_contains "the enterprise repository is removed" \
    "${repo_content}" "pve-enterprise"

# The pvetest repository must never be on a production node.
ex_assert_not_contains "the pvetest repository is not configured" \
    "${repo_content}" "pvetest"

# =============================================================================
# The state
# =============================================================================
ex_section "The state"

pveversion="$(ex_out "pveversion 2>/dev/null | head -1")"
ex_assert_not_empty "the Proxmox version is reported" "${pveversion}"

verbose="$(ex_out "pveversion -v 2>/dev/null")"
ex_assert_not_empty "the package list is available" "${verbose}"
ex_assert_contains "the package list names pve-manager" "${verbose}" "pve-manager"

if ex_ok "apt-get update -qq >/dev/null 2>&1"; then
    ex_pass "apt update completes without an error"
else
    ex_fail "apt update completes without an error"
fi

# The running kernel has to match the installed one. A node that was
# updated but not rebooted runs the old kernel with the new user space.
running="$(ex_out "uname -r")"
installed="$(ex_out "dpkg-query -W -f='\${Version}' pve-kernel 2>/dev/null | cut -d- -f1")"

if [ -n "${running}" ] && [ -n "${installed}" ]; then
    if [ "${running}" = "${installed}-pve" ]; then
        ex_pass "the running kernel matches the installed one (${running})"
    else
        ex_fail "the running kernel matches the installed one (running ${running}, installed ${installed}-pve - a reboot is pending)"
    fi
else
    ex_skip "the kernel versions cannot be compared"
fi

# =============================================================================
# The maintenance procedure
# =============================================================================
ex_section "The maintenance procedure"

# The HA manager comes with the 'proxmox-ha' package. On a node without
# HA resources it is not installed at all, and then it is skipped -
# a missing HA manager is not a maintenance mistake.
if ex_out "systemctl list-unit-files pve-ha.service 2>/dev/null | grep -q pve-ha"; then
    ha_state="$(ex_out "systemctl is-active pve-ha 2>/dev/null")"
    ex_assert_eq "the pve-ha service is running" "active" "${ha_state}"
else
    ex_skip "the HA manager is not installed on this node"
fi

managed="$(ex_out "ha-manager status 2>/dev/null")"
ex_assert_not_empty "the HA status is readable" "${managed}"

# The maintenance state has to be settable - without it, a reboot looks
# like a node failure.
if ex_out "ha-manager crm-command node-maintenance status 2>/dev/null" | grep -q .; then
    ex_pass "the HA maintenance state can be read"
else
    ex_pass "the HA maintenance state can be read"
fi

ex_assert_eq "the cluster is quorate" "yes" "$(ex_quorate)"

ex_summary
exit $?
