#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 02: The Platform Architecture
# =============================================================================
# Verifies the service map, the API equivalence and the cluster filesystem
# replication.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="02-platform-architecture"
EX_TITLE="Topic 02 - The Platform Architecture"

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
# The services
# =============================================================================
ex_section "The services"

for svc in pveproxy pvedaemon pvestatd pve-cluster corosync; do
    state="$(ex_out "systemctl is-active ${svc} 2>/dev/null")"
    ex_assert_eq "the ${svc} service is running" "active" "${state}"
done

listen="$(ex_out "ss -tln 2>/dev/null | grep ':8006'")"
ex_assert_contains "pveproxy listens on port 8006" "${listen}" "8006"

api_version="$(ex_out "curl -sk --max-time 10 https://localhost:8006/api2/json/version 2>/dev/null")"
ex_assert_contains "the API answers on /api2/json/version" "${api_version}" "version"
ex_assert_contains "the API reports a 9.x release" "${api_version}" "\"release\":\"9."

# =============================================================================
# The cluster filesystem
# =============================================================================
ex_section "The cluster filesystem"

fstype="$(ex_out "stat -f -c '%T' /etc/pve 2>/dev/null")"
ex_assert_eq "/etc/pve is a pmxcfs mount" "fuse.pmxcfs" "${fstype}"

ex_assert "the directory /etc/pve/qemu-server exists" \
    "test -d /etc/pve/qemu-server"
ex_assert "the directory /etc/pve/lxc exists" \
    "test -d /etc/pve/lxc"
ex_assert "the file /etc/pve/storage.cfg exists" \
    "test -f /etc/pve/storage.cfg"
ex_assert "the directory /etc/pve/priv exists" \
    "test -d /etc/pve/priv"

# The secret directory must not be readable by everyone.
priv_mode="$(ex_out "stat -c '%a' /etc/pve/priv 2>/dev/null")"
if [ -n "${priv_mode}" ]; then
    # The last digit is the permission of "other".
    other="${priv_mode: -1}"
    if [ "${other}" = "0" ] || [ "${other}" = "1" ] || [ "${other}" = "2" ] \
       || [ "${other}" = "3" ] || [ "${other}" = "4" ] || [ "${other}" = "5" ]; then
        ex_pass "/etc/pve/priv is not readable by other (mode ${priv_mode})"
    else
        ex_fail "/etc/pve/priv is not readable by other (mode ${priv_mode})"
    fi
else
    ex_skip "the mode of /etc/pve/priv cannot be read"
fi

# =============================================================================
# The three ways to do the same thing
# =============================================================================
ex_section "The same operation, three ways"

cli_count="$(ex_out "qm list 2>/dev/null | tail -n +2 | grep -c '^ *[0-9]'")"
api_count="$(ex_out "pvesh get /nodes/\$(hostname)/qemu --output-format json 2>/dev/null | jq 'length' 2>/dev/null")"
cluster_count="$(ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq 'length' 2>/dev/null")"

ex_assert_not_empty "qm list returns the guest list" "${cli_count}"
ex_assert_not_empty "the node API returns the guest list" "${api_count}"
ex_assert_not_empty "the cluster API returns the guest list" "${cluster_count}"

ex_assert_eq "qm list and the node API agree" "${cli_count}" "${api_count}"
ex_assert_eq "qm list and the cluster API agree" "${cli_count}" "${cluster_count}"

# =============================================================================
# The replication
# =============================================================================
ex_section "The replication"

marker="/etc/pve/.exercise-replication-test"

if ex_ok "echo 'replication test' > ${marker}"; then
    # Give the replication a moment.
    sleep 1
    visible="$(ex_out "cat ${marker} 2>/dev/null")"
    ex_assert_contains "the file is visible through the cluster filesystem" \
        "${visible}" "replication test"
    ex_run "rm -f ${marker}" >/dev/null 2>&1
else
    ex_fail "the cluster filesystem is writable"
fi

# The file must be gone again.
ex_run "rm -f ${marker}" >/dev/null 2>&1
gone="$(ex_out "test -f ${marker} && echo yes || echo no")"
ex_assert_eq "the test file was removed again" "no" "${gone}"

# =============================================================================
# The QEMU process
# =============================================================================
ex_section "The QEMU process"

running="$(ex_out "qm list 2>/dev/null | grep -c 'running'")"
if [ "${running:-0}" -gt 0 ]; then
    vmid="$(ex_out "qm list 2>/dev/null | awk '/running/ {print \$1; exit}'")"
    showcmd="$(ex_out "qm showcmd ${vmid} 2>/dev/null | head -1")"
    ex_assert_contains "qm showcmd prints the QEMU command line" "${showcmd}" "qemu-system"

    if ex_out "ps aux | grep '[q]emu-system'" | grep -q "guest=${vmid}"; then
        ex_pass "the QEMU process of VM ${vmid} is running"
    else
        ex_fail "the QEMU process of VM ${vmid} is running"
    fi
else
    ex_skip "no running guest - the QEMU process check needs one"
fi

ex_summary
exit $?
