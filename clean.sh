#!/usr/bin/env bash
# =============================================================================
# clean.sh - remove the seminar lab
# =============================================================================
# Two scopes:
#
#   --scope cluster   (default)
#       Destroy the guests (VMs and containers) and reset the cluster so the
#       lab can be re-created from scratch. The EC2 instances keep running.
#
#   --scope aws
#       Also terminate the EC2 instances, delete the EBS volumes, the ENIs,
#       the security groups, the NAT gateway, the subnets and the VPC.
#
#   --scope all
#       Both of the above.
#
# Everything is found through the state file and through the LabTag on the
# AWS resources, so nothing outside the lab is ever touched.
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
SCOPE="cluster"
ASSUME_YES=0
DRY_RUN=0
KEEP_AMI=0

usage() {
    cat << 'EOF'
clean.sh - remove the Proxmox VE seminar lab

Usage:
  ./clean.sh [options]

Options:
  --scope <scope>   What to remove:
                      cluster   destroy the guests and reset the cluster
                                 (the default - the EC2 instances keep running)
                      aws       terminate the instances and delete all AWS
                                 resources (the guests are destroyed first)
                      all       both of the above
  --keep-ami        Keep the AMIs (default for --scope all)
  --delete-ami      Also delete the AMIs
  --dry-run         Show what would be removed, change nothing
  --yes             Do not ask for confirmation
  -h, --help        Show this help

Examples:
  ./clean.sh                        reset the cluster, keep the infrastructure
  ./clean.sh --scope aws            remove everything from AWS
  ./clean.sh --scope all --dry-run  show what the full cleanup would do
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --scope)      SCOPE="$2"; shift 2 ;;
        --keep-ami)   KEEP_AMI=1; shift ;;
        --delete-ami) KEEP_AMI=0; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
done

case "${SCOPE}" in
    cluster|aws|all) ;;
    *) die "Invalid scope '${SCOPE}'. Use cluster, aws or all." ;;
esac

# --- helpers -----------------------------------------------------------------

run() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s  [dry-run] %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
        return 0
    fi
    "$@"
}

# --- scope 1: the cluster and its guests -------------------------------------

destroy_guests() {
    log_step "Destroying the guests"

    local node priv
    for node in $(lab_node_list); do
        priv="$(state_get ".instances.${node}.private_ip")"
        if ! ssh_exec_q "${priv}" "true"; then
            log_warn "${node}: not reachable - its guests cannot be destroyed from here"
            continue
        fi

        local vmid
        for vmid in $(ssh_exec "${priv}" "qm list 2>/dev/null | tail -n +2 | awk '{print \$1}'"); do
            [ -n "${vmid}" ] || continue
            log_info "${node}: destroying VM ${vmid}"
            run ssh_exec_q "${priv}" "qm destroy ${vmid} --purge 1 --destroy-unreferenced-disks 1"
        done

        local ctid
        for ctid in $(ssh_exec "${priv}" "pct list 2>/dev/null | tail -n +2 | awk '{print \$1}'"); do
            [ -n "${ctid}" ] || continue
            log_info "${node}: destroying container ${ctid}"
            run ssh_exec_q "${priv}" "pct destroy ${ctid} --purge 1"
        done
    done
}

reset_cluster() {
    log_step "Resetting the cluster configuration"

    local node priv last=""
    for node in $(lab_node_list); do
        priv="$(state_get ".instances.${node}.private_ip")"
        ssh_exec_q "${priv}" "true" || continue
        log_info "${node}: leaving the cluster"
        run ssh_exec_q "${priv}" "pvecm leave --force"
        last="${priv}"
    done

    # Wipe the shared configuration on the first node so that the next
    # 'pvecm create' starts from a clean slate.
    if [ -n "${last}" ]; then
        log_info "Removing the stored cluster configuration"
        run ssh_exec_q "${last}" "rm -f /etc/pve/corosync.conf /etc/pve/cluster/ /etc/pve/nodes/*/corosync.conf 2>/dev/null; true"
    fi

    # The storage definitions live in the cluster configuration too.
    local first_priv
    first_priv="$(state_get ".instances.$(lab_node_list | head -1).private_ip")"
    if ssh_exec_q "${first_priv}" "true"; then
        run ssh_exec_q "${first_priv}" "pvesm remove ${NFS_STORAGE_ID} 2>/dev/null; pvesm remove ${PBS_STORAGE_ID} 2>/dev/null; pvesm remove ${LOCAL_STORAGE_ID} 2>/dev/null; true"
    fi

    # Reset the recorded state so that a re-run starts from the foundation.
    state_set ".pve.cluster_formed" "false"
    state_set ".pve.vms_ready" "false"
    state_set ".pve.cts_ready" "false"
    state_set ".pve.security_ready" "false"
    state_set ".phase" "\"foundation\""
}

