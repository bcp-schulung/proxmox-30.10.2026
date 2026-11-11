#!/bin/bash
# =============================================================================
# ex-members.sh - run a command on the other cluster members
# =============================================================================
# Installed on a Proxmox node. It looks up the other cluster members and
# runs the given command on each of them over SSH.
#
# The node names alone do not resolve on a Proxmox node, and the addresses
# are not in the cluster configuration either. The reliable source is
# /etc/hosts, which maps every node name to its management address.
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

# The node name -> address mapping from /etc/hosts.
while read -r ip rest; do
    case "${ip}" in
        ''|'#'*) continue ;;
    esac
    # The names are the fields that look like a node name.
    for name in ${rest}; do
        case "${name}" in
            pve[0-9]*) ;;
            *) continue ;;
        esac
        [ "${name}" = "${LOCAL}" ] && continue
        printf '%s %s\n' "${name}" "${ip}"
    done
done < /etc/hosts | sort -u | while read -r name ip; do
    if [ "${NAMES_ONLY}" -eq 1 ]; then
        echo "${name}"
        continue
    fi
    echo "--- ${name} ---"
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "root@${ip}" "${CMD}" 2>/dev/null
done

exit 0
