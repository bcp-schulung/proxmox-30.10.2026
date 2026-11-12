#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 11: Snapshots and Rollback
# =============================================================================
# Verifies the snapshot, the rollback and the cleanup of VM 9201.
#
# The script performs the snapshot/rollback cycle itself when the guest is
# running, so the check is a real end-to-end test rather than a look at the
# configuration.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="11-snapshots-rollback"
EX_TITLE="Topic 11 - Snapshots and Rollback"

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

MARKER="/etc/nordwind-exercise-marker"
SNAPSHOT="pre-update"

status="$(ex_guest_status vm 100)"
if [ "${status}" != "running" ]; then
    ex_error "VM 9201 is not running - the snapshot cycle cannot be tested."
    ex_fail "VM 9201 is running"
    ex_summary
    exit $?
fi
ex_pass "VM 9201 is running"

# =============================================================================
# The snapshot
# =============================================================================
ex_section "The snapshot"

# A leftover snapshot from a previous run would make the test meaningless.
ex_run "qm delsnapshot 9201 ${SNAPSHOT} >/dev/null 2>&1" >/dev/null 2>&1

# The marker file exists BEFORE the snapshot. It must survive the snapshot
# and be gone after the rollback.
if ex_ok "qm guest exec 9201 -- sh -c 'echo before > ${MARKER}'"; then
    ex_pass "the marker file was created in the guest"
else
    ex_fail "the marker file was created in the guest"
fi

if ex_ok "qm snapshot 9201 ${SNAPSHOT} --description 'seminar exercise snapshot' >/dev/null 2>&1"; then
    ex_pass "the snapshot ${SNAPSHOT} was created"
else
    ex_fail "the snapshot ${SNAPSHOT} was created"
fi

snaps="$(ex_out "qm listsnapshot 9201 2>/dev/null")"
ex_assert_contains "the snapshot is listed" "${snaps}" "${SNAPSHOT}"

desc="$(ex_out "qm listsnapshot 9201 2>/dev/null | grep '${SNAPSHOT}' | sed 's/.*${SNAPSHOT}[[:space:]]*//'")"
ex_assert_not_empty "the snapshot carries a description" "${desc}"

# =============================================================================
# The rollback
# =============================================================================
ex_section "The rollback"

# Change the file after the snapshot.
if ex_ok "qm guest exec 9201 -- sh -c 'echo after > ${MARKER}'"; then
    ex_pass "the marker file was changed after the snapshot"
else
    ex_fail "the marker file was changed after the snapshot"
fi

if ex_ok "qm rollback 9201 ${SNAPSHOT} >/dev/null 2>&1"; then
    ex_pass "the rollback completed"
else
    ex_fail "the rollback completed"
fi

# Give the guest a moment to come back after the rollback.
sleep 3

content="$(ex_out "qm guest exec 9201 -- cat ${MARKER} 2>/dev/null | tr -d '\\r'")"
ex_assert_eq "the change after the snapshot is gone" "before" "${content}"

status="$(ex_guest_status vm 100)"
ex_assert_eq "the guest is running after the rollback" "running" "${status}"

if [ "${status}" = "running" ]; then
    if ex_ok "qm guest cmd 9201 ping >/dev/null 2>&1"; then
        ex_pass "the guest agent answers after the rollback"
    else
        ex_fail "the guest agent answers after the rollback"
    fi
fi

# =============================================================================
# The cleanup
# =============================================================================
ex_section "The cleanup"

if ex_ok "qm delsnapshot 9201 ${SNAPSHOT} >/dev/null 2>&1"; then
    ex_pass "the snapshot ${SNAPSHOT} was deleted"
else
    ex_fail "the snapshot ${SNAPSHOT} was deleted"
fi

snaps="$(ex_out "qm listsnapshot 9201 2>/dev/null")"
ex_assert_not_contains "the snapshot is no longer listed" "${snaps}" "${SNAPSHOT}"

# The marker file is left over from the test - clean it up.
ex_run "qm guest exec 9201 -- rm -f ${MARKER} >/dev/null 2>&1" >/dev/null 2>&1

ex_summary
exit $?
