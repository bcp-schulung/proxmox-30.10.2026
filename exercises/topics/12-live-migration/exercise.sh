#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 12: Live Migration
# =============================================================================
# Verifies that VM 100 was migrated online to pve2 and that the guest kept
# running through the move.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="12-live-migration"
EX_TITLE="Topic 12 - Live Migration"

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
# The precondition
# =============================================================================
ex_section "The precondition"

cfg="$(ex_vm_config 100)"
ex_assert_not_empty "VM 100 exists" "${cfg}"

status="$(ex_guest_status vm 100)"
ex_assert_eq "VM 100 is running" "running" "${status}"

scsi="$(ex_out "qm config 100 2>/dev/null | grep '^scsi0:'")"
ex_assert_contains "VM 100 is on the shared storage" "${scsi}" "nfs-lab"

# The CPU type has to be portable between the nodes.
cpu="$(ex_out "qm config 100 2>/dev/null | grep '^cpu:'")"
if [ -n "${cpu}" ]; then
    if printf '%s' "${cpu}" | grep -q 'host'; then
        ex_fail "the CPU type is portable between the nodes - it is the host CPU"
    else
        ex_pass "the CPU type is portable between the nodes"
    fi
else
    ex_skip "no CPU type is set (the default is used)"
fi

# =============================================================================
# The migration
# =============================================================================
ex_section "The migration"

node="$(ex_guest_node vm 100)"
ex_assert_eq "VM 100 runs on pve2 after the migration" "pve2" "${node}"

status="$(ex_guest_status vm 100)"
ex_assert_eq "VM 100 is still running" "running" "${status}"

if [ "${status}" = "running" ]; then
    if ex_ok "qm guest cmd 100 ping >/dev/null 2>&1"; then
        ex_pass "the guest agent answers after the migration"
    else
        ex_fail "the guest agent answers after the migration"
    fi

    # The uptime proves the guest was never restarted. An offline migration
    # would have reset it to a few seconds.
    uptime="$(ex_out "qm guest exec 100 -- cut -d' ' -f1 /proc/uptime 2>/dev/null | tr -d '\\r'")"
    case "${uptime}" in
        ''|*[!0-9.]*) ex_skip "the guest uptime cannot be read" ;;
        *)
            seconds="${uptime%%.*}"
            if [ "${seconds}" -gt 60 ]; then
                ex_pass "the guest kept running through the migration (uptime ${uptime}s)"
            else
                ex_fail "the guest kept running through the migration (uptime ${uptime}s - it was restarted)"
            fi
            ;;
    esac
else
    ex_skip "the guest agent and uptime checks (the guest is not running)"
fi

# =============================================================================
# The cluster state
# =============================================================================
ex_section "The cluster state"

ex_assert_eq "the cluster is still quorate" "yes" "$(ex_quorate)"
ex_assert_eq "the cluster still has three members" "3" "$(ex_member_count)"

nodes="$(ex_nodes | sort | tr '\n' ' ')"
ex_assert_contains "pve1 is still a member" "${nodes}" "pve1"
ex_assert_contains "pve2 is still a member" "${nodes}" "pve2"
ex_assert_contains "pve3 is still a member" "${nodes}" "pve3"

ex_summary
exit $?
