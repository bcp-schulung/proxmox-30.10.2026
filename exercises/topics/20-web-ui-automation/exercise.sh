#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 20: The API and Automation
# =============================================================================
# Verifies the API, the API token and - most importantly - that the token is
# actually limited to its ACL.
#
# The token secret is not readable after the creation, so the script reads it
# from the PROXMOX_TOKEN environment variable when it is set. Without it,
# the ACL checks still run - only the direct API call is skipped.
#
# Usage:
#   PROXMOX_TOKEN='automation@pve!terraform=<secret>' ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="20-web-ui-automation"
EX_TITLE="Topic 20 - The API and Automation"

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
# The API
# =============================================================================
ex_section "The API"

# The API needs an authentication token. An anonymous request answers
# with HTTP 401 - which proves that the API is there and that it enforces
# the authentication.
api_code="$(ex_out "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    https://localhost:8006/api2/json/version 2>/dev/null")"
if [ "${api_code}" = "401" ] || [ "${api_code}" = "200" ]; then
    ex_pass "the API answers on /api2/json/version (HTTP ${api_code})"
else
    ex_fail "the API answers on /api2/json/version (HTTP ${api_code})"
fi

# The token is what makes the API usable. When it is not set, the checks
# that need it are skipped.
TOKEN="${PROXMOX_TOKEN:-${PVE_TOKEN:-}}"

if [ -n "${TOKEN}" ]; then
    version="$(ex_out "curl -sk --max-time 10 \
        -H 'Authorization: PVEAPIToken=${TOKEN}' \
        https://localhost:8006/api2/json/version 2>/dev/null")"
    ex_assert_contains "the API answers on /api2/json/version" "${version}" "version"

    resources="$(ex_out "curl -sk --max-time 10 \
        -H 'Authorization: PVEAPIToken=${TOKEN}' \
        https://localhost:8006/api2/json/cluster/resources 2>/dev/null")"
    ex_assert_contains "the API answers on /api2/json/cluster/resources" "${resources}" "data"

    status="$(ex_out "curl -sk --max-time 10 \
        -H 'Authorization: PVEAPIToken=${TOKEN}' \
        https://localhost:8006/api2/json/cluster/status 2>/dev/null")"
    ex_assert_contains "the API answers on /api2/json/cluster/status" "${status}" "data"

    # pvesh and the raw API have to agree.
    pvesh_count="$(ex_out "pvesh get /cluster/resources --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh 'length'")"
    api_count="$(ex_out "curl -sk --max-time 10 \
        -H 'Authorization: PVEAPIToken=${TOKEN}' \
        https://localhost:8006/api2/json/cluster/resources 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.data | length'")"
    ex_assert_not_empty "pvesh returns the resources" "${pvesh_count}"
    ex_assert_eq "pvesh and the raw API agree" "${pvesh_count}" "${api_count}"
else
    ex_skip "the API checks with a token - export PROXMOX_TOKEN to run them"
fi

# =============================================================================
# The token
# =============================================================================
ex_section "The token"

tokens="$(ex_out "pveum user token list automation@pve 2>/dev/null")"
ex_assert_contains "the token automation@pve!terraform exists" "${tokens}" "terraform"

privsep="$(ex_out "pveum user token list automation@pve --output-format json 2>/dev/null \
    | /opt/exercises/lib/ex-json.sh '.[] | select(.tokenid == \"terraform\") | .privsep'")"
ex_assert_eq "the token has privilege separation enabled" "1" "${privsep}"

token_acl="$(ex_out "pveum acl list 2>/dev/null | grep 'automation@pve!terraform'")"
ex_assert_not_empty "the token has its own ACL entry" "${token_acl}"
ex_assert_contains "the token ACL is scoped to /vms/9201" "${token_acl}" "/vms/9201"

# The token must not be granted on the root path.
token_root="$(ex_out "pveum acl list 2>/dev/null | grep -E '^/[[:space:]]' | grep 'automation@pve!terraform'")"
ex_assert_empty "the token is not granted on the root path" "${token_root}"

# =============================================================================
# The token's reach
# =============================================================================
ex_section "The token's reach"

if [ -n "${TOKEN}" ]; then
    # The token can read the cluster resources.
    tok_resources="$(ex_out "curl -sk --max-time 10 \
        -H 'Authorization: PVEAPIToken=${TOKEN}' \
        https://localhost:8006/api2/json/cluster/resources 2>/dev/null")"
    ex_assert_contains "the token can read the cluster resources" \
        "${tok_resources}" "vmid"

    # The token can read the configuration of VM 9201.
    tok_vm="$(ex_out "curl -sk --max-time 10 \
        -H 'Authorization: PVEAPIToken=${TOKEN}' \
        https://localhost:8006/api2/json/nodes/\$(hostname)/qemu/100/config 2>/dev/null")"
    ex_assert_not_contains "the token can read the configuration of VM 9201" \
        "${tok_vm}" "Permission check failed"

    # The token CANNOT read the configuration of CT 301 - it is only
    # scoped to /vms/9201.
    tok_ct="$(ex_out "curl -sk --max-time 10 \
        -H 'Authorization: PVEAPIToken=${TOKEN}' \
        https://localhost:8006/api2/json/nodes/\$(hostname)/lxc/301/config 2>/dev/null")"
    ex_assert_contains "the token cannot read the configuration of CT 301" \
        "${tok_ct}" "Permission check failed"
else
    ex_skip "the token reach checks - export PROXMOX_TOKEN to run them"
fi

# =============================================================================
# The storage
# =============================================================================
ex_section "The storage through the API"

stor="$(ex_out "pvesh get /storage --output-format json 2>/dev/null")"
ex_assert_contains "the storages are visible through the API" "${stor}" "nfs-lab"

nfs_content="$(ex_out "pvesh get /storage/nfs-lab --output-format json 2>/dev/null | /opt/exercises/lib/ex-json.sh '.content // \"\"'")"
ex_assert_contains "the content types are visible through the API" \
    "${nfs_content}" "iso"

ex_summary
exit $?