clean_nfs_export() {
    local nfs_ip
    nfs_ip="$(state_get ".instances.nfs1.private_ip")"
    [ -n "${nfs_ip}" ] || return 0
    if ssh_exec_q "${nfs_ip}" "true"; then
        log_step "Cleaning the shared NFS export"
        run ssh_exec_q "${nfs_ip}" "rm -rf ${NFS_EXPORT}/images/* ${NFS_EXPORT}/rootfs/* ${NFS_EXPORT}/iso/* ${NFS_EXPORT}/vztmpl/* ${NFS_EXPORT}/backup/* 2>/dev/null; true"
    fi
}

# --- scope 2: the AWS resources ----------------------------------------------

terminate_instances() {
    log_step "Terminating the EC2 instances"

    local name instance_id
    for name in $(lab_node_list) nfs1 pbs1; do
        instance_id="$(state_get ".instances.${name}.id")"
        [ -n "${instance_id}" ] || continue
        log_info "Terminating ${name} (${instance_id})"
        run aws_terminate_instance "${instance_id}"
    done

    # Wait for the termination so that the volumes and ENIs can be deleted.
    if [ "${DRY_RUN}" != "1" ]; then
        log_info "Waiting for the instances to terminate..."
        for name in $(lab_node_list) nfs1 pbs1; do
            instance_id="$(state_get ".instances.${name}.id")"
            [ -n "${instance_id}" ] || continue
            aws_wait_instance_terminated "${instance_id}" 2>/dev/null || \
                log_warn "${name} did not terminate in time"
        done
    fi
}

delete_volumes() {
    log_step "Deleting the EBS volumes"

    local name volume_id
    for name in $(lab_node_list) nfs1 pbs1; do
        volume_id="$(state_get ".instances.${name}.data_volume")"
        [ -n "${volume_id}" ] || continue
        log_info "Deleting the data volume of ${name} (${volume_id})"
        run aws_delete_volume "${volume_id}"
    done

    # Anything that is still tagged with the lab tag.
    if [ "${DRY_RUN}" != "1" ]; then
        local volume
        for volume in $(aws_lab_volumes); do
            [ -n "${volume}" ] || continue
            log_info "Deleting the remaining lab volume ${volume}"
            aws_delete_volume "${volume}"
        done
    fi
}

