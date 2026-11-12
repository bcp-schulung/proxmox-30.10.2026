#!/usr/bin/env bash
# =============================================================================
# destroy.sh - destroy the entire seminar lab, including every AWS resource
# =============================================================================
# This is the full teardown. It removes:
#
#   * the guests (VMs and containers) and the cluster configuration
#   * every EC2 instance, including orphans from a failed Packer build
#   * every EBS volume
#   * every network interface, security group, route table, NAT gateway,
#     elastic IP, internet gateway, subnet and the VPC
#   * the key pair, both AMIs and their snapshots
#   * the local state, the credentials in .env and the diagnostic reports
#
# Resources are found by their LabTag, so leftovers from an interrupted run
# are removed as well - the state file is not required.
#
#   ./destroy.sh              destroy everything, with a confirmation
#   ./destroy.sh --dry-run    show what would be removed, change nothing
#   ./destroy.sh --yes        destroy everything without asking
#   ./destroy.sh --keep-amis  keep the AMIs (the next run starts faster)
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
ASSUME_YES=0
DRY_RUN=0
KEEP_AMIS=0
KEEP_STATE=0
SKIP_CLUSTER=0

usage() {
    cat << 'EOF'
destroy.sh - remove the Proxmox VE seminar lab completely

Usage:
  ./destroy.sh [options]

Options:
  --dry-run       Show what would be removed, change nothing
  --yes           Do not ask the ordinary yes/no question
                  (the destruction guard still asks for a typed phrase)
  --keep-amis     Keep the AMIs (the next provisioning run starts faster)
  --keep-state    Keep .state/lab.json and the generated .env
  --skip-cluster  Do not touch the cluster, only remove the AWS resources
  -h, --help      Show this help

This removes every instance, volume, network resource, image and key pair
that the harness created. Resources are located by their LabTag, so
leftovers from an interrupted run are removed too.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --keep-amis)    KEEP_AMIS=1; shift ;;
        --keep-state)   KEEP_STATE=1; shift ;;
        --skip-cluster) SKIP_CLUSTER=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
done

# --- discovery ---------------------------------------------------------------

# The instances recorded in the state file.
state_instance_ids() {
    local name id
    for name in $(lab_node_list) nfs1 pbs1; do
        id="$(state_get ".instances.${name}.id")"
        [ -n "${id}" ] && printf '%s\n' "${id}"
    done
}

# The volumes recorded in the state file.
state_volume_ids() {
    local name id
    for name in $(lab_node_list) nfs1 pbs1; do
        id="$(state_get ".instances.${name}.data_volume")"
        [ -n "${id}" ] && printf '%s\n' "${id}"
    done
}

# Merge two lists of IDs, removing the duplicates. An empty result is not an
# error - grep exits 1 when nothing matches, which would abort the script.
merge_ids() {
    { cat | tr ' ' '\n' | grep -v '^$' | grep -v '^None$' | sort -u; } || true
}

# --- the manifest ------------------------------------------------------------
MANIFEST_INSTANCES=""
MANIFEST_VOLUMES=""
MANIFEST_ENIS=""
MANIFEST_SGS=""
MANIFEST_RTBS=""
MANIFEST_NATGWS=""
MANIFEST_EIPS=""
MANIFEST_IGWS=""
MANIFEST_SUBNETS=""
MANIFEST_VPCS=""
MANIFEST_AMIS=""
MANIFEST_SNAPSHOTS=""
MANIFEST_KEYPAIRS=""

build_manifest() {
    log_step "Discovering the lab resources in ${AWS_REGION}"

    MANIFEST_INSTANCES="$( { state_instance_ids; aws_lab_instances; } | merge_ids )"
    MANIFEST_VOLUMES="$( { state_volume_ids; aws_lab_volumes; } | merge_ids )"
    MANIFEST_ENIS="$(aws_lab_enis | merge_ids)"
    MANIFEST_SGS="$(aws_lab_sgs | merge_ids)"
    MANIFEST_RTBS="$(aws_lab_route_tables | merge_ids)"
    MANIFEST_NATGWS="$(aws_lab_natgws | merge_ids)"
    MANIFEST_EIPS="$(aws_lab_eips | merge_ids)"
    MANIFEST_IGWS="$(aws_lab_igws | merge_ids)"
    MANIFEST_SUBNETS="$(aws_lab_subnets | merge_ids)"
    MANIFEST_VPCS="$(aws_lab_vpcs | merge_ids)"
    MANIFEST_AMIS="$(aws_lab_amis | merge_ids)"
    MANIFEST_SNAPSHOTS="$(aws_lab_snapshots | merge_ids)"
    MANIFEST_KEYPAIRS="$(aws_lab_keypairs | merge_ids)"

    # The AMIs and key pair are also known by name, in case the tags are gone.
    local ami
    for ami in "${PVE_AMI_NAME}" "${PBS_AMI_NAME}"; do
        local id
        id="$(aws_ami_id_by_name "${ami}")"
        [ -n "${id}" ] && MANIFEST_AMIS="$(printf '%s\n%s\n' "${MANIFEST_AMIS}" "${id}" | merge_ids)"
    done
    if aws_keypair_exists "${PVE_KEYPAIR_NAME}"; then
        MANIFEST_KEYPAIRS="$(printf '%s\n%s\n' "${MANIFEST_KEYPAIRS}" "${PVE_KEYPAIR_NAME}" | merge_ids)"
    fi
}

