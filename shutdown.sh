#!/usr/bin/env bash
# =============================================================================
# shutdown.sh - stop the seminar lab without destroying it
# =============================================================================
# Shuts the guests down gracefully, then stops the EC2 instances. Everything
# is kept: the EBS volumes, the AMIs, the VPC and the cluster configuration on
# the nodes. Restarting is a matter of starting the instances again.
#
#   ./shutdown.sh            graceful guest shutdown + stop the instances
#   ./shutdown.sh --guests   only shut the guests down, keep the nodes running
#   ./shutdown.sh --start    start the lab again
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
GUESTS_ONLY=0
START_ONLY=0
ASSUME_YES=0
FORCE=0

usage() {
    cat << 'EOF'
shutdown.sh - stop the Proxmox VE seminar lab, keeping all resources

Usage:
  ./shutdown.sh [options]

Options:
  --guests    Only shut the guests down, leave the EC2 instances running
  --start     Start the lab again (the counterpart of a shutdown)
  --force     Do not wait for the graceful shutdown timeout
  --yes       Do not ask for confirmation
  -h, --help  Show this help

After a shutdown the instances can be started again with:
  ./shutdown.sh --start
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --guests)   GUESTS_ONLY=1; shift ;;
        --start)    START_ONLY=1; shift ;;
        --force)    FORCE=1; shift ;;
        --yes|-y)   ASSUME_YES=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
done

# --- guest handling ----------------------------------------------------------

# Shut every guest on a node down gracefully.
shutdown_guests_on_node() {
    local node="$1"
    local priv
    priv="$(state_get ".instances.${node}.private_ip")"

    if ! ssh_exec_q "${priv}" "true"; then
        log_warn "${node}: not reachable - skipping the guest shutdown"
        return 0
    fi

    local vmid ctid
    for vmid in $(ssh_exec "${priv}" "qm list 2>/dev/null | tail -n +2 | awk '{print \$1}'"); do
        [ -n "${vmid}" ] || continue
        if ssh_exec_q "${priv}" "qm status ${vmid} 2>/dev/null | grep -q running"; then
            log_info "${node}: shutting down VM ${vmid}"
            if [ "${FORCE}" = "1" ]; then
                ssh_exec_q "${priv}" "qm stop ${vmid}" || true
            else
                ssh_exec_q "${priv}" "qm shutdown ${vmid} --timeout 60" || \
                    log_warn "${node}: VM ${vmid} did not shut down cleanly"
            fi
        fi
    done

    for ctid in $(ssh_exec "${priv}" "pct list 2>/dev/null | tail -n +2 | awk '{print \$1}'"); do
        [ -n "${ctid}" ] || continue
        if ssh_exec_q "${priv}" "pct status ${ctid} 2>/dev/null | grep -q running"; then
            log_info "${node}: shutting down container ${ctid}"
            if [ "${FORCE}" = "1" ]; then
                ssh_exec_q "${priv}" "pct stop ${ctid}" || true
            else
                ssh_exec_q "${priv}" "pct shutdown ${ctid} --timeout 60" || \
                    log_warn "${node}: container ${ctid} did not shut down cleanly"
            fi
        fi
    done
}

do_shutdown_guests() {
    local node
    for node in $(lab_node_list); do
        shutdown_guests_on_node "${node}"
    done
}

# --- EC2 handling ------------------------------------------------------------

do_stop_instances() {
    local name instance_id
    for name in $(lab_node_list) nfs1 pbs1; do
        instance_id="$(state_get ".instances.${name}.id")"
        [ -n "${instance_id}" ] || continue

        local state
        state="$(aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "${instance_id}" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)"
        case "${state}" in
            running|pending)
                log_info "Stopping ${name} (${instance_id})..."
                aws_stop_instance "${instance_id}"
                ;;
            stopped)
                log_info "${name} is already stopped"
                ;;
            *)
                log_warn "${name} is in state '${state:-unknown}' - not stopping it"
                continue
                ;;
        esac
    done

    log_info "Waiting for the instances to stop..."
    local name instance_id
    for name in $(lab_node_list) nfs1 pbs1; do
        instance_id="$(state_get ".instances.${name}.id")"
        [ -n "${instance_id}" ] || continue
        aws_wait_instance_stopped "${instance_id}" 2>/dev/null || \
            log_warn "${name} did not report 'stopped' in time"
    done
}

do_start_instances() {
    local name instance_id
    for name in $(lab_node_list) nfs1 pbs1; do
        instance_id="$(state_get ".instances.${name}.id")"
        [ -n "${instance_id}" ] || continue

        local state
        state="$(aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "${instance_id}" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)"
        if [ "${state}" = "running" ]; then
            log_info "${name} is already running"
            continue
        fi
        log_info "Starting ${name} (${instance_id})..."
        aws_cli ec2 start-instances --region "${AWS_REGION}" --instance-ids "${instance_id}" >/dev/null
    done

    log_info "Waiting for the instances to start..."
    for name in $(lab_node_list) nfs1 pbs1; do
        instance_id="$(state_get ".instances.${name}.id")"
        [ -n "${instance_id}" ] || continue
        aws_wait_instance_running "${instance_id}" 2>/dev/null || \
            log_warn "${name} did not report 'running' in time"
    done

    log_info "Waiting for the Proxmox nodes to come back..."
    local node priv
    for node in $(lab_node_list); do
        priv="$(state_get ".instances.${node}.private_ip")"
        if wait_ssh "${priv}" "${BOOT_TIMEOUT}"; then
            log_ok "${node} is reachable again"
        else
            log_warn "${node} did not answer SSH within ${BOOT_TIMEOUT}s - run ./debug.sh"
        fi
    done
}

# --- main --------------------------------------------------------------------

main() {
    load_config

    if ! state_exists; then
        die "No state file found - there is nothing to shut down."
    fi

    print_banner "Proxmox VE seminar lab - shutdown"

    if [ "${START_ONLY}" = "1" ]; then
        do_start_instances
        log_ok "The lab has been started again."
        printf '\n  Web UI: https://%s:8006/\n\n' "$(state_get ".instances.$(lab_node_list | head -1).public_ip")"
        return 0
    fi

    if [ "${ASSUME_YES}" != "1" ]; then
        if ! confirm "Shut down the guests and stop all lab instances?" "no"; then
            log_info "Aborted."
            return 0
        fi
    fi

    do_shutdown_guests

    if [ "${GUESTS_ONLY}" = "1" ]; then
        log_ok "The guests are stopped. The EC2 instances are still running."
        return 0
    fi

    do_stop_instances

    print_banner "The lab has been shut down"
    printf '  Everything is preserved: EBS volumes, AMIs, the VPC and the\n'
    printf '  cluster configuration on the nodes.\n\n'
    printf '  Start it again with:  ./shutdown.sh --start\n'
    printf '  Cost so far:  roughly 5 instances are stopped, so nothing accrues.\n\n'
}

main "$@"
