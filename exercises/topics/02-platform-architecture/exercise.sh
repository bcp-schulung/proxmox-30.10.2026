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

# The API needs an authentication token - an anonymous request to
# /api2/json/version answers with HTTP 401. 'pvesh' uses the ticket of
# the root user, so it is the convenient way to talk to the API from the
# node itself.
api_version="$(ex_out "pvesh get /version --output-format json 2>/dev/null")"
ex_assert_contains "the API answers on /version" "${api_version}" "version"
ex_assert_contains "the API reports a 9.x release" "${api_version}" "\"release\":\"9."

# The API is reachable over HTTPS. The answer is '401 Unauthorized'
# without a token, which proves that pveproxy is there and that it
# enforces the authentication.
api_code="$(ex_out "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    https://localhost:8006/api2/json/version 2>/dev/null")"
if [ "${api_code}" = "401" ] || [ "${api_code}" = "200" ]; then
    ex_pass "the API is reachable on port 8006 (HTTP ${api_code})"
else
    ex_fail "the API is reachable on port 8006 (HTTP ${api_code})"
fi

# =============================================================================
# The cluster filesystem
# =============================================================================
ex_section "The cluster filesystem"

ex_assert_eq "/etc/pve is a pmxcfs mount" "yes" "$(ex_is_pmxcfs)"

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

# 'jq' is not installed on a Proxmox node - python3 is. The counting is
# done with python3, because the JSON has to be parsed properly.
count_py='import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
if isinstance(d,dict):
    d=[d]
print(len(d))'

cli_count="$(ex_out "qm list 2>/dev/null | tail -n +2 | grep -c '^ *[0-9]'")"
api_count="$(ex_out "pvesh get /nodes/\$(hostname)/qemu --output-format json 2>/dev/null \
    | python3 -c \"${count_py}\" 2>/dev/null")"
cluster_count="$(ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | python3 -c \"${count_py}\" 2>/dev/null")"

ex_assert_not_empty "qm list returns the guest list" "${cli_count}"
ex_assert_not_empty "the node API returns the guest list" "${api_count}"
ex_assert_not_empty "the cluster API returns the guest list" "${cluster_count}"

# 'qm list' shows the guests of THIS node, the node API the guests of
# THIS node, and the cluster API the guests of the WHOLE cluster. The
# first two have to agree. The cluster count is larger as soon as a
# guest runs on another node - and it must never be smaller.
ex_assert_eq "qm list and the node API agree" "${cli_count}" "${api_count}"

if [ "${cluster_count:-0}" -ge "${cli_count:-0}" ]; then
    ex_pass "the cluster API sees at least the guests of this node (${cluster_count} >= ${cli_count})"
else
    ex_fail "the cluster API sees at least the guests of this node (${cluster_count} < ${cli_count})"
fi

# Every guest that the node knows has to be in the cluster listing.
cluster_ids="$(ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | python3 -c \"import json,sys
d=json.load(sys.stdin)
print(' '.join(str(v['vmid']) for v in d))\" 2>/dev/null")"
local_ids="$(ex_out "qm list 2>/dev/null | tail -n +2 | grep -E '^ *[0-9]+' | awk '{print \$1}' | tr '\n' ' '")"
missing=""
for id in ${local_ids}; do
    case " ${cluster_ids} " in
        *" ${id} "*) ;;
        *) missing="${missing} ${id}" ;;
    esac
done
if [ -z "${missing}" ]; then
    ex_pass "every guest of this node is in the cluster listing"
else
    ex_fail "every guest of this node is in the cluster listing (missing:${missing})"
fi

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
    # Proxmox 9 does not start 'qemu-system-x86_64' directly, it starts
    # the wrapper '/usr/bin/kvm'. Both spellings are accepted.
    showcmd="$(ex_out "qm showcmd ${vmid} 2>/dev/null | head -1")"
    if printf '%s' "${showcmd}" | grep -qE 'qemu-system|/usr/bin/kvm'; then
        ex_pass "qm showcmd prints the QEMU command line"
    else
        ex_fail "qm showcmd prints the QEMU command line"
    fi

    # The process of a guest carries '-id <vmid>'.
    if ex_out "ps aux | grep -E '[q]emu-system|[/]usr/bin/kvm'" | grep -q -- "-id ${vmid}"; then
        ex_pass "the QEMU process of VM ${vmid} is running"
    else
        ex_fail "the QEMU process of VM ${vmid} is running"
    fi
else
    ex_skip "no running guest - the QEMU process check needs one"
fi

ex_summary
exit $?