delete_network() {
    log_step "Deleting the network resources"

    local vpc_id
    vpc_id="$(state_get ".vpc.id")"
    [ -n "${vpc_id}" ] || vpc_id="$(aws_vpc_id)"
    [ -n "${vpc_id}" ] || return 0

    # ENIs that are not owned by an instance (the second interface of a node).
    local eni
    if [ "${DRY_RUN}" != "1" ]; then
        for eni in $(aws_cli ec2 describe-network-interfaces --region "${AWS_REGION}" \
            --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
            "Name=status,Values=available" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null | tr '\t' '\n'); do
            [ -n "${eni}" ] || continue
            log_info "Deleting the network interface ${eni}"
            aws_delete_eni "${eni}"
        done
    fi

    local sg
    for sg in pve-lab services-lab; do
        local sg_id
        sg_id="$(aws_sg_id "${sg}")"
        [ -n "${sg_id}" ] || continue
        log_info "Deleting the security group ${sg} (${sg_id})"
        run aws_delete_sg "${sg_id}"
    done

    local natgw
    natgw="$(state_get ".natgw")"
    [ -n "${natgw}" ] || natgw="$(aws_natgw_id)"
    if [ -n "${natgw}" ]; then
        log_info "Deleting the NAT gateway ${natgw}"
        run aws_delete_natgw "${natgw}"
    fi

    local igw
    igw="$(state_get ".igw")"
    [ -n "${igw}" ] || igw="$(aws_igw_id)"
    if [ -n "${igw}" ]; then
        log_info "Deleting the internet gateway ${igw}"
        run aws_delete_igw "${igw}"
    fi

    local role
    for role in public services; do
        local subnet
        subnet="$(state_get ".subnets.${role}.id")"
        [ -n "${subnet}" ] || continue
        log_info "Deleting the subnet ${role} (${subnet})"
        run aws_delete_subnet "${subnet}"
    done

    log_info "Deleting the VPC ${vpc_id}"
    run aws_delete_vpc "${vpc_id}"
}

delete_keypair() {
    log_step "Deleting the key pair"
    log_info "Deleting the key pair ${PVE_KEYPAIR_NAME}"
    run aws_delete_keypair "${PVE_KEYPAIR_NAME}"
    rm -f "${PVE_SSH_KEY_PATH}" "${PVE_SSH_KEY_PATH}.pub"
}

delete_amis() {
    [ "${KEEP_AMI}" = "1" ] && return 0
    log_step "Deleting the AMIs"
    local kind ami
    for kind in pve pbs; do
        ami="$(state_get ".amis.${kind}")"
        [ -n "${ami}" ] || continue
        log_info "Deregistering the ${kind} AMI ${ami}"
        run aws_deregister_ami "${ami}"
        if [ "${DRY_RUN}" != "1" ]; then
            aws_delete_snapshots_of_ami "${ami}"
        fi
    done
}

# --- main --------------------------------------------------------------------

main() {
    load_config

    print_banner "Proxmox VE seminar lab - cleanup (scope: ${SCOPE})"

    if [ "${DRY_RUN}" = "1" ]; then
        log_warn "Dry run - nothing will be changed."
    fi

    if [ "${ASSUME_YES}" != "1" ] && [ "${DRY_RUN}" != "1" ]; then
        local prompt="Remove the lab"
        case "${SCOPE}" in
            cluster) prompt="Destroy the guests and reset the cluster (the EC2 instances keep running)?" ;;
            aws)     prompt="Remove EVERYTHING, including the running EC2 instances?" ;;
            all)     prompt="Remove EVERYTHING, including the running EC2 instances?" ;;
        esac
        if ! confirm "${prompt}" "no"; then
            log_info "Aborted."
            return 0
        fi
    fi

    if [ "${SCOPE}" = "cluster" ] || [ "${SCOPE}" = "all" ]; then
        destroy_guests
        clean_nfs_export
        reset_cluster
    fi

    if [ "${SCOPE}" = "aws" ] || [ "${SCOPE}" = "all" ]; then
        if [ "${SCOPE}" = "all" ]; then
            destroy_guests
            clean_nfs_export
            reset_cluster
        fi
        terminate_instances
        delete_volumes
        delete_network
        delete_keypair
        delete_amis
    fi

    if [ "${SCOPE}" = "cluster" ]; then
        print_banner "The cluster has been reset"
        printf '  The guests are gone and the cluster configuration was cleared.\n'
        printf '  The EC2 instances are still running and still cost money.\n\n'
        printf '  Remove them completely with:  ./clean.sh --scope aws\n\n'
    else
        print_banner "The lab has been removed"
        printf '  All EC2 instances, volumes and network resources are gone.\n'
        [ "${KEEP_AMI}" = "1" ] && printf '  The AMIs were kept for the next run.\n'
        printf '\n'
        if [ "${DRY_RUN}" != "1" ]; then
            rm -f "${STATE_FILE}"
            log_debug "Removed the state file"
        fi
    fi
}

main "$@"
