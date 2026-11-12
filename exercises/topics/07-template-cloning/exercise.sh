#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 07: The Golden Image and Templates
# =============================================================================
# Verifies the configuration of the golden image VM and that it really is a
# template.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="07-template-cloning"
EX_TITLE="Topic 07 - The Golden Image and Templates"

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
# The templates
#
# There is ONE template per node:
#
#   9101 debian13-tpl-pve1 on pve1
#   9102 debian13-tpl-pve2 on pve2
#   9103 debian13-tpl-pve3 on pve3
# =============================================================================
ex_section "The templates"

TPL_ID="${NW_VM_TEMPLATE_ID}"

cfg="$(ex_vm_config "${TPL_ID}")"
ex_assert_not_empty "VM ${TPL_ID} exists" "${cfg}"

if [ -z "${cfg}" ]; then
    ex_error "VM ${TPL_ID} does not exist - the rest of the checks cannot run."
    ex_summary
    exit $?
fi

name="$(ex_out "qm config ${TPL_ID} 2>/dev/null | grep '^name:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM ${TPL_ID} is named ${NW_VM_TEMPLATE_NAME}" "${NW_VM_TEMPLATE_NAME}" "${name}"

ex_assert_contains "VM ${TPL_ID} uses the q35 machine type" "${cfg}" "q35"
ex_assert_contains "VM ${TPL_ID} uses virtio-scsi-single" "${cfg}" "virtio-scsi-single"
ex_assert_contains "VM ${TPL_ID} uses the virtio network device" "${cfg}" "virtio"
ex_assert_contains "VM ${TPL_ID} is connected to vmbr0" "${cfg}" "bridge=vmbr0"

ex_assert_contains "the guest agent is enabled" "${cfg}" "enabled=1"
ex_assert_contains "fstrim_cloned_disks is set" "${cfg}" "fstrim_cloned_disks=1"

ex_assert_contains "VM ${TPL_ID} has an EFI disk" "${cfg}" "efidisk0"
ex_assert_contains "the EFI disk has pre-enrolled keys" "${cfg}" "pre-enrolled-keys=1"

boot="$(ex_out "qm config ${TPL_ID} 2>/dev/null | grep '^boot:'")"
ex_assert_contains "the boot order starts with the disk" "${boot}" "scsi0"

scsi="$(ex_out "qm config ${TPL_ID} 2>/dev/null | grep '^scsi0:'")"
ex_assert_contains "the disk is on the local LVM-thin storage" "${scsi}" "local-lvm"
ex_assert_contains "the disk has discard enabled" "${scsi}" "discard=on"
ex_assert_contains "the disk has an iothread" "${scsi}" "iothread=1"

# The disk must be the imported Debian disk, not the 4 MB EFI vars disk.
# 'qm importdisk' puts the EFI vars on disk-0 and the imported OS disk
# on disk-1, so a template that has the wrong one attached boots an EFI
# partition instead of Debian.
scsi_size="$(ex_out "qm config ${TPL_ID} 2>/dev/null | grep '^scsi0:' | grep -oE 'size=[0-9A-Za-z]+'")"
ex_assert_eq "scsi0 is the 3 GB Debian disk, not the 4 MB EFI disk" "size=3G" "${scsi_size}"

# =============================================================================
# The template state
# =============================================================================
ex_section "The template state"

is_template="$(ex_out "qm config ${TPL_ID} 2>/dev/null | grep -c '^template:'")"
ex_assert_ge "VM ${TPL_ID} is marked as a template" "${is_template}" "1"

# A template cannot be started.
if ex_ok "qm start ${TPL_ID} >/dev/null 2>&1"; then
    ex_fail "VM ${TPL_ID} cannot be started (it is a template)"
    # It started - stop it again so the exercise does not leave it running.
    ex_run "qm shutdown ${TPL_ID} >/dev/null 2>&1" >/dev/null 2>&1
else
    ex_pass "VM ${TPL_ID} cannot be started (it is a template)"
fi

# =============================================================================
# The disk
# =============================================================================
ex_section "The disk"

# The base image must not still be sitting loose in the storage.
unused="$(ex_out "qm config ${TPL_ID} 2>/dev/null | grep -c '^unused'")"
ex_assert_eq "no loose disk is left unattached" "0" "${unused}"

attached="$(ex_out "qm config ${TPL_ID} 2>/dev/null | grep -c '^scsi0:'")"
ex_assert_eq "the imported disk is attached as scsi0" "1" "${attached}"

ex_summary
exit $?
