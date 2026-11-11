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
# The VM 9000
# =============================================================================
ex_section "The VM 9000"

cfg="$(ex_vm_config 9000)"
ex_assert_not_empty "VM 9000 exists" "${cfg}"

if [ -z "${cfg}" ]; then
    ex_error "VM 9000 does not exist - the rest of the checks cannot run."
    ex_summary
    exit $?
fi

name="$(ex_out "qm config 9000 2>/dev/null | grep '^name:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM 9000 is named debian13-template" "debian13-template" "${name}"

ex_assert_contains "VM 9000 uses the q35 machine type" "${cfg}" "q35"
ex_assert_contains "VM 9000 uses virtio-scsi-single" "${cfg}" "virtio-scsi-single"
ex_assert_contains "VM 9000 uses the virtio network device" "${cfg}" "virtio"
ex_assert_contains "VM 9000 is connected to vmbr0" "${cfg}" "bridge=vmbr0"

ex_assert_contains "the guest agent is enabled" "${cfg}" "enabled=1"
ex_assert_contains "fstrim_cloned_disks is set" "${cfg}" "fstrim_cloned_disks=1"

ex_assert_contains "VM 9000 has an EFI disk" "${cfg}" "efidisk0"
ex_assert_contains "the EFI disk has pre-enrolled keys" "${cfg}" "pre-enrolled-keys=1"

ex_assert_contains "VM 9000 has a cloud-init drive" "${cfg}" "cloudinit"

boot="$(ex_out "qm config 9000 2>/dev/null | grep '^boot:'")"
ex_assert_contains "the boot order starts with the disk" "${boot}" "scsi0"

scsi="$(ex_out "qm config 9000 2>/dev/null | grep '^scsi0:'")"
ex_assert_contains "the disk is on the shared storage" "${scsi}" "nfs-lab"
ex_assert_contains "the disk has discard enabled" "${scsi}" "discard=on"
ex_assert_contains "the disk has an iothread" "${scsi}" "iothread=1"

# =============================================================================
# The template state
# =============================================================================
ex_section "The template state"

is_template="$(ex_out "qm config 9000 2>/dev/null | grep -c '^template:'")"
ex_assert_ge "VM 9000 is marked as a template" "${is_template}" "1"

# A template cannot be started.
if ex_ok "qm start 9000 >/dev/null 2>&1"; then
    ex_fail "VM 9000 cannot be started (it is a template)"
    # It started - stop it again so the exercise does not leave it running.
    ex_run "qm shutdown 9000 >/dev/null 2>&1" >/dev/null 2>&1
else
    ex_pass "VM 9000 cannot be started (it is a template)"
fi

# =============================================================================
# The disk
# =============================================================================
ex_section "The disk"

# The base image must not still be sitting loose in the storage.
unused="$(ex_out "qm config 9000 2>/dev/null | grep -c '^unused'")"
ex_assert_eq "no loose disk is left unattached" "0" "${unused}"

attached="$(ex_out "qm config 9000 2>/dev/null | grep -c '^scsi0:'")"
ex_assert_eq "the imported disk is attached as scsi0" "1" "${attached}"

ex_summary
exit $?
