#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 17: Troubleshooting
# =============================================================================
# Verifies the forensic snapshot, the repair and the documentation of the
# incident.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="17-troubleshooting"
EX_TITLE="Topic 17 - Troubleshooting"

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
# The forensic snapshot
# =============================================================================
ex_section "The forensic snapshot"

snaps="$(ex_out "qm listsnapshot 9201 2>/dev/null")"
ex_assert_contains "a snapshot named incident exists" "${snaps}" "incident"

desc="$(ex_out "qm listsnapshot 9201 2>/dev/null | grep 'incident' | sed 's/.*incident[[:space:]]*//'")"
ex_assert_not_empty "the incident snapshot carries a description" "${desc}"

# =============================================================================
# The diagnosis
# =============================================================================
ex_section "The diagnosis"

status="$(ex_guest_status vm 100)"
ex_assert_eq "VM 9201 is running" "running" "${status}"

if [ "${status}" = "running" ]; then
    # The agent answering proves that the QEMU process, the virtio-serial
    # channel and the hypervisor are all healthy - the fault was inside
    # the guest, not on the host.
    if ex_ok "qm guest cmd 9201 ping >/dev/null 2>&1"; then
        ex_pass "the guest agent answers - the host layer was not the problem"
    else
        ex_fail "the guest agent answers - the host layer was not the problem"
    fi

    # The host has to be healthy too.
    for svc in pveproxy pvedaemon pvestatd; do
        state="$(ex_out "systemctl is-active ${svc} 2>/dev/null")"
        ex_assert_eq "the host service ${svc} is running" "active" "${state}"
    done

    stor="$(ex_out "pvesm status 2>/dev/null | grep -c 'active'")"
    ex_assert_ge "the storages are active" "${stor}" "2"
fi

# =============================================================================
# The repair
# =============================================================================
ex_section "The repair"

if [ "${status}" = "running" ]; then
    agent="$(ex_out "qm guest exec 9201 -- systemctl is-active qemu-guest-agent 2>/dev/null | tr -d '\\r'")"
    ex_assert_eq "the guest agent is active inside the guest" "active" "${agent}"

    failed="$(ex_out "qm guest exec 9201 -- systemctl --failed --no-legend 2>/dev/null | tr -d '\\r'")"
    ex_assert_empty "the guest has no failed units" "${failed}"

    hostname="$(ex_out "qm guest exec 9201 -- hostname 2>/dev/null | tr -d '\\r'")"
    ex_assert_not_empty "the guest is functional and answers" "${hostname}"
else
    ex_skip "the repair checks (the guest is not running)"
fi

# =============================================================================
# The documentation
# =============================================================================
ex_section "The documentation"

log="$(ex_out "pvesh get /cluster/log --limit 200 --output-format json 2>/dev/null \
    | grep -c 'vms/9201'")"
case "${log}" in
    ''|*[!0-9]*) ex_skip "the task log cannot be counted" ;;
    *)
        if [ "${log}" -ge 1 ]; then
            ex_pass "the incident is recorded in the task log (${log} entries)"
        else
            ex_fail "the incident is recorded in the task log"
        fi
        ;;
esac

# The evidence must still be there.
snaps="$(ex_out "qm listsnapshot 9201 2>/dev/null")"
ex_assert_contains "the incident snapshot still exists - the evidence was not destroyed" \
    "${snaps}" "incident"

ex_summary
exit $?
