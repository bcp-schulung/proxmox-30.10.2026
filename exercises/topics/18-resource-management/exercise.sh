#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 18: Resource Management
# =============================================================================
# Verifies the CPU, the memory and the disk limits of the guests.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="18-resource-management"
EX_TITLE="Topic 18 - Resource Management"

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

cfg="$(ex_vm_config 100)"
ex_assert_not_empty "VM 9201 exists" "${cfg}"

if [ -z "${cfg}" ]; then
    ex_error "VM 9201 does not exist - the rest of the checks cannot run."
    ex_summary
    exit $?
fi

# =============================================================================
# The CPU
# =============================================================================
ex_section "The CPU"

sockets="$(ex_out "qm config 9201 2>/dev/null | grep '^sockets:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM 9201 has 1 socket" "1" "${sockets}"

cores="$(ex_out "qm config 9201 2>/dev/null | grep '^cores:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM 9201 has 2 cores" "2" "${cores}"

cpulimit="$(ex_out "qm config 9201 2>/dev/null | grep '^cpulimit:' | tr -s ' ' | cut -d' ' -f2")"
case "${cpulimit}" in
    ''|*[!0-9]*) ex_fail "VM 9201 has a CPU limit" ;;
    0)           ex_fail "VM 9201 has a CPU limit (it is unlimited)" ;;
    *)           ex_pass "VM 9201 has a CPU limit (${cpulimit})" ;;
esac

cpuunits="$(ex_out "qm config 9201 2>/dev/null | grep '^cpuunits:' | tr -s ' ' | cut -d' ' -f2")"
case "${cpuunits}" in
    ''|*[!0-9]*) ex_fail "VM 9201 has a CPU weight" ;;
    *)           ex_pass "VM 9201 has a CPU weight (${cpuunits})" ;;
esac

cpu="$(ex_out "qm config 9201 2>/dev/null | grep '^cpu:'")"
if [ -n "${cpu}" ]; then
    if printf '%s' "${cpu}" | grep -q 'host'; then
        ex_fail "the CPU type is portable between the nodes (it is 'host')"
    else
        ex_pass "the CPU type is portable between the nodes"
    fi
else
    ex_skip "no CPU type is set"
fi

# =============================================================================
# The memory
# =============================================================================
ex_section "The memory"

memory="$(ex_out "qm config 9201 2>/dev/null | grep '^memory:' | tr -s ' ' | cut -d' ' -f2")"
case "${memory}" in
    ''|*[!0-9]*) ex_fail "VM 9201 has a memory limit" ;;
    0)           ex_fail "VM 9201 has a memory limit" ;;
    *)           ex_pass "VM 9201 has a memory limit (${memory} MB)" ;;
esac

balloon="$(ex_out "qm config 9201 2>/dev/null | grep '^balloon:' | tr -s ' ' | cut -d' ' -f2")"
case "${balloon}" in
    ''|*[!0-9]*)
        ex_fail "VM 9201 has a balloon value"
        ;;
    0)
        ex_fail "VM 9201 has a balloon value (it is disabled)"
        ;;
    *)
        if [ -n "${memory}" ] && [ "${balloon}" -lt "${memory}" ]; then
            ex_pass "the balloon (${balloon}) is lower than the memory limit (${memory})"
        else
            ex_fail "the balloon (${balloon}) is lower than the memory limit (${memory})"
        fi
        ;;
esac

# The database tier must not have a balloon.
ct301_balloon="$(ex_out "pct config 301 2>/dev/null | grep '^balloon:' | tr -s ' ' | cut -d' ' -f2")"
case "${ct301_balloon}" in
    ''|0) ex_pass "the database tier CT 301 has no balloon" ;;
    *)   ex_fail "the database tier CT 301 has no balloon (it is ${ct301_balloon})" ;;
esac

# =============================================================================
# The disk
# =============================================================================
ex_section "The disk"

scsi0="$(ex_out "qm config 9201 2>/dev/null | grep '^scsi0:'")"
ex_assert_contains "the disk is on the shared storage" "${scsi0}" "nfs-lab"
ex_assert_contains "the disk has discard enabled" "${scsi0}" "discard=on"
ex_assert_contains "the disk has an iothread" "${scsi0}" "iothread=1"

# The size has to be larger than the original 32 GB.
size="$(printf '%s' "${scsi0}" | tr ',' '\n' | grep '^size=' | cut -d= -f2 | tr -d 'G')"
case "${size}" in
    ''|*[!0-9.]*) ex_skip "the disk size cannot be read" ;;
    *)
        whole="${size%%.*}"
        if [ "${whole}" -gt 32 ]; then
            ex_pass "the disk was grown (${size}G, the original was 32G)"
        else
            ex_fail "the disk was grown (it is ${size}G, the original was 32G)"
        fi
        ;;
esac

# =============================================================================
# The container limits
# =============================================================================
ex_section "The container limits"

ct300="$(ex_ct_config 300)"
ex_assert_not_empty "CT 300 exists" "${ct300}"

ctcores="$(ex_out "pct config 300 2>/dev/null | grep '^cores:' | tr -s ' ' | cut -d' ' -f2")"
case "${ctcores}" in
    ''|*[!0-9]*) ex_fail "CT 300 has a CPU limit" ;;
    0)           ex_fail "CT 300 has a CPU limit" ;;
    *)           ex_pass "CT 300 has a CPU limit (${ctcores})" ;;
esac

ctmemory="$(ex_out "pct config 300 2>/dev/null | grep '^memory:' | tr -s ' ' | cut -d' ' -f2")"
case "${ctmemory}" in
    ''|*[!0-9]*) ex_fail "CT 300 has a memory limit" ;;
    0)           ex_fail "CT 300 has a memory limit" ;;
    *)           ex_pass "CT 300 has a memory limit (${ctmemory} MB)" ;;
esac

ex_summary
exit $?
