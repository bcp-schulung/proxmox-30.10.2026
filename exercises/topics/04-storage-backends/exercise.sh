#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 04: Storage Backends
# =============================================================================
# Verifies the three storage definitions, their scope, their content types
# and - most importantly - that the NFS storage is genuinely shared.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="04-storage-backends"
EX_TITLE="Topic 04 - Storage Backends"

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
# The definitions
# =============================================================================
ex_section "The definitions"

status="$(ex_out "pvesm status 2>/dev/null")"

ex_assert_contains "local-lvm is defined" "${status}" "local-lvm"
ex_assert_contains "nfs-lab is defined" "${status}" "nfs-lab"
ex_assert_contains "pbs-main is defined" "${status}" "pbs-main"

for sid in local-lvm nfs-lab pbs-main; do
    line="$(ex_out "pvesm status --storage ${sid} 2>/dev/null | head -1")"
    ex_assert_contains "${sid} is active" "${line}" "active"
done

# =============================================================================
# The scope
# =============================================================================
ex_section "The scope"

cfg="$(ex_out "cat /etc/pve/storage.cfg 2>/dev/null")"

local_block="$(printf '%s' "${cfg}" | sed -n '/^storage local-lvm/,/^$/p')"
ex_assert_contains "local-lvm is an LVM-thin storage" "${local_block}" "type lvmthin"
ex_assert_contains "local-lvm uses the volume group pve" "${local_block}" "vgname pve"
ex_assert_contains "local-lvm uses the thin pool data" "${local_block}" "thinpool data"

nfs_block="$(printf '%s' "${cfg}" | sed -n '/^storage nfs-lab/,/^$/p')"
ex_assert_contains "nfs-lab is an NFS storage" "${nfs_block}" "type nfs"
ex_assert_contains "nfs-lab points at the NFS server" "${nfs_block}" "10.20.2.20"
ex_assert_contains "nfs-lab uses the /export/lab export" "${nfs_block}" "/export/lab"

pbs_block="$(printf '%s' "${cfg}" | sed -n '/^storage pbs-main/,/^$/p')"
ex_assert_contains "pbs-main is a PBS storage" "${pbs_block}" "type pbs"
ex_assert_contains "pbs-main points at the backup server" "${pbs_block}" "10.20.2.21"
ex_assert_contains "pbs-main uses the datastore main" "${pbs_block}" "datastore main"

# The shared storages have to be active on every node.
shared_nodes="$(ex_remote_members "pvesm status --storage nfs-lab | grep -c active" | grep -c '^[1-9]')"

if [ "${shared_nodes:-0}" -ge 2 ]; then
    ex_pass "nfs-lab is active on all three nodes (${shared_nodes} other nodes confirm it)"
else
    ex_fail "nfs-lab is active on all three nodes (${shared_nodes:-0} other nodes confirm it)"
fi

# =============================================================================
# The content types
# =============================================================================
ex_section "The content types"

for c in images rootdir iso vztmpl backup snippets; do
    ex_assert_contains "nfs-lab declares the content type '${c}'" \
        "${nfs_block}" "${c}"
done

ex_assert_contains "pbs-main declares the content type 'backup'" \
    "${pbs_block}" "backup"
ex_assert_not_contains "pbs-main does not declare 'images'" \
    "${pbs_block}" "images"

# =============================================================================
# The proof that the NFS storage is shared
# =============================================================================
ex_section "The proof that the NFS storage is shared"

marker="/mnt/pve/nfs-lab/.exercise-shared-test"

if ex_ok "echo 'shared storage test' > ${marker} 2>/dev/null"; then
    remote="$(ex_run "
        for ip in \$(awk '/^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+[[:space:]]+pve[0-9]/ {print \$1}' /etc/hosts); do
            n=\$(awk -v ip=\"\$ip\" '\$1==ip {for(i=2;i<=NF;i++) if(\$i ~ /^pve[0-9]+\$/) print \$i}' /etc/hosts | head -1)
            [ \"\$n\" = \"\$(hostname)\" ] && continue
            if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
                   \"root@\$n\" 'cat ${marker}' 2>/dev/null | grep -q 'shared storage test'; then
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
    ex_fail "the NFS storage is mounted on this node"
fi

ex_run "rm -f ${marker}" >/dev/null 2>&1
gone="$(ex_out "test -f ${marker} && echo yes || echo no")"
ex_assert_eq "the test file was removed again" "no" "${gone}"

# =============================================================================
# The capacity
# =============================================================================
ex_section "The capacity"

free="$(ex_out "pvesm status --storage local-lvm 2>/dev/null | awk 'NR==2 {print \$6}' | tr -d '%'")"
case "${free}" in
    ''|*[!0-9]*) ex_skip "the free space of local-lvm cannot be read" ;;
    *) ex_assert_ge "local-lvm reports free space" "${free}" "1" ;;
esac

nfs_free="$(ex_out "df -BG --output=avail /mnt/pve/nfs-lab 2>/dev/null | tail -1 | tr -d ' G'")"
case "${nfs_free}" in
    ''|*[!0-9]*) ex_skip "the free space of the NFS export cannot be read" ;;
    *) ex_assert_ge "the NFS export reports free space" "${nfs_free}" "1" ;;
esac

ex_summary
exit $?
