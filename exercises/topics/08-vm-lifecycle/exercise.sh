#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 08: The VM Lifecycle
# =============================================================================
# Verifies the web tier VM: its configuration, the guest agent and the
# lifecycle operations.
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
# The VM 100
# =============================================================================
ex_section "The VM 100"

cfg="$(ex_vm_config 100)"
ex_assert_not_empty "VM 100 exists" "${cfg}"

if [ -z "${cfg}" ]; then
    ex_error "VM 100 does not exist - the rest of the checks cannot run."
    ex_summary
    exit $?
fi

name="$(ex_out "qm config 100 2>/dev/null | grep '^name:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM 100 is named web01" "web01" "${name}"

scsi="$(ex_out "qm config 100 2>/dev/null | grep '^scsi0:'")"
ex_assert_contains "VM 100 is on the shared storage" "${scsi}" "nfs-lab"
ex_assert_not_contains "VM 100 is a full clone, not a linked one" \
    "${scsi}" "base-9000"
ex_assert_contains "the disk has discard enabled" "${scsi}" "discard=on"
ex_assert_contains "the disk has an iothread" "${scsi}" "iothread=1"

cores="$(ex_out "qm config 100 2>/dev/null | grep '^cores:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM 100 has 2 vCPU" "2" "${cores}"

memory="$(ex_out "qm config 100 2>/dev/null | grep '^memory:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "VM 100 has 4096 MB of memory" "4096" "${memory}"

net="$(ex_out "qm config 100 2>/dev/null | grep '^net0:'")"
ex_assert_contains "VM 100 uses the virtio network device" "${net}" "virtio"
ex_assert_contains "VM 100 is on vmbr0" "${net}" "bridge=vmbr0"
ex_assert_contains "VM 100 carries the VLAN tag 20" "${net}" "tag=20"

ex_assert_contains "VM 100 uses virtio-scsi-single" "${cfg}" "virtio-scsi-single"
ex_assert_contains "the guest agent is enabled" "${cfg}" "enabled=1"

ex_assert_contains "VM 100 has its own cloud-init drive" "${cfg}" "cloudinit"

# =============================================================================
# The guest agent
# =============================================================================
ex_section "The guest agent"

status="$(ex_guest_status vm 100)"
ex_assert_eq "VM 100 is running" "running" "${status}"

if [ "${status}" = "running" ]; then
    if ex_ok "qm guest cmd 100 ping >/dev/null 2>&1"; then
        ex_pass "the guest agent answers"
    else
        ex_fail "the guest agent answers"
    fi

    agent_state="$(ex_out "qm guest exec 100 -- systemctl is-active qemu-guest-agent 2>/dev/null | tr -d '\r'")"
    ex_assert_eq "the guest agent is active inside the guest" "active" "${agent_state}"

    guest_hostname="$(ex_out "qm guest exec 100 -- hostname 2>/dev/null | tr -d '\r'")"
    ex_assert_eq "the guest reports the hostname web01" "web01" "${guest_hostname}"

    guest_addr="$(ex_out "qm guest exec 100 -- ip -4 -brief addr show 2>/dev/null | grep -v ' lo ' | head -1")"
    ex_assert_contains "the guest has an address on the overlay" "${guest_addr}" "10.10."
else
    ex_skip "the guest agent checks (the guest is not running)"
fi

# =============================================================================
# The lifecycle
# =============================================================================
ex_section "The lifecycle"

# The guest has to be able to shut down cleanly, which proves the agent
# works. The check restarts it afterwards.
if ex_ok "qm shutdown 100 --timeout 60 >/dev/null 2>&1"; then
    ex_pass "the guest shuts down cleanly"

    stopped="$(ex_guest_status vm 100)"
    ex_assert_eq "the guest is stopped after the shutdown" "stopped" "${stopped}"

    if ex_ok "qm start 100 >/dev/null 2>&1"; then
        ex_pass "the guest starts again"

        # Give the agent a moment to come up.
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
            ex_ok "qm guest cmd 100 ping >/dev/null 2>&1" && break
            sleep 5
        done

        if ex_ok "qm guest cmd 100 ping >/dev/null 2>&1"; then
            ex_pass "the guest agent answers after the restart"
        else
            ex_fail "the guest agent answers after the restart"
        fi
    else
        ex_fail "the guest starts again"
    fi
else
    ex_fail "the guest shuts down cleanly"
fi

ex_summary
exit $?
