#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 14: Backup and Restore with PBS
# =============================================================================
# Verifies the backup storage, the backup job, the backups in the datastore
# and - most importantly - the restore.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="14-backup-pbs"
EX_TITLE="Topic 14 - Backup and Restore with PBS"

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
# The storage
# =============================================================================
ex_section "The backup storage"

status="$(ex_out "pvesm status --storage pbs-main 2>/dev/null | head -1")"
ex_assert_contains "the storage pbs-main exists" "${status}" "pbs-main"
ex_assert_contains "the storage pbs-main is active" "${status}" "active"

cfg="$(ex_out "cat /etc/pve/storage.cfg 2>/dev/null")"
pbs_block="$(printf '%s' "${cfg}" | sed -n '/^storage pbs-main/,/^$/p')"
ex_assert_contains "the storage points at the backup server" "${pbs_block}" "10.20.2.21"
ex_assert_contains "the storage uses the datastore main" "${pbs_block}" "datastore main"
ex_assert_contains "the storage declares the content type backup" "${pbs_block}" "backup"

# =============================================================================
# The backup job
# =============================================================================
ex_section "The backup job"

jobs="$(ex_out "pvesh get /cluster/backup --output-format json 2>/dev/null")"
ex_assert_not_empty "a backup job exists" "${jobs}"

ex_assert_contains "the job targets pbs-main" "${jobs}" "pbs-main"
ex_assert_contains "the job covers VM 9201" "${jobs}" "100"
ex_assert_contains "the job covers CT 301" "${jobs}" "301"
ex_assert_contains "the job runs in snapshot mode" "${jobs}" "snapshot"
ex_assert_contains "the job is enabled" "${jobs}" "\"enabled\":1"
ex_assert_contains "the job has a schedule" "${jobs}" "schedule"

ex_assert_contains "the retention keeps 7 daily backups" "${jobs}" "\"keep-daily\":7"
ex_assert_contains "the retention keeps 4 weekly backups" "${jobs}" "\"keep-weekly\":4"
ex_assert_contains "the retention keeps 6 monthly backups" "${jobs}" "\"keep-monthly\":6"

# =============================================================================
# The backups
# =============================================================================
ex_section "The backups in the datastore"

backups="$(ex_out "pvesm list pbs-main --content backup 2>/dev/null")"
ex_assert_contains "a backup of VM 9201 exists" "${backups}" "vm/100"
ex_assert_contains "a backup of CT 301 exists" "${backups}" "lxc/301"

# =============================================================================
# The restore
# =============================================================================
ex_section "The restore"

restored="$(ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | /opt/exercises/lib/ex-json.sh '.[] | select(.vmid >= 190) | .vmid' | sort -n | head -1")"

if [ -n "${restored}" ]; then
    ex_pass "a restored VM exists (VMID ${restored})"

    rcfg="$(ex_vm_config "${restored}")"
    rdisk="$(ex_out "qm config ${restored} 2>/dev/null | grep '^scsi0:'")"
    ex_assert_contains "the restored VM is on the shared storage" "${rdisk}" "nfs-lab"

    rstatus="$(ex_guest_status vm "${restored}")"
    ex_assert_eq "the restored VM is running" "running" "${rstatus}"

    if [ "${rstatus}" = "running" ]; then
        if ex_ok "qm guest cmd ${restored} ping >/dev/null 2>&1"; then
            ex_pass "the guest agent answers in the restored VM"
        else
            ex_fail "the guest agent answers in the restored VM"
        fi
    else
        ex_skip "the guest agent check (the restored VM is not running)"
    fi
else
    ex_fail "a restored VM exists (VMID >= 190)"
fi

ex_summary
exit $?
