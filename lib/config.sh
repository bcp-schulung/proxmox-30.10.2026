#!/usr/bin/env bash
# =============================================================================
# lib/config.sh - configuration loading and validation
# =============================================================================
# Load order (highest precedence first):
#   1. real environment variables
#   2. ./.env   (git-ignored, machine specific)
#   3. ./config/default.env  (versioned defaults)
# =============================================================================

if [ -n "${__LAB_CONFIG_SOURCED:-}" ]; then
    return 0
fi
__LAB_CONFIG_SOURCED=1

# shellcheck source=lib/common.sh
. "${LAB_LIB_DIR}/common.sh"

# Load a shell file into the environment without clobbering variables that the
# operator explicitly exported. `set -a` + source would let the file override
# real environment variables, which is the opposite of what we want.
_load_env_file() {
    local file="$1"
    [ -f "${file}" ] || return 0
    local line key value
    # Snapshot the exported names once instead of forking `env` per line.
    local exported
    exported="$(export -p)"
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            ''|'#'*) continue ;;
        esac
        line="${line%%#*}"
        # strip surrounding whitespace
        line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${line}" ] && continue
        case "${line}" in
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        # trim key
        key="$(printf '%s' "${key}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        # trim surrounding quotes from value
        case "${value}" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        # Only set if not already present in the environment.
        case "${exported}" in
            *"declare -x ${key}="*) : ;;   # already exported by the operator
            *) export "${key}=${value}" ;;
        esac
    done < "${file}"
}

load_config() {
    _load_env_file "${LAB_CONFIG_DIR}/default.env"
    _load_env_file "${LAB_ROOT_DIR}/.env"

    # Derived values
    export AWS_REGION="${AWS_REGION:-eu-central-1}"
    export AWS_CALLER_IP="${AWS_CALLER_IP:-}"
    export PACKER_AMI_REGION="${PACKER_AMI_REGION:-${AWS_REGION}}"

    export PVE_NODE_NAMES="${PVE_NODE_NAMES:-pve1 pve2 pve3}"
    export PVE_SSH_KEY_PATH="${PVE_SSH_KEY_PATH:-${LAB_STATE_DIR}/keys/${PVE_KEYPAIR_NAME}.pem}"

    # Ensure the state/log directories exist
    mkdir -p "${LAB_STATE_DIR}" "${LAB_LOG_DIR}" "${LAB_STATE_DIR}/keys"

    # Never let an AWS profile leak into packer if it is empty
    if [ -z "${AWS_PROFILE:-}" ]; then
        unset AWS_PROFILE || true
    fi
}

# Build the aws CLI invocation, honouring AWS_PROFILE when set.
aws_cli() {
    if [ -n "${AWS_PROFILE:-}" ]; then
        aws --profile "${AWS_PROFILE}" "$@"
    else
        aws "$@"
    fi
}

# The same for the AWS CLI v2 pager and region handling.
aws_quiet() {
    aws_cli "$@" >/dev/null 2>&1
}

# Detect the operator's public IP address (used to scope the web UI firewall
# rules). Returns empty when detection fails - the caller decides what to do.
detect_caller_ip() {
    local ip=""
    ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null || true)"
    ip="$(printf '%s' "${ip}" | tr -d '[:space:]')"
    if printf '%s' "${ip}" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        printf '%s' "${ip}"
    fi
}

# Validate the configuration before touching AWS. Fails fast with a clear
# message rather than half way through a provision run.
validate_config() {
    local errors=0

    if ! printf '%s' "${AWS_REGION}" | grep -Eq '^[a-z]{2}-[a-z]+-[0-9]$'; then
        log_error "AWS_REGION '${AWS_REGION}' is not a valid region identifier"
        errors=$((errors + 1))
    fi

    for cidr in "${VPC_CIDR}" "${SUBNET_PUBLIC_CIDR}" \
                 "${SUBNET_SERVICES_CIDR}" "${GUEST_SUBNET_CIDR}"; do
        if ! printf '%s' "${cidr}" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
            log_error "Invalid CIDR: ${cidr}"
            errors=$((errors + 1))
        fi
    done

    if [ "${errors}" -gt 0 ]; then
        die "${errors} configuration error(s) found. Fix config/default.env or .env"
    fi

    # Node names must be unique and a valid hostname each.
    local seen="" name
    for name in ${PVE_NODE_NAMES}; do
        case "${seen}" in
            *" ${name} "*) log_error "Duplicate node name in PVE_NODE_NAMES: ${name}"; errors=$((errors + 1)) ;;
        esac
        seen="${seen} ${name} "
        if ! printf '%s' "${name}" | grep -Eq '^[a-z][a-z0-9-]{0,62}$'; then
            log_error "Invalid node name: ${name}"
            errors=$((errors + 1))
        fi
    done

    [ "${errors}" -eq 0 ] || die "${errors} configuration error(s) found"
    log_ok "Configuration validated (region=${AWS_REGION}, nodes=${PVE_NODE_NAMES})"
}

