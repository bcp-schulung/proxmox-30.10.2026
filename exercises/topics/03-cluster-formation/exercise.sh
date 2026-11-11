#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 03: Cluster Formation
# =============================================================================
# Verifies the cluster membership, the quorum, the SSH key distribution and
# the shared cluster filesystem.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="03-cluster-formation"
EX_TITLE="Topic 03 - Cluster Formation"

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
# The cluster
# =============================================================================
ex_section "The cluster"

status="$(ex_out "pvecm status 2>/dev/null")"

members="$(ex_member_count)"
ex_assert_eq "the cluster has three members" "3" "${members}"

ex_assert_eq "the cluster is quorate" "yes" "$(ex_quorate)"

cluster_name="$(printf '%s' "${status}" | grep -i 'cluster name' | tr -s ' ' | cut -d' ' -f4)"
if [ -z "${cluster_name}" ]; then
    cluster_name="$(ex_out "pvecm status 2>/dev/null | grep -i '^Cluster' | tr -s ' ' | cut -d' ' -f2")"
fi
ex_assert_eq "the cluster is called prod-cluster" "prod-cluster" "${cluster_name}"

quorum="$(printf '%s' "${status}" | grep -i 'quorum' | tr -s ' ' | cut -d' ' -f3)"
ex_assert_eq "the quorum is 2" "2" "${quorum}"

nodes="$(ex_nodes | sort | tr '\n' ' ')"
ex_assert_contains "pve1 is a member" "${nodes}" "pve1"
ex_assert_contains "pve2 is a member" "${nodes}" "pve2"
ex_assert_contains "pve3 is a member" "${nodes}" "pve3"

# Every member is in the state "Member", not "Left" or "Old".
member_states="$(ex_out "pvecm nodes 2>/dev/null | tail -n +2 | cut -d' ' -f4 | sort -u | tr '\n' ' '")"
ex_assert_eq "every member is in the state Member" "Member " "${member_states}"

# =============================================================================
# The services
# =============================================================================
ex_section "The services on this node"

for svc in pve-cluster corosync; do
    state="$(ex_out "systemctl is-active ${svc} 2>/dev/null")"
    ex_assert_eq "the ${svc} service is running" "active" "${state}"
done

# =============================================================================
# The SSH keys
# =============================================================================
ex_section "The SSH keys"

ex_assert "a private SSH key exists in /root/.ssh" \
    "ls /root/.ssh/ 2>/dev/null | grep -qE '^id_(ed25519|rsa)$'"

known="$(ex_out "grep -c '10.20.0' /root/.ssh/known_hosts 2>/dev/null")"
if ! printf '%s' "${known}" | grep -qE '^[0-9]+$'; then
    ex_fail "the known_hosts file contains the other nodes"
elif [ "${known}" -ge 2 ]; then
    ex_pass "the known_hosts file contains the other nodes (${known} entries)"
else
    ex_fail "the known_hosts file contains the other nodes (only ${known})"
fi

# =============================================================================
# The shared configuration
# =============================================================================
ex_section "The shared configuration"

fstype="$(ex_out "stat -f -c '%T' /etc/pve 2>/dev/null")"
ex_assert_eq "/etc/pve is a pmxcfs mount" "fuse.pmxcfs" "${fstype}"

marker="/etc/pve/.exercise-cluster-test"

if ex_ok "echo 'cluster filesystem test' > ${marker}"; then
    sleep 1
    visible="$(ex_out "cat ${marker} 2>/dev/null")"
    ex_assert_contains "the file is visible through the cluster filesystem" \
        "${visible}" "cluster filesystem test"

    # It has to be visible on the other nodes as well.
    remote="$(ex_run "
        for n in \$(pvecm nodes | awk 'NR>1 && \\\$3 ~ /^[0-9]+\\\$/ {print \\\$3}'); do
            [ \"\$n\" = \"\$(hostname)\" ] && continue
            if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
                   \"root@\$n\" 'cat ${marker}' 2>/dev/null | grep -q 'cluster filesystem test'; then
                echo \"\$n\"
                break
            fi
        done" 2>/dev/null)"

    if [ -n "${remote}" ]; then
        ex_pass "the file is visible on another node (${remote})"
    else
        ex_fail "the file is visible on another node"
    fi

    ex_run "rm -f ${marker}" >/dev/null 2>&1
else
    ex_fail "the cluster filesystem is writable"
fi

ex_run "rm -f ${marker}" >/dev/null 2>&1
gone="$(ex_out "test -f ${marker} && echo yes || echo no")"
ex_assert_eq "the test file was removed again" "no" "${gone}"

ex_summary
exit $?