count_lines() {
    printf '%s' "$1" | grep -c '[^[:space:]]' || true
}

print_manifest() {
    log_section
    log_info "The following resources will be destroyed"
    printf '    %-22s %s\n' "EC2 instances"   "$(count_lines "${MANIFEST_INSTANCES}")"
    printf '    %-22s %s\n' "EBS volumes"     "$(count_lines "${MANIFEST_VOLUMES}")"
    printf '    %-22s %s\n' "Network IFs"     "$(count_lines "${MANIFEST_ENIS}")"
    printf '    %-22s %s\n' "Security groups" "$(count_lines "${MANIFEST_SGS}")"
    printf '    %-22s %s\n' "Route tables"    "$(count_lines "${MANIFEST_RTBS}")"
    printf '    %-22s %s\n' "NAT gateways"    "$(count_lines "${MANIFEST_NATGWS}")"
    printf '    %-22s %s\n' "Elastic IPs"     "$(count_lines "${MANIFEST_EIPS}")"
    printf '    %-22s %s\n' "Internet GWs"    "$(count_lines "${MANIFEST_IGWS}")"
    printf '    %-22s %s\n' "Subnets"         "$(count_lines "${MANIFEST_SUBNETS}")"
    printf '    %-22s %s\n' "VPCs"            "$(count_lines "${MANIFEST_VPCS}")"
    printf '    %-22s %s\n' "AMIs"            "$(count_lines "${MANIFEST_AMIS}")"
    printf '    %-22s %s\n' "Snapshots"       "$(count_lines "${MANIFEST_SNAPSHOTS}")"
    printf '    %-22s %s\n' "Key pairs"       "$(count_lines "${MANIFEST_KEYPAIRS}")"

    local total
    total=$(( $(count_lines "${MANIFEST_INSTANCES}") \
            + $(count_lines "${MANIFEST_VOLUMES}") \
            + $(count_lines "${MANIFEST_ENIS}") \
            + $(count_lines "${MANIFEST_SGS}") \
            + $(count_lines "${MANIFEST_RTBS}") \
            + $(count_lines "${MANIFEST_NATGWS}") \
            + $(count_lines "${MANIFEST_EIPS}") \
            + $(count_lines "${MANIFEST_IGWS}") \
            + $(count_lines "${MANIFEST_SUBNETS}") \
            + $(count_lines "${MANIFEST_VPCS}") \
            + $(count_lines "${MANIFEST_AMIS}") \
            + $(count_lines "${MANIFEST_SNAPSHOTS}") \
            + $(count_lines "${MANIFEST_KEYPAIRS}") ))

    if [ "${total}" -eq 0 ]; then
        log_ok "Nothing found - the lab is already gone."
        return 1
    fi
    log_warn "${total} resource(s) will be removed. This cannot be undone."
    return 0
}

# --- the teardown ------------------------------------------------------------

run() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s  [dry-run] %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
        return 0
    fi
    "$@"
}

# Same, but the command's own output is discarded and a failure is not fatal.
run_quiet() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s  [dry-run] %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
        return 0
    fi
    "$@" >/dev/null 2>&1 || true
}

destroy_cluster() {
    if [ "${SKIP_CLUSTER}" = "1" ]; then
        log_info "Skipping the cluster cleanup (--skip-cluster)"
        return 0
    fi

    # The in-cluster cleanup only works on a running node. If the instances
    # are stopped there is nothing to do - the volumes carry the cluster
    # configuration away with them.
    local node reachable=0
    for node in $(lab_node_list); do
        local priv
        priv="$(state_reach_ip "${node}")"
        if ssh_exec_q "${priv}" "true"; then
            reachable=1
            break
        fi
    done

    if [ "${reachable}" = "0" ]; then
        log_warn "No cluster node is reachable - skipping the in-cluster cleanup."
        log_warn "The cluster configuration goes away with the volumes."
        return 0
    fi

    lab_destroy_guests
    lab_clean_nfs_export
    lab_reset_cluster
}

