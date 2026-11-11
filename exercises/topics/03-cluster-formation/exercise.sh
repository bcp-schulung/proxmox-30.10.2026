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

ex_assert_eq "the cluster is called prod-cluster" "prod-cluster" "$(ex_cluster_name)"

ex_assert_eq "the quorum is 2" "2" "$(ex_quorum)"

nodes="$(ex_nodes | sort | tr '\n' ' ')"
ex_assert_contains "pve1 is a member" "${nodes}" "pve1"
ex_assert_contains "pve2 is a member" "${nodes}" "pve2"
ex_assert_contains "pve3 is a member" "${nodes}" "pve3"

# Every member is listed with a vote - a member that left has no votes
# any more, and a member that is only a name without a vote is not part
# of the ring.
member_count="$(ex_out "pvecm nodes 2>/dev/null \
    | grep -cE '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[a-zA-Z0-9._-]+'")"
ex_assert_eq "every member has a vote" "3" "${member_count}"

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

# The known hosts of the other nodes.
#
# After a cluster join the file lives in the cluster filesystem, in
# /etc/pve/priv/known_hosts. A node that is not clustered yet has a plain
# file in /root/.ssh/known_hosts instead - that is where the keys have to
# be put BEFORE the join, because 'pvecm add --use_ssh' verifies the host
# key of the seed node.
#
# Both locations are accepted.
#
# The entries are host keys - a hostname or an address, then the key
# type, then the key itself. The file may use a hostname ('pve1') or an
# address ('10.20.0.246'), and it may use the comma separated form for
# several names on one line. Counting the key types is the only thing
# that works for all of those forms.
known="$(ex_out "cat /etc/pve/priv/known_hosts /root/.ssh/known_hosts 2>/dev/null \
    | grep -cE '(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)[[:space:]]'")"
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

ex_assert_eq "/etc/pve is a pmxcfs mount" "yes" "$(ex_is_pmxcfs)"

marker="/etc/pve/.exercise-cluster-test"

if ex_ok "echo 'cluster filesystem test' > ${marker}"; then
    sleep 1
    visible="$(ex_out "cat ${marker} 2>/dev/null")"
    ex_assert_contains "the file is visible through the cluster filesystem" \
        "${visible}" "cluster filesystem test"

    # It has to be visible on the other nodes as well.
    #
    # The check runs on the node itself and uses the cluster's own SSH key
    # to look at the other members.
    remote="$(ex_remote_members "cat ${marker}")"

    if printf '%s' "${remote}" | grep -q 'cluster filesystem test'; then
        ex_pass "the file is visible on another node"
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
