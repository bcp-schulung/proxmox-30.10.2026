#!/usr/bin/env bash
# =============================================================================
# exercise.sh - Topic 06: Identity, Roles and Access Control
# =============================================================================
# Verifies the realm, the user, the narrow custom role, the scoped ACL and
# the privilege separated API token.
#
# Usage:
#   ./exercise.sh
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="06-identity-rbac"
EX_TITLE="Topic 06 - Identity, Roles and Access Control"

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
# The realm and the user
# =============================================================================
ex_section "The realm and the user"

realms="$(ex_out "pveum realm list 2>/dev/null")"
ex_assert_contains "the realm ad-corp exists" "${realms}" "ad-corp"

users="$(ex_out "pveum user list 2>/dev/null")"
ex_assert_contains "the user jsmith@ad-corp exists" "${users}" "jsmith@ad-corp"

# =============================================================================
# The role
# =============================================================================
ex_section "The role"

role_line="$(ex_out "pveum role list 2>/dev/null | grep -E '^VM-Operator'")"
ex_assert_not_empty "the role VM-Operator exists" "${role_line}"

if [ -n "${role_line}" ]; then
    privs="$(printf '%s' "${role_line}" | cut -d' ' -f3-)"

    ex_assert_contains "the role grants VM.Console" "${privs}" "VM.Console"
    ex_assert_contains "the role grants VM.PowerMgmt" "${privs}" "VM.PowerMgmt"
    ex_assert_contains "the role grants VM.Monitor" "${privs}" "VM.Monitor"

    # The negative checks - the point of a narrow custom role.
    ex_assert_not_contains "the role does not grant VM.Config.Disk" \
        "${privs}" "VM.Config.Disk"
    ex_assert_not_contains "the role does not grant VM.Config.CDROM" \
        "${privs}" "VM.Config.CDROM"
    ex_assert_not_contains "the role does not grant VM.Config.Options" \
        "${privs}" "VM.Config.Options"
    ex_assert_not_contains "the role does not grant VM.Allocate" \
        "${privs}" "VM.Allocate"
    ex_assert_not_contains "the role does not grant Sys.Audit" \
        "${privs}" "Sys.Audit"
    ex_assert_not_contains "the role does not grant Sys.Modify" \
        "${privs}" "Sys.Modify"
else
    ex_fail "the role VM-Operator exists"
fi

# =============================================================================
# The ACL
# =============================================================================
ex_section "The ACL"

acl="$(ex_out "pveum acl list 2>/dev/null")"

ex_assert_contains "an ACL grants VM-Operator to jsmith@ad-corp on /vms/9201" \
    "${acl}" "/vms/9201"
ex_assert_contains "the ACL names the user" "${acl}" "jsmith@ad-corp"
ex_assert_contains "the ACL names the role" "${acl}" "VM-Operator"

ex_assert_contains "an ACL grants VM-Operator to jsmith@ad-corp on /vms/9202" \
    "${acl}" "/vms/9202"

# The scope must not be broadened.
root_entry="$(ex_out "pveum acl list 2>/dev/null | grep -E '^/[[:space:]]'")"
ex_assert_not_contains "no ACL for jsmith on the root path" \
    "${root_entry}" "jsmith@ad-corp"

vms_entry="$(ex_out "pveum acl list 2>/dev/null | grep -E '^/vms[[:space:]]'")"
ex_assert_not_contains "no ACL for jsmith on the /vms path" \
    "${vms_entry}" "jsmith@ad-corp"

# =============================================================================
# The effective permissions
# =============================================================================
ex_section "The effective permissions"

perms="$(ex_out "pveum user permissions jsmith@ad-corp 2>/dev/null")"
ex_assert_not_empty "the effective permissions are readable" "${perms}"
ex_assert_contains "jsmith has the console privilege" "${perms}" "VM.Console"
ex_assert_contains "jsmith has the power management privilege" "${perms}" "VM.PowerMgmt"
ex_assert_contains "jsmith has the monitor privilege" "${perms}" "VM.Monitor"

ex_assert_not_contains "jsmith does not have Sys.Audit" "${perms}" "Sys.Audit"
ex_assert_not_contains "jsmith does not have VM.Config.Disk" "${perms}" "VM.Config.Disk"
ex_assert_not_contains "jsmith does not have VM.Allocate" "${perms}" "VM.Allocate"

# =============================================================================
# The API token
# =============================================================================
ex_section "The API token"

tokens="$(ex_out "pveum user token list automation@pve 2>/dev/null")"
ex_assert_contains "the token terraform exists" "${tokens}" "terraform"

privsep="$(ex_out "pveum user token list automation@pve --output-format json 2>/dev/null \
    | /opt/exercises/lib/ex-json.sh '.[] | select(.tokenid == \"terraform\") | .privsep'")"
ex_assert_eq "the token has privilege separation enabled" "1" "${privsep}"

token_acl="$(ex_out "pveum acl list 2>/dev/null | grep 'automation@pve!terraform'")"
ex_assert_not_empty "the token has its own ACL entry" "${token_acl}"
ex_assert_contains "the token ACL is scoped to /vms/9201" "${token_acl}" "/vms/9201"
ex_assert_contains "the token ACL grants the VM-Operator role" "${token_acl}" "VM-Operator"

# The token's ACL must be its own entry, not the user's.
token_type="$(printf '%s' "${token_acl}" | tr -s ' ' | cut -d' ' -f2)"
ex_assert_eq "the token ACL is a token entry, not a user entry" "token" "${token_type}"

ex_summary
exit $?