destroy_instances() {
    local id count=0
    for id in ${MANIFEST_INSTANCES}; do
        log_info "Terminating ${id}"
        run aws_terminate_instance "${id}"
        count=$((count + 1))
    done
    [ "${count}" -gt 0 ] || return 0

    if [ "${DRY_RUN}" = "1" ]; then
        return 0
    fi

    log_info "Waiting for the instances to terminate..."
    for id in ${MANIFEST_INSTANCES}; do
        aws_wait_instance_terminated "${id}" 2>/dev/null || \
            log_warn "${id} did not terminate in time - the resources may still be in use"
    done
}

destroy_volumes() {
    local id
    for id in ${MANIFEST_VOLUMES}; do
        log_info "Deleting the volume ${id}"
        run aws_delete_volume "${id}"
    done
}

destroy_enis() {
    local id
    for id in ${MANIFEST_ENIS}; do
        log_info "Deleting the network interface ${id}"
        run aws_delete_eni "${id}"
    done
}

destroy_security_groups() {
    local id
    for id in ${MANIFEST_SGS}; do
        log_info "Deleting the security group ${id}"
        run aws_delete_sg "${id}"
    done
}

destroy_route_tables() {
    local id
    for id in ${MANIFEST_RTBS}; do
        log_info "Deleting the route table ${id}"
        run_quiet aws_cli ec2 delete-route-table --region "${AWS_REGION}" --route-table-id "${id}"
    done
}

destroy_nat_gateways() {
    local id
    for id in ${MANIFEST_NATGWS}; do
        log_info "Deleting the NAT gateway ${id}"
        run aws_delete_natgw "${id}"
    done
}

destroy_elastic_ips() {
    local id
    for id in ${MANIFEST_EIPS}; do
        log_info "Releasing the elastic IP ${id}"
        run aws_release_eip "${id}"
    done
}

destroy_internet_gateways() {
    local id
    for id in ${MANIFEST_IGWS}; do
        log_info "Deleting the internet gateway ${id}"
        run aws_delete_igw "${id}"
    done
}

destroy_subnets() {
    local id
    for id in ${MANIFEST_SUBNETS}; do
        log_info "Deleting the subnet ${id}"
        run aws_delete_subnet "${id}"
    done
}

destroy_vpcs() {
    local id
    for id in ${MANIFEST_VPCS}; do
        log_info "Deleting the VPC ${id}"
        run aws_delete_vpc "${id}"
    done
}

destroy_images() {
    [ "${KEEP_AMIS}" = "1" ] && return 0

    local id
    for id in ${MANIFEST_AMIS}; do
        log_info "Deregistering the AMI ${id}"
        run aws_deregister_ami "${id}"
        if [ "${DRY_RUN}" != "1" ]; then
            aws_delete_snapshots_of_ami "${id}"
        fi
    done

    for id in ${MANIFEST_SNAPSHOTS}; do
        log_info "Deleting the snapshot ${id}"
        run_quiet aws_cli ec2 delete-snapshot --region "${AWS_REGION}" --snapshot-id "${id}"
    done
}

destroy_keypairs() {
    local name
    for name in ${MANIFEST_KEYPAIRS}; do
        log_info "Deleting the key pair ${name}"
        run aws_delete_keypair "${name}"
    done
    rm -f "${PVE_SSH_KEY_PATH}" "${PVE_SSH_KEY_PATH}.pub"
}

destroy_local_files() {
    if [ "${KEEP_STATE}" = "1" ]; then
        log_info "Keeping the local state and the .env file"
        return 0
    fi

    log_info "Removing the local state, the credentials and the reports"
    rm -rf "${LAB_STATE_DIR}"
    rm -f "${LAB_ROOT_DIR}/.env"
    rm -rf "${LAB_LOG_DIR}"
    rm -f "${LAB_ROOT_DIR}/packer/manifest-pve.json" "${LAB_ROOT_DIR}/packer/manifest-pbs.json"
}

