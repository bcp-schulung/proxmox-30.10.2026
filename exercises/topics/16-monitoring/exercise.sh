#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 16: Monitoring and Notifications
# =============================================================================
# Verifies the metrics, the notification configuration, the task log and the
# monitoring workload.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="16-monitoring"
EX_TITLE="Topic 16 - Monitoring and Notifications"

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
# The metrics
# =============================================================================
ex_section "The metrics"

status="$(ex_out "pvesh get /cluster/status --output-format json 2>/dev/null")"
ex_assert_not_empty "the cluster status is readable" "${status}"

metrics="$(ex_out "pvesh get /cluster/metrics 2>/dev/null")"
ex_assert_not_empty "the cluster metrics are readable" "${metrics}"

node_status="$(ex_out "pvesh get /nodes/\$(hostname)/status --output-format json 2>/dev/null")"
ex_assert_not_empty "the node status is readable" "${node_status}"

guest_status="$(ex_out "pvesh get /nodes/\$(hostname)/qemu/100/status/current --output-format json 2>/dev/null")"
if [ -z "${guest_status}" ]; then
    guest_status="$(ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null")"
fi
ex_assert_not_empty "the guest status is readable" "${guest_status}"

# =============================================================================
# The notifications
# =============================================================================
ex_section "The notifications"

endpoints="$(ex_out "pvesh get /cluster/notifications/endpoints --output-format json 2>/dev/null")"
ex_assert_not_empty "a notification endpoint exists" "${endpoints}"

matchers="$(ex_out "pvesh get /cluster/notifications/matchers --output-format json 2>/dev/null")"
ex_assert_not_empty "a notification matcher exists" "${matchers}"

ex_assert_contains "the matcher refers to a notification template" \
    "${matchers}" "notification-template"

# =============================================================================
# The task log
# =============================================================================
ex_section "The task log"

log="$(ex_out "pvesh get /cluster/log --limit 50 --output-format json 2>/dev/null")"
ex_assert_not_empty "the task log returns entries" "${log}"

ex_assert_contains "the log entries carry the user" "${log}" "username"
ex_assert_contains "the log entries carry the command" "${log}" "cmd"

# =============================================================================
# The monitoring workload
# =============================================================================
ex_section "The monitoring workload"

ct302="$(ex_ct_config 302)"
ex_assert_not_empty "the operations tier workload CT 302 exists" "${ct302}"

hostname302="$(ex_out "pct config 302 2>/dev/null | grep '^hostname:' | tr -s ' ' | cut -d' ' -f2")"
ex_assert_eq "CT 302 is named cache01" "cache01" "${hostname302}"

status302="$(ex_guest_status lxc 302)"
ex_assert_eq "CT 302 is running" "running" "${status302}"

ex_summary
exit $?
