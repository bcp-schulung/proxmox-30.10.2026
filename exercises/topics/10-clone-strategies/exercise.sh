#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 10: Clone Strategies
# =============================================================================
# Verifies the linked clone, the full clone and the dependency of the linked
# clone on its base template.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="10-clone-strategies"
EX_TITLE="Topic 10 - Clone Strategies"

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
# The linked clone
# =============================================================================
ex_section "The linked clone 102"

cfg="$(ex_vm_config 102)"
ex_assert_not_empty "VM 102 exists" "${cfg}"

if [ -z "${cfg}" ]; then
    ex_error "VM 102 does not exist - the rest of the checks cannot run."
    ex_summary
    exit $?
fi

name="$(ex_out "qm config 102 2>/dev/null | grep '^name:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM 102 is named web-test" "web-test" "${name}"

scsi="$(ex_out "qm config 102 2>/dev/null | grep '^scsi0:'")"
ex_assert_contains "VM 102 is a linked clone of the template" "${scsi}" "base-9000"
ex_assert_contains "VM 102 is on the shared storage" "${scsi}" "nfs-lab"

ex_assert_contains "VM 102 has its own cloud-init drive" "${cfg}" "cloudinit"

ipconfig="$(ex_out "qm config 102 2>/dev/null | grep '^ipconfig0:'")"
ex_assert_contains "VM 102 has its own IP configuration" "${ipconfig}" "ip="

status="$(ex_guest_status vm 102)"
ex_assert_eq "VM 102 is running" "running" "${status}"

if [ "${status}" = "running" ]; then
    guest_hostname="$(ex_out "qm guest exec 102 -- hostname 2>/dev/null | tr -d '\r'")"
    ex_assert_eq "the guest reports the hostname web-test" "web-test" "${guest_hostname}"
else
    ex_skip "the hostname check (the guest is not running)"
fi

# =============================================================================
# The base template
# =============================================================================
ex_section "The base template"

tpl="$(ex_vm_config 9000)"
ex_assert_not_empty "the template 9000 still exists" "${tpl}"

is_template="$(ex_out "qm config 9000 2>/dev/null | grep -c '^template:'")"
ex_assert_ge "the template 9000 is still a template" "${is_template}" "1"

base="$(ex_out "pvesm list nfs-lab --content images 2>/dev/null | grep -c 'base-9000'")"
ex_assert_ge "the base disk base-9000-disk-0 still exists" "${base}" "1"

# =============================================================================
# The full clone, for comparison
# =============================================================================
ex_section "The full clone 100, for comparison"

cfg100="$(ex_vm_config 100)"
ex_assert_not_empty "VM 100 exists" "${cfg100}"

scsi100="$(ex_out "qm config 100 2>/dev/null | grep '^scsi0:'")"
ex_assert_not_contains "VM 100 is a full clone, not a linked one" \
    "${scsi100}" "base-9000"
ex_assert_contains "VM 100 has its own disk" "${scsi100}" "vm-100-disk-0"

ex_summary
exit $?
