#!/bin/bash
# =============================================================================
# ex-members.sh - run a command on the other cluster members
# =============================================================================
# Installed on a Proxmox node. It looks up the other cluster members and
# runs the given command on each of them over SSH.
#
# WHERE THE MEMBERS COME FROM
# ---------------------------
# The node names and their addresses are read from the corosync
# configuration, /etc/corosync/corosync.conf:
#
#     node {
#       name: pve2
#       nodeid: 2
#       quorum_votes: 1
#       ring0_addr: 10.20.0.241
#     }
#
# The corosync configuration is the one place that has BOTH the name and
# the address of every member. /etc/hosts only has the local node, and
# 'pvecm status' prints the addresses but not the names.
#
# Usage:
#   ex-members.sh <command>
#   ex-members.sh --names-only
#
# The output of every member is printed, preceded by a "--- <node> ---"
# header. A member that does not answer is skipped.
#
# With --names-only the script only prints the names of the other members,
# one per line, and runs no command.
# =============================================================================
set -u

NAMES_ONLY=0
if [ "${1:-}" = "--names-only" ]; then
    NAMES_ONLY=1
    shift
fi

CMD="${1:-}"
if [ "${NAMES_ONLY}" -eq 0 ] && [ -z "${CMD}" ]; then
    echo "usage: ex-members.sh <command>" >&2
    exit 2
fi

LOCAL="$(hostname)"
COROSYNC="/etc/corosync/corosync.conf"

# ---------------------------------------------------------------------------
# Read the members out of the corosync configuration.
#
# The configuration looks like this:
#
#     node {
#       name: pve2
#       nodeid: 2
#       quorum_votes: 1
#       ring0_addr: 10.20.0.241
#     }
#
# The name and the address are two lines of the same block, so the awk
# collects them together and prints them when the block ends.
# ---------------------------------------------------------------------------
members() {
    if [ -r "${COROSYNC}" ]; then
        awk '
            /^[ \t]*node[[:space:]]*\{/ { name=""; addr=""; innode=1; next }
            /^[ \t]*\}/ {
                if (innode && name != "" && addr != "") print name, addr
                innode=0; name=""; addr=""
                next
            }
            innode && /name:/ { gsub(/^[ \t]*name:[ \t]*/, ""); gsub(/[ \t]+$/, ""); name=$0; next }
            innode && /ring0_addr:/ { gsub(/^[ \t]*ring0_addr:[ \t]*/, ""); gsub(/[ \t]+$/, ""); addr=$0; next }
        ' "${COROSYNC}"
        return
    fi

    # The fallback: /etc/hosts. On a node that is not clustered yet this
    # is the only place the names are.
    if [ -r /etc/hosts ]; then
        awk '
            /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
                addr=$1
                for (i=2; i<=NF; i++) {
                    if ($i ~ /^pve[0-9]+$/) print $i, addr
                }
            }
        ' /etc/hosts
    fi
}

while read -r name addr; do
    [ -n "${name}" ] || continue
    [ -n "${addr}" ] || continue
    [ "${name}" = "${LOCAL}" ] && continue

    if [ "${NAMES_ONLY}" -eq 1 ]; then
        echo "${name}"
        continue
    fi

    echo "--- ${name} ---"
    # The '-n' is important: without it ssh reads from the standard
    # input and swallows the rest of the member list.
    ssh -n -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "root@${addr}" "${CMD}" 2>/dev/null
done < <(members)

exit 0