# Preflight: check that every external tool the scripts rely on is installed.
preflight_tools() {
    local missing=0

    require_cmd aws     "Install the AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" || missing=$((missing + 1))
    require_cmd jq      "Install jq: https://jqlang.github.io/jq/download/" || missing=$((missing + 1))
    require_cmd ssh     "Install an OpenSSH client" || missing=$((missing + 1))
    require_cmd ssh-keygen "Install an OpenSSH client" || missing=$((missing + 1))
    require_cmd curl    "Install curl" || missing=$((missing + 1))

    if [ "${missing}" -gt 0 ]; then
        die "${missing} required tool(s) missing. Install them and re-run."
    fi

    if [ "${LAB_SKIP_PACKER_CHECK:-0}" != "1" ]; then
        if ! command -v packer >/dev/null 2>&1; then
            log_warn "packer not found - the Proxmox/PBS AMIs cannot be built."
            log_warn "Install it (https://www.packer.io/downloads) or pass --skip-ami-build"
            log_warn "to use a pre-built AMI (see PVE_AMI_ID / PBS_AMI_ID in .env)."
        fi
    fi

    log_ok "All required tools present"
}

# Preflight: verify AWS credentials work and the region is reachable.
preflight_aws() {
    local identity
    # The ERR trap is disabled inside the subshell so that the expected
    # failure does not print a confusing stack trace.
    if ! identity="$( { trap - ERR; aws_cli sts get-caller-identity --output json; } 2>&1 )"; then
        log_error "AWS credentials are not usable:"
        printf '%s\n' "${identity}" >&2
        log_error "Configure them with 'aws configure' or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY."
        die "Aborting."
    fi

    local account
    account="$(printf '%s' "${identity}" | jq -r '.Account')"
    export AWS_ACCOUNT_ID="${account}"
    log_ok "AWS credentials valid (account ${account})"

    if ! aws_quiet ec2 describe-vpcs --region "${AWS_REGION}" --filters "Name=cidr,Values=${VPC_CIDR}"; then
        die "Region '${AWS_REGION}' is not reachable with the current credentials."
    fi
    log_ok "Region '${AWS_REGION}' reachable"
}

# Print the effective configuration (redacting secrets).
print_config() {
    log_section
    log_info "Effective configuration"
    printf '    %-26s %s\n' "AWS region"          "${AWS_REGION}"
    printf '    %-26s %s\n' "AWS account"         "${AWS_ACCOUNT_ID:-n/a}"
    printf '    %-26s %s\n' "PVE instance type"   "${PVE_INSTANCE_TYPE}"
    printf '    %-26s %s\n' "PVE nodes"           "${PVE_NODE_NAMES}"
    printf '    %-26s %s\n' "Cluster name"        "${PVE_CLUSTER_NAME}"
    printf '    %-26s %s\n' "VPC CIDR"            "${VPC_CIDR}"
    printf '    %-26s %s\n' "Guest overlay"       "${GUEST_SUBNET_CIDR} (gw ${GUEST_GATEWAY})"
    printf '    %-26s %s\n' "Shared storage"      "NFS ${NFS_STORAGE_ID} @ ${NFS_EXPORT}"
    printf '    %-26s %s\n' "Backup target"       "PBS ${PBS_STORAGE_ID}"
    printf '    %-26s %s\n' "Web UI access"       "${AWS_CALLER_IP:-<auto-detect>}:8006"
}
