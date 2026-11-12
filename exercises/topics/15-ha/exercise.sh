#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 15: High Availability
# =============================================================================
# Verifies the HA group, the managed resources, their state and the
# preconditions.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="15-ha"
EX_TITLE="Topic 15 - High Availability"

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
# The HA group
# =============================================================================
ex_section "The HA group"

group="$(ex_out "ha-manager group prod-nodes --output-format json 2>/dev/null")"
ex_assert_not_empty "the HA group prod-nodes exists" "${group}"

if [ -n "${group}" ]; then
    groupnodes="$(ex_out "ha-manager group prod-nodes --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.nodes // [] | join(\",\")'")"
    ex_assert_contains "the group contains pve1" "${groupnodes}" "pve1"
    ex_assert_contains "the group contains pve2" "${groupnodes}" "pve2"
    ex_assert_contains "the group contains pve3" "${groupnodes}" "pve3"
fi

# =============================================================================
# The managed resources
# =============================================================================
ex_section "The managed resources"

managed="$(ex_out "ha-manager status 2>/dev/null")"
ex_assert_not_empty "the HA status is readable" "${managed}"

ex_assert_contains "VM 9201 is HA managed" "${managed}" "9201"
ex_assert_contains "VM 9202 is HA managed" "${managed}" "9202"
ex_assert_contains "CT 301 is HA managed" "${managed}" "301"

# The state of each resource.
#
# The filter is built on the node, so the resource ID can be put into it
# directly. The ID contains a colon ('vm:9201'), which is safe inside a
# jq string.
for res in vm:9201 vm:9202 ct:301; do
    state="$(ex_out "ha-manager status --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.[] | select(.id == \"${res}\") | .status'")"
    ex_assert_eq "${res} is in the started state" "started" "${state}"
done

# A configured node.
configured="$(ex_out "ha-manager status --output-format json 2>/dev/null \
    | /opt/exercises/lib/ex-json.sh '[.[] | select(.type == \"vm\" or .type == \"ct\") | select(.status == \"started\") | .node] | length'")"
case "${configured}" in
    ''|*[!0-9]*) ex_skip "the configured nodes cannot be counted" ;;
    *)
        if [ "${configured}" -ge 3 ]; then
            ex_pass "the HA resources have a configured node"
        else
            ex_fail "the HA resources have a configured node (${configured} of 3)"
        fi
        ;;
esac

# =============================================================================
# The policies
# =============================================================================
ex_section "The policies"

for res in vm:9201 vm:9202 ct:301; do
    maxrestart="$(ex_out "ha-manager config --${res} --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.max_restart // 0'")"
    case "${maxrestart}" in
        ''|*[!0-9]*) ex_skip "the restart policy of ${res} cannot be read" ;;
        *)
            if [ "${maxrestart}" -ge 1 ]; then
                ex_pass "${res} has a restart policy (${maxrestart})"
            else
                ex_fail "${res} has a restart policy"
            fi
            ;;
    esac

    maxrelocate="$(ex_out "ha-manager config --${res} --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.max_relocate // 0'")"
    case "${maxrelocate}" in
        ''|*[!0-9]*) ex_skip "the relocate policy of ${res} cannot be read" ;;
        *)
            if [ "${maxrelocate}" -ge 1 ]; then
                ex_pass "${res} has a relocate policy (${maxrelocate})"
            else
                ex_fail "${res} has a relocate policy"
            fi
            ;;
    esac
done

# =============================================================================
# The preconditions
#
# HA needs shared storage: the resource has to be able to move to another
# node, and the target node has to be able to open the same volume. The
# guests of the lab start on the node-local 'local-lvm', so the exercise
# moves them to 'nfs-lab' first. The containers are on 'nfs-lab' already.
# =============================================================================
ex_section "The preconditions"

for id in ${NW_VM_IDS}; do
    disk="$(ex_out "qm config ${id} 2>/dev/null | grep '^scsi0:'")"
    ex_assert_contains "the managed VM ${id} is on the shared storage" "${disk}" "nfs-lab"
done

rootfs301="$(ex_out "pct config 301 2>/dev/null | grep '^rootfs:'")"
ex_assert_contains "the managed CT 301 is on the shared storage" "${rootfs301}" "nfs-lab"

ex_assert_eq "the cluster is quorate" "yes" "$(ex_quorate)"

# The HA service has to run on every node.
for node in $(ex_nodes); do
    svc="$(ex_run "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
        root@${node} 'systemctl is-active pve-ha' 2>/dev/null" 2>/dev/null | tr -d '\r' | head -1)"
    if [ -n "${svc}" ]; then
        ex_assert_eq "the pve-ha service runs on ${node}" "active" "${svc}"
    else
        ex_skip "the pve-ha service on ${node} cannot be checked"
    fi
done

ex_summary
exit $?
