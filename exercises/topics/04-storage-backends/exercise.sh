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

for sid in local-lvm nfs-lab; do
    # 'pvesm status --storage <id>' prints a header line first, so the
    # storage itself is on the second line.
    # The closing parenthesis of the command may not sit directly behind
    # a single quote inside a '$( ... )' - bash ends the substitution at
    # the wrong place. The 'sed' therefore gets its argument without
    # quotes.
    line="$(ex_out "pvesm status --storage ${sid} 2>/dev/null | sed -n 2p")"
    ex_assert_contains "${sid} is active" "${line}" "active"
done

# The backup server is a separate machine. When it is not part of the
# lab, the PBS part of the exercise cannot be checked - and then it is
# skipped, not failed. A missing backup server is not a mistake of the
# student.
pbs_available=0
if ex_out "pvesm status --storage pbs-main 2>/dev/null | grep -q pbs-main"; then
    pbs_available=1
    ex_pass "pbs-main is defined"
    line="$(ex_out "pvesm status --storage pbs-main 2>/dev/null | sed -n 2p")"
    ex_assert_contains "pbs-main is active" "${line}" "active"
else
    ex_skip "the backup server is not part of this lab - the PBS checks are skipped"
fi

# =============================================================================
# The scope
# =============================================================================
ex_section "The scope"

cfg="$(ex_out "cat /etc/pve/storage.cfg 2>/dev/null")"

local_block="$(printf '%s' "${cfg}" | sed -n '/^\(storage local-lvm\|lvmthin: local-lvm\)/,/^$/p')"
ex_assert_contains "local-lvm is an LVM-thin storage" "${local_block}" "lvmthin"
ex_assert_contains "local-lvm uses the volume group pve" "${local_block}" "vgname pve"
ex_assert_contains "local-lvm uses the thin pool data" "${local_block}" "thinpool data"

# The storage configuration has two formats:
#
#   storage nfs-lab            the old format
#       type nfs
#       server 10.20.2.20
#
#   nfs: nfs-lab                the format of Proxmox VE 8 and 9
#       server 10.20.2.20
#
# The type is the prefix in the second format. Both are accepted here -
# what matters is the result.
nfs_block="$(printf '%s' "${cfg}" | sed -n '/^\(storage nfs-lab\|nfs: nfs-lab\)/,/^$/p')"
ex_assert_contains "nfs-lab is an NFS storage" "${nfs_block}" "nfs"
ex_assert_contains "nfs-lab points at the NFS server" "${nfs_block}" "10.20.2.20"
ex_assert_contains "nfs-lab uses the /export/lab export" "${nfs_block}" "/export/lab"

pbs_block="$(printf '%s' "${cfg}" | sed -n '/^\(storage pbs-main\|pbs: pbs-main\)/,/^$/p')"
if [ "${pbs_available}" -eq 1 ]; then
    ex_assert_contains "pbs-main is a PBS storage" "${pbs_block}" "pbs"
    ex_assert_contains "pbs-main points at the backup server" "${pbs_block}" "10.20.2.21"
    ex_assert_contains "pbs-main uses the datastore main" "${pbs_block}" "datastore main"
else
    ex_skip "pbs-main is not defined - the backup server is not part of this lab"
fi

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

if [ "${pbs_available}" -eq 1 ]; then
    ex_assert_contains "pbs-main declares the content type 'backup'" \
        "${pbs_block}" "backup"
    ex_assert_not_contains "pbs-main does not declare 'images'" \
        "${pbs_block}" "images"
else
    ex_skip "the content type of pbs-main cannot be checked"
fi

# =============================================================================
# The proof that the NFS storage is shared
# =============================================================================
ex_section "The proof that the NFS storage is shared"

marker="/mnt/pve/nfs-lab/.exercise-shared-test"

if ex_ok "echo 'shared storage test' > ${marker} 2>/dev/null"; then
    remote="$(ex_remote_members "cat ${marker}" | grep -c 'shared storage test')"

    if [ "${remote:-0}" -gt 0 ]; then
        ex_pass "the file is visible on another node (${remote} other nodes confirm it)"
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