# --- verification ------------------------------------------------------------
verify_destroyed() {
    log_step "Verifying that nothing is left behind"

    local leftovers=""
    local check

    for check in instances volumes enis sgs rtbs natgws eips igws subnets vpcs amis snapshots keypairs; do
        local found=""
        case "${check}" in
            instances) found="$(aws_lab_instances | merge_ids)" ;;
            volumes)   found="$(aws_lab_volumes | merge_ids)" ;;
            enis)      found="$(aws_lab_enis | merge_ids)" ;;
            sgs)       found="$(aws_lab_sgs | merge_ids)" ;;
            rtbs)      found="$(aws_lab_route_tables | merge_ids)" ;;
            natgws)    found="$(aws_lab_natgws | merge_ids)" ;;
            eips)      found="$(aws_lab_eips | merge_ids)" ;;
            igws)      found="$(aws_lab_igws | merge_ids)" ;;
            subnets)   found="$(aws_lab_subnets | merge_ids)" ;;
            vpcs)      found="$(aws_lab_vpcs | merge_ids)" ;;
            amis)      found="$(aws_lab_amis | merge_ids)" ;;
            snapshots) found="$(aws_lab_snapshots | merge_ids)" ;;
            keypairs)  found="$(aws_lab_keypairs | merge_ids)" ;;
        esac
        if [ -n "${found}" ]; then
            leftovers="${leftovers}${check}: $(printf '%s' "${found}" | tr '\n' ' ')"$'\n'
        fi
    done

    if [ -z "${leftovers}" ]; then
        log_ok "The lab is completely gone."
        return 0
    fi

    log_warn "Some resources are still present:"
    printf '%s' "${leftovers}" >&2
    log_warn "They are probably still being deleted, or they are in use by something else."
    return 1
}

# --- main --------------------------------------------------------------------

main() {
    load_config

    print_banner "Proxmox VE seminar lab - full teardown"
    log_info "Region: ${AWS_REGION}    Tag: ${LAB_TAG}"

    if ! aws_quiet sts get-caller-identity; then
        die "No usable AWS credentials - nothing can be destroyed."
    fi

    build_manifest

    if ! print_manifest; then
        # Nothing to destroy, but the local files may still be there.
        if [ "${DRY_RUN}" != "1" ] && [ "${KEEP_STATE}" != "1" ]; then
            destroy_local_files
            log_ok "The local state was removed as well."
        fi
        return 0
    fi

    if [ "${DRY_RUN}" = "1" ]; then
        log_warn "Dry run - nothing will be changed."
    else
        # The destruction guard. It is not skipped by --yes: the flag only
        # skips the ordinary yes/no question, the guard always asks for
        # the typed phrase.
        local what="the guests (VMs and containers) on every node
the cluster configuration of pve1, pve2 and pve3
the contents of the shared NFS export
every EC2 instance of the lab
every EBS volume of the lab
the VPC, the subnets, the route tables, the internet gateways,
the security groups and the network interfaces of the lab
the key pair
the AMIs and their snapshots
the state file, the generated .env and the diagnostic reports"

        if ! lab_confirm_destruction "${LAB_CONFIRM_PHRASE_AWS}" \
                "Destroy the entire lab and every AWS resource?" "${what}"; then
            log_info "Aborted - nothing was destroyed."
            return 0
        fi
    fi

    # The dry run must not change anything. The teardown helpers are
    # called directly and not through the 'run' wrapper, so they have
    # to be skipped explicitly.
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s  [dry-run] the guests would be destroyed%s\n' "${C_DIM}" "${C_RESET}"
        printf '%s  [dry-run] the cluster configuration would be reset%s\n' "${C_DIM}" "${C_RESET}"
        printf '%s  [dry-run] the EC2 instances would be terminated%s\n' "${C_DIM}" "${C_RESET}"
        printf '%s  [dry-run] the EBS volumes would be deleted%s\n' "${C_DIM}" "${C_RESET}"
        printf '%s  [dry-run] the network resources would be deleted%s\n' "${C_DIM}" "${C_RESET}"
        printf '%s  [dry-run] the AMIs and the key pair would be deleted%s\n' "${C_DIM}" "${C_RESET}"
        printf '%s  [dry-run] the state file and .env would be removed%s\n' "${C_DIM}" "${C_RESET}"
        print_banner "Dry run finished - nothing was changed"
        return 0
    fi

    destroy_cluster
    destroy_instances
    destroy_volumes
    destroy_enis
    destroy_security_groups
    destroy_route_tables
    destroy_nat_gateways
    destroy_elastic_ips
    destroy_internet_gateways
    destroy_subnets
    destroy_vpcs
    destroy_images
    destroy_keypairs
    destroy_local_files

    print_banner "The lab has been destroyed"

    if [ "${DRY_RUN}" = "1" ]; then
        return 0
    fi

    if verify_destroyed; then
        log_ok "Nothing is left running and nothing is billing."
    else
        log_warn "Some resources need another minute to disappear."
    fi

    printf '\n'
    log_info "To build the lab again:  ./provision.sh"
    printf '\n'
}

main "$@"
