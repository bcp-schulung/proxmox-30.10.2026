#!/usr/bin/env bash
# =============================================================================
# provision.sh - build the complete Proxmox VE seminar lab on AWS
# =============================================================================
# Creates the network, builds the AMIs, launches the Proxmox cluster, joins
# the nodes, configures the storage backends and provisions the guests.
#
# The script is resumable: every phase records its completion in
# .state/lab.json, so a re-run picks up where the previous one stopped.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/aws.sh
. "${SCRIPT_DIR}/lib/aws.sh"
# shellcheck source=lib/ssh.sh
. "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/pve.sh
. "${SCRIPT_DIR}/lib/pve.sh"
# shellcheck source=lib/lab.sh
. "${SCRIPT_DIR}/lib/lab.sh"

# --- options -----------------------------------------------------------------
SKIP_AMI_BUILD=0
WITH_SECURITY=0
ASSUME_YES=0
ONLY_PHASE=""

usage() {
    cat << 'EOF'
provision.sh - build the Proxmox VE seminar lab on AWS

Usage:
  ./provision.sh [options]

Options:
  --skip-ami-build     Do not rebuild the AMIs (use the ones in .state/lab.json)
  --with-security      Also apply the security seminar baseline (RBAC, roles,
                       privilege-separated API token, self-signed cluster cert)
  --phase <name>       Only run one phase:
                         foundation | amis | nodes | bootstrap | cluster |
                         storage | backup | guests | security
  --yes                Do not ask for confirmation
  -h, --help           Show this help

Configuration:
  Environment variables > ./.env > ./config/default.env
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-ami-build) SKIP_AMI_BUILD=1; shift ;;
        --with-security)  WITH_SECURITY=1; shift ;;
        --phase)          ONLY_PHASE="$2"; shift 2 ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
done

main() {
    enable_error_trap
    load_config
    preflight_tools
    validate_config

    if [ "${SKIP_AMI_BUILD}" = "1" ]; then
        export LAB_SKIP_PACKER_CHECK=1
    fi

    state_init
    preflight_aws

    if [ "${ASSUME_YES}" != "1" ]; then
        log_warn "This will create billable AWS resources in ${AWS_REGION}."
        if ! confirm "Continue with the provisioning?" "yes"; then
            log_info "Aborted."
            exit 0
        fi
    fi

    print_banner "Proxmox VE advanced seminar lab - provisioning"
    print_config

    # The root password is shared by every node so that the cluster join and
    # the web UI work with one set of credentials.
    local root_password
    root_password="$(state_get ".pve.root_password")"
    if [ -z "${root_password}" ]; then
        root_password="$(gen_password 24)"
        state_set ".pve.root_password" "\"${root_password}\""
        log_info "Generated a Proxmox root password"
    fi
    export PVE_ROOT_PASSWORD="${root_password}"

    if [ -n "${ONLY_PHASE}" ]; then
        case " ${LAB_PHASES} " in
            *" ${ONLY_PHASE} "*) ;;
            *) die "Unknown phase '${ONLY_PHASE}'. Valid phases: ${LAB_PHASES}" ;;
        esac
        log_info "Running only the phase '${ONLY_PHASE}'"
    fi

    local start_time
    start_time="$(date +%s)"

    run_phase foundation lab_phase_foundation
    run_phase amis       lab_phase_amis
    run_phase nodes      lab_phase_nodes
    run_phase bootstrap  lab_phase_bootstrap
    run_phase cluster    lab_phase_cluster
    run_phase storage    lab_phase_storage
    run_phase backup     lab_phase_backup
    run_phase guests     lab_phase_guests

    if [ "${WITH_SECURITY}" = "1" ]; then
        run_phase security lab_phase_security
    fi

    # Write the human-readable .env with the generated credentials.
    lab_write_env

    local elapsed
    elapsed=$(( $(date +%s) - start_time ))
    lab_print_summary
    log_ok "Provisioning finished in $(human_duration "${elapsed}")"
}

# run_phase <name> <function>
run_phase() {
    local name="$1" func="$2"

    # The operator's public IPv4 address changes over time. The access
    # rules of the security groups are therefore synced before every
    # phase, so that the operator does not lose the access to the nodes
    # while the lab is running.
    lab_sync_operator_access

    # An explicitly requested phase always runs, even when the state file
    # says it is done - the operator asked for it.
    if [ -n "${ONLY_PHASE}" ]; then
        [ "${ONLY_PHASE}" = "${name}" ] || return 0
        warn_missing_prerequisites "${name}"
        "${func}"
        return 0
    fi

    if [ "${name}" != "security" ] && lab_phase_done "${name}"; then
        log_info "Phase '${name}' is already complete - skipping"
        return 0
    fi

    if [ "${name}" = "amis" ] && [ "${SKIP_AMI_BUILD}" = "1" ]; then
        log_info "Phase 'amis' skipped (--skip-ami-build)"
        return 0
    fi

    if [ "${name}" = "security" ] && [ "${WITH_SECURITY}" != "1" ]; then
        return 0
    fi

    "${func}"
}

# Warn when the phases a phase depends on have not been completed.
warn_missing_prerequisites() {
    local target="$1"
    local target_index phase phase_index
    target_index="$(lab_phase_index "${target}")"

    for phase in ${LAB_PHASES}; do
        phase_index="$(lab_phase_index "${phase}")"
        [ "${phase_index}" -lt "${target_index}" ] || break
        [ "${phase}" = "${target}" ] && break
        if ! lab_phase_done "${phase}"; then
            log_warn "Phase '${phase}' has not completed yet - '${target}' may fail."
        fi
    done
}

# Write a .env file with the generated values so the operator (and the other
# scripts) can read the credentials without digging in the state file.
lab_write_env() {
    local env_file="${LAB_ROOT_DIR}/.env"
    {
        printf '# Generated by provision.sh - contains lab credentials.\n'
        printf '# Never commit this file.\n\n'
        printf 'AWS_REGION="%s"\n' "${AWS_REGION}"
        printf 'PVE_ROOT_PASSWORD="%s"\n' "$(state_get ".pve.root_password")"
        printf 'PBS_PASSWORD="%s"\n' "$(state_get ".pve.pbs_password")"
        printf 'PBS_FINGERPRINT="%s"\n' "$(state_get ".pve.pbs_fingerprint")"
        printf 'PVE_CLUSTER_NAME="%s"\n' "${PVE_CLUSTER_NAME}"
        printf 'AWS_CALLER_IP="%s"\n' "${AWS_CALLER_IP:-}"
        printf 'GUEST_ROOT_PASSWORD="%s"\n' "$(state_get ".pve.guest_password")"
    } > "${env_file}"
    chmod 600 "${env_file}"
    log_debug "Wrote ${env_file}"
}

main "$@"
