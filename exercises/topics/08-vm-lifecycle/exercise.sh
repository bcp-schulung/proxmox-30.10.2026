#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 08: The VM Lifecycle
# =============================================================================
# Verifies the web tier VM: its configuration and the lifecycle operations.
#
# NOTE: the guests of this lab are bare clones of the Debian cloud image.
# The image ships no configuration of its own - no network, no root
# password, no cloud-init drive - so the guest boots to a 'localhost'
# login prompt and the guest agent never comes up.
#
# That is the point of this topic, not an accident: the difference between
# 'qm stop' and 'qm shutdown' is only visible on a guest that has the
# agent. A bare guest has to be stopped with 'qm stop', which is the data
# loss version of the same operation.
#
# The checks that need a configured guest (the cloud-init drive, the
# hostname, the address, the guest agent) are the STUDENT'S task - see
# requirements.md. This script verifies what the starting state can show.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="08-vm-lifecycle"
EX_TITLE="Topic 08 - The VM Lifecycle"

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
# The VM 9201
# =============================================================================
ex_section "The VM ${NW_WEB_VM_ID}"

cfg="$(ex_vm_config "${NW_WEB_VM_ID}")"
ex_assert_not_empty "VM ${NW_WEB_VM_ID} exists" "${cfg}"

if [ -z "${cfg}" ]; then
    ex_error "VM ${NW_WEB_VM_ID} does not exist - the rest of the checks cannot run."
    ex_summary
    exit $?
fi

name="$(ex_out "qm config ${NW_WEB_VM_ID} 2>/dev/null | grep '^name:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM ${NW_WEB_VM_ID} is named ${NW_VM_NAMES%% *}" "${NW_VM_NAMES%% *}" "${name}"

scsi="$(ex_out "qm config ${NW_WEB_VM_ID} 2>/dev/null | grep '^scsi0:'")"
ex_assert_contains "VM ${NW_WEB_VM_ID} is on the local LVM-thin storage" "${scsi}" "local-lvm"
ex_assert_not_contains "VM ${NW_WEB_VM_ID} is a full clone, not a linked one" \
    "${scsi}" "base-9101"
ex_assert_contains "the disk has discard enabled" "${scsi}" "discard=on"
ex_assert_contains "the disk has an iothread" "${scsi}" "iothread=1"

cores="$(ex_out "qm config ${NW_WEB_VM_ID} 2>/dev/null | grep '^cores:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM ${NW_WEB_VM_ID} has 2 vCPU" "2" "${cores}"

memory="$(ex_out "qm config ${NW_WEB_VM_ID} 2>/dev/null | grep '^memory:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_ge "VM ${NW_WEB_VM_ID} has memory allocated" "${memory:-0}" "512"

net="$(ex_out "qm config ${NW_WEB_VM_ID} 2>/dev/null | grep '^net0:'")"
ex_assert_contains "VM ${NW_WEB_VM_ID} uses the virtio network device" "${net}" "virtio"
ex_assert_contains "VM ${NW_WEB_VM_ID} is on vmbr0" "${net}" "bridge=vmbr0"

ex_assert_contains "VM ${NW_WEB_VM_ID} uses virtio-scsi-single" "${cfg}" "virtio-scsi-single"

# The guest agent is enabled in the CONFIGURATION. Whether it answers is
# a different question - see the section below.
ex_assert_contains "the guest agent is enabled" "${cfg}" "enabled=1"

# The template of the guest is a template, and the guest is not.
ex_assert_not_contains "the guest is not a template" "${cfg}" "template:"

# =============================================================================
# The state
# =============================================================================
ex_section "The state"

status="$(ex_guest_status vm "${NW_WEB_VM_ID}")"
ex_assert_eq "VM ${NW_WEB_VM_ID} is running" "running" "${status}"

# A guest that has the agent answers it. The guests of this lab are bare
# clones of the cloud image and do not have it running yet - that is the
# student's task, and the reason the lifecycle below needs 'qm stop'.
if [ "${status}" = "running" ]; then
    if ex_ok "qm guest cmd ${NW_WEB_VM_ID} ping >/dev/null 2>&1"; then
        ex_pass "the guest agent answers"
    else
        ex_skip "the guest agent answers (the guest is a bare clone - see requirements.md)"
    fi
else
    ex_skip "the guest agent checks (the guest is not running)"
fi

# =============================================================================
# The lifecycle
# =============================================================================
ex_section "The lifecycle"

# The guest is stopped and started again below. If the script is
# interrupted between the two, the guest would be left down and the
# cluster would no longer be in the state the seminar started from. The
# trap makes the restart unconditional.
restart_guest() {
    if [ "$(ex_guest_status vm "${NW_WEB_VM_ID}")" != "running" ]; then
        ex_run "qm start ${NW_WEB_VM_ID} >/dev/null 2>&1" >/dev/null 2>&1 || true
    fi
}
trap restart_guest EXIT INT TERM

# Stopping the guest. 'qm shutdown' asks the guest to shut itself down
# and only works when the agent answers. Without the agent it times out,
# so 'qm stop' is used - the data loss version of the same operation.
#
# The guest is started again afterwards, so the exercise leaves the
# cluster in the state it found it in.
if ex_ok "qm stop ${NW_WEB_VM_ID} >/dev/null 2>&1"; then
    ex_pass "the guest is stopped"

    stopped="$(ex_guest_status vm "${NW_WEB_VM_ID}")"
    ex_assert_eq "the guest is stopped after the stop" "stopped" "${stopped}"

    if ex_ok "qm start ${NW_WEB_VM_ID} >/dev/null 2>&1"; then
        ex_pass "the guest starts again"

        running="$(ex_guest_status vm "${NW_WEB_VM_ID}")"
        ex_assert_eq "the guest is running again" "running" "${running}"
    else
        ex_fail "the guest starts again"
    fi
else
    ex_fail "the guest is stopped"
fi

# The guest was running before the exercise and has to be running after
# it. A stopped guest would change the state of the cluster.
ex_assert_eq "the guest is left in the state the exercise found it in" \
    "running" "$(ex_guest_status vm "${NW_WEB_VM_ID}")"

trap - EXIT INT TERM
restart_guest

ex_summary
exit $?
