#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 10: Clone Strategies
# =============================================================================
# Verifies the clone strategies against the guest inventory.
#
# The lab has one template per node and one running guest per node:
#
#   pve1: template 9101 debian13-tpl-pve1  ->  guest 9201 debian13-run-pve1
#   pve2: template 9102 debian13-tpl-pve2  ->  guest 9202 debian13-run-pve2
#   pve3: template 9103 debian13-tpl-pve3  ->  guest 9203 debian13-run-pve3
#
# Every guest is a FULL clone of the template on its own node. The reason
# is the one this topic is about:
#
#   A full clone can be moved to another node only when the source is on
#   shared storage. A template on the local storage of a node is refused
#   with
#
#     can't clone VM to node 'pve2' (VM uses local storage)
#
#   A linked clone is a snapshot of the template's disk, and a snapshot is
#   only possible on a storage that supports them. NFS does not:
#
#     Linked clone feature is not supported for 'nfs-lab:9000/...'
#
# A template on the node's OWN local LVM-thin storage satisfies both
# constraints, so that is where the templates live.
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
# The guest on this node
# =============================================================================
ex_section "The guest ${NW_VM_TEST_ID}"

cfg="$(ex_vm_config "${NW_VM_TEST_ID}")"
ex_assert_not_empty "VM ${NW_VM_TEST_ID} exists" "${cfg}"

if [ -z "${cfg}" ]; then
    ex_error "VM ${NW_VM_TEST_ID} does not exist - the rest of the checks cannot run."
    ex_summary
    exit $?
fi

name="$(ex_out "qm config ${NW_VM_TEST_ID} 2>/dev/null | grep '^name:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM ${NW_VM_TEST_ID} is named ${NW_VM_TEST_NAME}" "${NW_VM_TEST_NAME}" "${name}"

scsi="$(ex_out "qm config ${NW_VM_TEST_ID} 2>/dev/null | grep '^scsi0:'")"

# A full clone has a disk of its own. A linked clone shares the disk of
# its template and the volume is named 'base-<vmid>-disk-N'.
ex_assert_not_contains "VM ${NW_VM_TEST_ID} is a full clone, not a linked one" \
    "${scsi}" "base-910"
ex_assert_contains "VM ${NW_VM_TEST_ID} has its own disk" "${scsi}" "vm-${NW_VM_TEST_ID}-disk"

# The template of the node is on the node's local LVM-thin storage, so
# that it supports the snapshots that a linked clone needs.
ex_assert_contains "the guest is on the local LVM-thin storage" "${scsi}" "local-lvm"

ex_assert_contains "VM ${NW_VM_TEST_ID} has its own cloud-init drive" "${cfg}" "cloudinit"

ipconfig="$(ex_out "qm config ${NW_VM_TEST_ID} 2>/dev/null | grep '^ipconfig0:'")"
ex_assert_contains "VM ${NW_VM_TEST_ID} has its own IP configuration" "${ipconfig}" "ip="

status="$(ex_guest_status vm "${NW_VM_TEST_ID}")"
ex_assert_eq "VM ${NW_VM_TEST_ID} is running" "running" "${status}"

if [ "${status}" = "running" ]; then
    guest_hostname="$(ex_out "qm guest exec ${NW_VM_TEST_ID} -- hostname 2>/dev/null | tr -d '\r'")"
    ex_assert_eq "the guest reports the hostname ${NW_VM_TEST_NAME}" "${NW_VM_TEST_NAME}" "${guest_hostname}"
else
    ex_skip "the hostname check (the guest is not running)"
fi

# =============================================================================
# The base template
# =============================================================================
ex_section "The base template"

tpl="$(ex_vm_config "${NW_VM_TEMPLATE_ID}")"
ex_assert_not_empty "the template ${NW_VM_TEMPLATE_ID} still exists" "${tpl}"

is_template="$(ex_out "qm config ${NW_VM_TEMPLATE_ID} 2>/dev/null | grep -c '^template:'")"
ex_assert_ge "the template ${NW_VM_TEMPLATE_ID} is still a template" "${is_template}" "1"

base="$(ex_out "pvesm list local-lvm --content images 2>/dev/null | grep -c 'base-9101'")"
ex_assert_ge "the base disk base-9101-disk-0 still exists" "${base}" "1"

# =============================================================================
# The other guests, for comparison
# =============================================================================
ex_section "The other guests, for comparison"

for id in 9201 9202; do
    cfg_other="$(ex_vm_config "${id}")"
    if [ -z "${cfg_other}" ]; then
        ex_skip "the checks for VM ${id} (it does not exist on this node)"
        continue
    fi

    scsi_other="$(ex_out "qm config ${id} 2>/dev/null | grep '^scsi0:'")"
    ex_assert_not_contains "VM ${id} is a full clone, not a linked one" \
        "${scsi_other}" "base-910"
    ex_assert_contains "VM ${id} has its own disk" "${scsi_other}" "vm-${id}-disk"
done

ex_summary
exit $?
