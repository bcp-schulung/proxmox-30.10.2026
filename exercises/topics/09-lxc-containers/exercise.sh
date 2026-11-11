#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 09: LXC Containers
# =============================================================================
# Verifies the container template, the three Nordwind containers and their
# internal properties.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="09-lxc-containers"
EX_TITLE="Topic 09 - LXC Containers"

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
# The template
# =============================================================================
ex_section "The container template"

templates="$(ex_out "pvesm list nfs-lab --content vztmpl 2>/dev/null")"
ex_assert_contains "a Debian 13 template exists in the shared storage" \
    "${templates}" "debian-13-standard"

# =============================================================================
# The three containers
# =============================================================================
ex_section "The three containers"

for spec in "300:app01:30" "301:db01:40" "302:cache01:30"; do
    id="${spec%%:*}"
    rest="${spec#*:}"
    name="${rest%%:*}"
    tag="${rest##*:}"

    cfg="$(ex_ct_config "${id}")"
    if [ -z "${cfg}" ]; then
        ex_fail "CT ${id} exists"
        continue
    fi
    ex_pass "CT ${id} exists"

    hostname="$(ex_out "pct config ${id} 2>/dev/null | grep '^hostname:' | tr -s ' ' | cut -d' ' -f2")"
    ex_assert_eq "CT ${id} is named ${name}" "${name}" "${hostname}"

    # Unprivileged - the security property.
    unpriv="$(ex_out "pct config ${id} 2>/dev/null | grep '^unprivileged:' | tr -s ' ' | cut -d' ' -f2")"
    ex_assert_eq "CT ${id} is unprivileged" "1" "${unpriv}"

    features="$(ex_out "pct config ${id} 2>/dev/null | grep '^features:'")"
    ex_assert_contains "CT ${id} has nesting enabled" "${features}" "nesting=1"

    rootfs="$(ex_out "pct config ${id} 2>/dev/null | grep '^rootfs:'")"
    ex_assert_contains "CT ${id} is on the shared storage" "${rootfs}" "nfs-lab"

    net="$(ex_out "pct config ${id} 2>/dev/null | grep '^net0:'")"
    ex_assert_contains "CT ${id} is on vmbr0" "${net}" "bridge=vmbr0"
    ex_assert_contains "CT ${id} carries the VLAN tag ${tag}" "${net}" "tag=${tag}"

    status="$(ex_guest_status lxc "${id}")"
    ex_assert_eq "CT ${id} is running" "running" "${status}"

    if [ "${status}" = "running" ]; then
        # The container has no kernel of its own.
        kver="$(ex_out "pct exec ${id} -- cat /proc/version 2>/dev/null | head -1")"
        ex_assert_not_empty "CT ${id} reports a kernel version" "${kver}"
        ex_assert_contains "CT ${id} runs on the host kernel" "${kver}" "pve"

        # The cgroup carries the limits.
        cgroup="$(ex_out "pct exec ${id} -- cat /proc/1/cgroup 2>/dev/null | head -1")"
        ex_assert_not_empty "CT ${id} shows its cgroup membership" "${cgroup}"
        ex_assert_contains "CT ${id} is in its own cgroup scope" "${cgroup}" "lxc-${id}"

        # The network.
        addr="$(ex_out "pct exec ${id} -- ip -4 -brief addr show 2>/dev/null | grep -v ' lo ' | head -1")"
        ex_assert_contains "CT ${id} has an address on the overlay" "${addr}" "10.10."

        # The guest agent.
        agent="$(ex_out "pct exec ${id} -- systemctl is-active qemu-guest-agent 2>/dev/null | tr -d '\r'")"
        ex_assert_eq "the guest agent is running in CT ${id}" "active" "${agent}"
    else
        ex_skip "the internal checks of CT ${id} (the container is not running)"
    fi
done

ex_summary
exit $?
