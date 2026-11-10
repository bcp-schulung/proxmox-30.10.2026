#!/usr/bin/env bash
# =============================================================================
# lib/lab.sh - the seminar lab topology and its lifecycle
# =============================================================================
# Phase order (also the resume order used by provision.sh):
#   foundation -> amis -> nodes -> bootstrap -> cluster -> storage
#   -> backup -> guests -> security
# Each phase records its completion in the state file so that a re-run picks
# up where it left off instead of starting over.

if [ -n "${__LAB_LAB_SOURCED:-}" ]; then
    return 0
fi
__LAB_LAB_SOURCED=1

# shellcheck source=lib/common.sh
. "${LAB_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
. "${LAB_LIB_DIR}/config.sh"
# shellcheck source=lib/state.sh
. "${LAB_LIB_DIR}/state.sh"
# shellcheck source=lib/aws.sh
. "${LAB_LIB_DIR}/aws.sh"
# shellcheck source=lib/ssh.sh
. "${LAB_LIB_DIR}/ssh.sh"
# shellcheck source=lib/pve.sh
. "${LAB_LIB_DIR}/pve.sh"

# ---------------------------------------------------------------------------
# Phase tracking - lets provision.sh resume instead of starting over
# ---------------------------------------------------------------------------
LAB_PHASES="foundation amis nodes bootstrap cluster storage backup guests security"

# lab_phase_index <phase> -> position in the phase list (0 if unknown)
lab_phase_index() {
    local phase="$1" i=1 p
    for p in ${LAB_PHASES}; do
        if [ "${p}" = "${phase}" ]; then
            printf '%s' "${i}"
            return 0
        fi
        i=$((i + 1))
    done
    printf '0'
}

# lab_phase_done <phase> -> true when the phase already completed
lab_phase_done() {
    local target current
    target="$(lab_phase_index "$1")"
    current="$(lab_phase_index "$(state_get ".phase" "init")")"
    [ "${current}" -ge "${target}" ] && [ "${target}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Address plan helpers
# ---------------------------------------------------------------------------

# The node names, one per line.
lab_node_list() {
    # shellcheck disable=SC2086  # the node list is intentionally split into words
    printf '%s\n' ${PVE_NODE_NAMES}
}

# lab_node_index <name> -> 1-based index
lab_node_index() {
    local name="$1" i=1 n
    for n in $(lab_node_list); do
        if [ "${n}" = "${name}" ]; then
            printf '%s' "${i}"
            return 0
        fi
        i=$((i + 1))
    done
    printf '0'
}

# lab_node_mgmt_ip <name> -> 10.20.0.1<index>
lab_node_mgmt_ip() {
    local index
    index="$(lab_node_index "$1")"
    printf '10.20.0.%s' "$((10 + index))"
}

# lab_node_overlay_cidr <name> -> 10.10.<index>0.0/24
#
# Every node runs its own overlay subnet. Identical subnets on all nodes
# would collide, because the nodes route between each other over the VPC.
lab_node_overlay_cidr() {
    local index
    index="$(lab_node_index "$1")"
    printf '10.10.%s0.0/24' "${index}"
}

lab_node_overlay_gw() {
    local index
    index="$(lab_node_index "$1")"
    printf '10.10.%s0.1' "${index}"
}

lab_node_dhcp_start() {
    local index
    index="$(lab_node_index "$1")"
    printf '10.10.%s0.100' "${index}"
}

lab_node_dhcp_end() {
    local index
    index="$(lab_node_index "$1")"
    printf '10.10.%s0.200' "${index}"
}

# All overlay routes that a given node needs, as "cidr=gw,cidr=gw".
lab_node_overlay_routes() {
    local name="$1" other routes=""
    for other in $(lab_node_list); do
        [ "${other}" = "${name}" ] && continue
        routes="${routes}$(lab_node_overlay_cidr "${other}")=$(lab_node_mgmt_ip "${other}"),"
    done
    printf '%s' "${routes%,}"
}

# ---------------------------------------------------------------------------
# Phase 1 - AWS foundation
# ---------------------------------------------------------------------------
lab_phase_foundation() {
    log_step "Phase 1/8 - AWS network foundation"

    local az vpc_id
    az="$(aws_az)"
    [ -n "${az}" ] || die "No usable availability zone found in ${AWS_REGION}"
    log_info "Availability zone: ${az}"

    vpc_id="$(aws_vpc_id)"
    if [ -z "${vpc_id}" ]; then
        vpc_id="$(aws_vpc_create)"
        log_ok "VPC ${vpc_id} (${VPC_CIDR}) created"
    else
        log_info "VPC ${vpc_id} already exists"
    fi
    # Always (re-)apply the tag: a VPC that was created by an earlier,
    # interrupted run may not carry it, and destroy.sh finds resources by tag.
    aws_tag_lab "${vpc_id}" "vpc" "vpc"
    state_set ".vpc.id" "\"${vpc_id}\""
    state_set ".vpc.cidr" "\"${VPC_CIDR}\""
    state_set ".vpc.az" "\"${az}\""

    # --- subnets ---
    local subnet
    for entry in "public:${SUBNET_PUBLIC_CIDR}" "services:${SUBNET_SERVICES_CIDR}"; do
        local role="${entry%%:*}" cidr="${entry#*:}"
        subnet="$(aws_subnet_id "${cidr}")"
        if [ -z "${subnet}" ]; then
            subnet="$(aws_subnet_create "${cidr}" "${az}" "${role}")"
            log_ok "Subnet ${role} ${subnet} (${cidr}) created"
        else
            log_info "Subnet ${role} ${subnet} already exists"
        fi
        aws_tag_lab "${subnet}" "subnet-${role}" "subnet"
        state_set ".subnets.${role}" "{\"id\":\"${subnet}\",\"cidr\":\"${cidr}\"}"
    done

    # --- internet gateway + NAT ---
    local igw
    igw="$(aws_igw_id)"
    if [ -z "${igw}" ]; then
        igw="$(aws_igw_create)"
        log_ok "Internet gateway ${igw} created"
    fi
    state_set ".igw" "\"${igw}\""

    local natgw
    natgw="$(aws_natgw_id)"
    if [ -z "${natgw}" ]; then
        natgw="$(aws_natgw_create)"
        log_ok "NAT gateway ${natgw} created"
    else
        log_info "NAT gateway ${natgw} already exists"
    fi
    state_set ".natgw" "\"${natgw}\""

    lab_create_route_tables "${igw}" "${natgw}"

    # --- security groups ---
    lab_create_security_groups

    # --- key pair ---
    if ! aws_keypair_exists "${PVE_KEYPAIR_NAME}"; then
        aws_keypair_create
        log_ok "Key pair ${PVE_KEYPAIR_NAME} created"
    else
        log_info "Key pair ${PVE_KEYPAIR_NAME} already exists"
        if [ ! -f "${PVE_SSH_KEY_PATH}" ]; then
            log_warn "Key pair exists but ${PVE_SSH_KEY_PATH} is missing."
            log_warn "Delete the key pair manually or use a different PVE_KEYPAIR_NAME."
        fi
    fi
    state_set ".keypair" "\"${PVE_KEYPAIR_NAME}\""

    state_set_phase "foundation"
}

# The public subnet routes straight to the internet gateway so the nodes keep
# their public IP. The services subnet routes through the NAT gateway.
# The default route table is left alone on purpose - it must not send the
# public subnet through the NAT gateway, or the public IP would be lost.
lab_create_route_tables() {
    local igw="$1" natgw="$2"
    local public_subnet services_subnet rtb_public rtb_private

    public_subnet="$(state_get ".subnets.public.id")"
    services_subnet="$(state_get ".subnets.services.id")"

    rtb_public="$(state_get ".rtb.public")"
    if [ -z "${rtb_public}" ]; then
        rtb_public="$(aws_create_route_table "public")"
        state_set ".rtb.public" "\"${rtb_public}\""
    fi
    aws_route_to "${rtb_public}" "0.0.0.0/0" "${igw}" "internet-gateway" 2>/dev/null || true
    aws_associate_route_table "${public_subnet}" "${rtb_public}" 2>/dev/null || true

    rtb_private="$(state_get ".rtb.private")"
    if [ -z "${rtb_private}" ]; then
        rtb_private="$(aws_create_route_table "private")"
        state_set ".rtb.private" "\"${rtb_private}\""
    fi
    aws_route_to "${rtb_private}" "0.0.0.0/0" "${natgw}" "nat-gateway" 2>/dev/null || true
    aws_associate_route_table "${services_subnet}" "${rtb_private}" 2>/dev/null || true

    log_ok "Route tables configured (public -> IGW, services -> NAT gateway)"
}

# The operator's source IP, used to scope the web UI and SSH rules.
lab_caller_cidr() {
    if [ -z "${AWS_CALLER_IP:-}" ]; then
        log_info "Detecting the operator's public IP address..."
        AWS_CALLER_IP="$(detect_caller_ip)"
        if [ -n "${AWS_CALLER_IP}" ]; then
            export AWS_CALLER_IP
            log_ok "Operator IP: ${AWS_CALLER_IP}"
        else
            log_warn "Could not detect the operator IP - using 0.0.0.0/0 for SSH and the web UI."
            AWS_CALLER_IP="0.0.0.0/0"
            export AWS_CALLER_IP
        fi
    fi

    # A security group rule needs a prefix length.
    case "${AWS_CALLER_IP}" in
        */*) : ;;
        *)   AWS_CALLER_IP="${AWS_CALLER_IP}/32"; export AWS_CALLER_IP ;;
    esac

    printf '%s' "${AWS_CALLER_IP}"
}

lab_create_security_groups() {
    local pve_sg services_sg caller
    caller="$(lab_caller_cidr)"

    pve_sg="$(aws_sg_id "pve-lab")"
    if [ -z "${pve_sg}" ]; then
        pve_sg="$(aws_sg_create "pve-lab" "Proxmox VE cluster nodes (seminar lab)")"
        log_ok "Security group pve-lab (${pve_sg}) created"
    else
        log_info "Security group pve-lab already exists"
    fi
    aws_tag_lab "${pve_sg}" "pve-lab" "sg"

    # The rules are re-applied on every run so that a security group left
    # behind by an interrupted run gets completed. Adding a rule that
    # already exists is tolerated.
    aws_sg_allow "${pve_sg}" tcp 22 "${caller}" "SSH from the operator"
    aws_sg_allow "${pve_sg}" tcp 8006 "${caller}" "Proxmox web UI from the operator"
    aws_sg_allow "${pve_sg}" tcp "5900-5999" "${caller}" "VNC/SPICE console from the operator"

    # Node to node: corosync/KNET (5405-5412), pvecm (7946), SSH, web UI.
    aws_sg_allow "${pve_sg}" udp "5405-5412" "${VPC_CIDR}" "corosync/KNET between nodes"
    aws_sg_allow "${pve_sg}" tcp 22 "${VPC_CIDR}" "SSH between nodes"
    aws_sg_allow "${pve_sg}" tcp 8006 "${VPC_CIDR}" "web UI between nodes"

    # Guest overlay traffic is NATed through the node, so the node's own
    # address is what the shared storage sees.
    aws_sg_allow "${pve_sg}" tcp 2049 "${VPC_CIDR}" "NFS from the cluster"
    aws_sg_allow "${pve_sg}" tcp 8007 "${VPC_CIDR}" "Proxmox Backup Server"
    aws_sg_allow "${pve_sg}" icmp -1 "${VPC_CIDR}" "ICMP inside the VPC"
    state_set ".sgs.pve" "\"${pve_sg}\""

    services_sg="$(aws_sg_id "services-lab")"
    if [ -z "${services_sg}" ]; then
        services_sg="$(aws_sg_create "services-lab" "NFS and Proxmox Backup Server (seminar lab)")"
        log_ok "Security group services-lab (${services_sg}) created"
    else
        log_info "Security group services-lab already exists"
    fi
    aws_tag_lab "${services_sg}" "services-lab" "sg"

    aws_sg_allow "${services_sg}" tcp 22 "${caller}" "SSH from the operator"
    aws_sg_allow "${services_sg}" tcp 2049 "${VPC_CIDR}" "NFS from the cluster nodes"
    aws_sg_allow "${services_sg}" tcp 8007 "${VPC_CIDR}" "PBS web UI and API from the cluster"
    aws_sg_allow "${services_sg}" icmp -1 "${VPC_CIDR}" "ICMP inside the VPC"
    state_set ".sgs.services" "\"${services_sg}\""
}

# ---------------------------------------------------------------------------
# Phase 2 - AMIs
# ---------------------------------------------------------------------------
lab_phase_amis() {
    log_step "Phase 2/8 - Building the AMIs"

    local pve_ami pbs_ami
    pve_ami="$(state_get ".amis.pve")"
    pbs_ami="$(state_get ".amis.pbs")"

    if [ -n "${pve_ami}" ] && aws_quiet ec2 describe-images --region "${AWS_REGION}" --image-ids "${pve_ami}"; then
        log_info "Proxmox AMI ${pve_ami} already built"
    else
        local base_ami
        base_ami="$(aws_debian_ami)"
        [ -n "${base_ami}" ] || die "Could not find a Debian 13 cloud image in ${AWS_REGION}"
        log_info "Base Debian AMI: ${base_ami}"

        pve_ami="$(lab_build_ami "pve" "${LAB_ROOT_DIR}/packer/pve.pkr.hcl" "${base_ami}")"
        state_set ".amis.pve" "\"${pve_ami}\""
    fi

    if [ -n "${pbs_ami}" ] && aws_quiet ec2 describe-images --region "${AWS_REGION}" --image-ids "${pbs_ami}"; then
        log_info "PBS AMI ${pbs_ami} already built"
    else
        local base_ami
        base_ami="$(aws_debian_ami)"
        pbs_ami="$(lab_build_ami "pbs" "${LAB_ROOT_DIR}/packer/pbs.pkr.hcl" "${base_ami}")"
        state_set ".amis.pbs" "\"${pbs_ami}\""
    fi

    state_set_phase "amis"
}

# lab_build_ami <pve|pbs> <hcl-file> <base-ami>
lab_build_ami() {
    local kind="$1" hcl="$2" base_ami="$3"
    local ami_name var_name

    if [ "${kind}" = "pve" ]; then
        ami_name="${PVE_AMI_NAME}"
        var_name="pve_ami_name"
    else
        ami_name="${PBS_AMI_NAME}"
        var_name="pbs_ami_name"
    fi

    log_info "Building the ${kind} AMI with Packer (this takes several minutes)..."
    if ! packer init "${hcl}" >/dev/null 2>&1; then
        log_warn "packer init failed - continuing, the plugin may already be installed"
    fi
    if ! packer build \
        -var "region=${PACKER_AMI_REGION}" \
        -var "base_ami=${base_ami}" \
        -var "${var_name}=${ami_name}" \
        -var "root_volume_size=${PVE_ROOT_VOLUME_SIZE}" \
        -var "ssh_key_path=${PVE_SSH_KEY_PATH}" \
        "${hcl}"; then
        die "Packer build for the ${kind} AMI failed."
    fi

    local ami
    ami="$(aws_ami_id_by_name "${ami_name}")"
    [ -n "${ami}" ] || die "Packer finished but the AMI ${ami_name} could not be found."
    log_ok "${kind} AMI built: ${ami}"
    printf '%s' "${ami}"
}

# ---------------------------------------------------------------------------
# Phase 3 - EC2 instances
# ---------------------------------------------------------------------------
lab_phase_nodes() {
    log_step "Phase 3/8 - Launching the EC2 instances"

    local pve_ami az
    pve_ami="$(state_get ".amis.pve")"
    az="$(state_get ".vpc.az")"
    [ -n "${pve_ami}" ] || die "The Proxmox AMI is missing from the state file."

    # --- Proxmox nodes ---
    local node instance_id
    for node in $(lab_node_list); do
        instance_id="$(state_get ".instances.${node}.id")"
        if [ -n "${instance_id}" ] && aws_quiet ec2 describe-instances --region "${AWS_REGION}" --instance-ids "${instance_id}"; then
            log_info "Node ${node} (${instance_id}) already exists"
            continue
        fi

        log_info "Launching ${node} (${PVE_INSTANCE_TYPE})..."
        instance_id="$(aws_instance_launch "${node}" "pve" "${PVE_INSTANCE_TYPE}" "${pve_ami}" "${az}")"
        [ -n "${instance_id}" ] || die "Failed to launch ${node}"
        aws_wait_instance_running "${instance_id}"
        log_ok "${node} launched: ${instance_id}"

        local eni0 priv pub
        eni0="$(aws_instance_eni "${instance_id}" 0)"
        priv="$(aws_eni_private_ip "${eni0}")"
        pub="$(aws_instance_public_ip "${instance_id}")"

        state_set ".instances.${node}" "$(jq -n \
            --arg id "${instance_id}" --arg role pve --arg eni0 "${eni0}" \
            --arg priv "${priv}" --arg pub "${pub}" --arg type "${PVE_INSTANCE_TYPE}" \
            --arg mac0 "$(aws_eni_mac "${eni0}")" \
            --arg vol "$(aws_instance_volume_for_device "${instance_id}" /dev/sdf)" \
            '{id:$id, role:$role, eni0:$eni0, private_ip:$priv,
              public_ip:$pub, instance_type:$type, mac0:$mac0,
              data_volume:$vol}')"
    done

    # --- NFS server ---
    if [ -z "$(state_get ".instances.nfs1.id")" ]; then
        log_info "Launching the NFS server..."
        instance_id="$(aws_instance_launch_service "nfs1" "nfs" "${NFS_INSTANCE_TYPE}" \
            "$(aws_debian_ami)" "${az}" "${NFS_VOLUME_SIZE}")"
        [ -n "${instance_id}" ] || die "Failed to launch the NFS server"
        aws_wait_instance_running "${instance_id}"
        log_ok "NFS server launched: ${instance_id}"
        state_set ".instances.nfs1" "$(jq -n \
            --arg id "${instance_id}" --arg role nfs \
            --arg priv "$(aws_eni_private_ip "$(aws_instance_eni "${instance_id}" 0)")" \
            --arg pub "$(aws_instance_public_ip "${instance_id}")" \
            --arg vol "$(aws_instance_volume_for_device "${instance_id}" /dev/sdf)" \
            '{id:$id, role:$role, private_ip:$priv, public_ip:$pub, data_volume:$vol}')"
    fi

    # --- Proxmox Backup Server ---
    if [ -z "$(state_get ".instances.pbs1.id")" ]; then
        log_info "Launching the Proxmox Backup Server..."
        instance_id="$(aws_instance_launch_service "pbs1" "pbs" "${PBS_INSTANCE_TYPE}" \
            "$(state_get ".amis.pbs")" "${az}" "${PBS_VOLUME_SIZE}")"
        [ -n "${instance_id}" ] || die "Failed to launch the Proxmox Backup Server"
        aws_wait_instance_running "${instance_id}"
        log_ok "PBS launched: ${instance_id}"
        state_set ".instances.pbs1" "$(jq -n \
            --arg id "${instance_id}" --arg role pbs \
            --arg priv "$(aws_eni_private_ip "$(aws_instance_eni "${instance_id}" 0)")" \
            --arg pub "$(aws_instance_public_ip "${instance_id}")" \
            --arg vol "$(aws_instance_volume_for_device "${instance_id}" /dev/sdf)" \
            '{id:$id, role:$role, private_ip:$priv, public_ip:$pub, data_volume:$vol}')"
    fi

    state_set_phase "nodes"
}

# ---------------------------------------------------------------------------
# Phase 4 - node bootstrap
# ---------------------------------------------------------------------------
lab_phase_bootstrap() {
    log_step "Phase 4/8 - Bootstrapping the Proxmox nodes"

    local node instance_id priv
    for node in $(lab_node_list); do
        instance_id="$(state_get ".instances.${node}.id")"
        priv="$(state_get ".instances.${node}.private_ip")"

        if [ "$(state_get ".instances.${node}.bootstrapped")" = "true" ]; then
            log_info "Node ${node} is already bootstrapped"
            continue
        fi

        log_info "Waiting for SSH on ${node} (${priv})..."
        if ! wait_ssh "${priv}" 600; then
            log_warn "SSH to ${node} did not come up in time - trying the SSM fallback"
            if ! ssm_agent_installed "${instance_id}"; then
                die "Cannot reach ${node}: neither SSH nor SSM is available."
            fi
        fi

        # The data volume is located by its EBS serial, not by device index.
        local data_device
        data_device="$(resolve_volume_device "${priv}" "$(state_get ".instances.${node}.data_volume")" || true)"
        if [ -z "${data_device}" ]; then
            data_device="$(ssh_exec "${priv}" "lsblk -ndo NAME | grep -v '^nvme0n1$' | head -1" || true)"
        fi
        [ -n "${data_device}" ] || die "Could not determine the data volume device on ${node}."
        log_info "Data volume on ${node}: ${data_device}"

        log_info "Running the bootstrap on ${node}..."
        ssh_run_local "${priv}" "${LAB_ROOT_DIR}/scripts/node-bootstrap.sh" \
            --name "${node}" \
            --mgmt-ip "${priv}" \
            --mgmt-gw "${VPC_GATEWAY}" \
            --mgmt-cidr 24 \
            --guest-cidr "$(lab_node_overlay_cidr "${node}")" \
            --guest-gw "$(lab_node_overlay_gw "${node}")" \
            --dhcp-start "$(lab_node_dhcp_start "${node}")" \
            --dhcp-end "$(lab_node_dhcp_end "${node}")" \
            --data-device "${data_device}" \
            --routes "$(lab_node_overlay_routes "${node}")" \
            --root-password "$(state_get ".pve.root_password")" \
            || die "Bootstrap failed on ${node}"

        log_info "Rebooting ${node} to apply the network configuration..."
        ssh_exec_q "${priv}" "nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &" || true
        sleep 10
        if ! wait_ssh "${priv}" "${BOOT_TIMEOUT}"; then
            die "${node} did not come back after the reboot. Use ./debug.sh for diagnostics."
        fi
        log_ok "${node} is back with the new network configuration"

        # Sanity check the bridge.
        if ! ssh_exec_q "${priv}" "ip -4 addr show vmbr0 | grep -q 'inet'"; then
            die "${node} rebooted but vmbr0 has no address. Use ./debug.sh."
        fi

        state_set ".instances.${node}.bootstrapped" "true"
        state_set ".instances.${node}.data_device" "\"${data_device}\""
    done

    state_set_phase "bootstrap"
}

# ---------------------------------------------------------------------------
# Phase 5 - cluster formation
# ---------------------------------------------------------------------------
lab_phase_cluster() {
    log_step "Phase 5/8 - Forming the Proxmox cluster"

    local first_node
    first_node="$(lab_node_list | head -1)"

    if [ "$(state_get ".pve.cluster_formed")" = "true" ]; then
        log_info "Cluster '${PVE_CLUSTER_NAME}' is already formed"
        return 0
    fi

    # Node-to-node SSH trust. 'pvecm add --use_ssh' authenticates with these
    # keys, which removes the interactive password prompt from the join.
    log_info "Distributing the cluster SSH keys"
    local node pubkey
    local keys=""
    for node in $(lab_node_list); do
        local priv
        priv="$(state_get ".instances.${node}.private_ip")"
        ssh_exec "${priv}" "mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
            [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C 'pve-cluster-${node}' >/dev/null" || true
        pubkey="$(ssh_exec "${priv}" "cat /root/.ssh/id_ed25519.pub")"
        keys="${keys}${pubkey}"$'\n'
    done

    for node in $(lab_node_list); do
        local priv
        priv="$(state_get ".instances.${node}.private_ip")"
        local other
        while IFS= read -r other; do
            [ -n "${other}" ] || continue
            ssh_install_pubkey "${priv}" "${other}" || true
        done <<< "${keys}"
    done

    # Create the cluster on the first node.
    local first_priv fingerprint
    first_priv="$(state_get ".instances.${first_node}.private_ip")"

    if ! pve_cmd_q "${first_priv}" "pvecm status | grep -q 'Quorate'"; then
        pve_cluster_create "${first_priv}" "${PVE_CLUSTER_NAME}" "${first_priv}" 1
        log_ok "Cluster '${PVE_CLUSTER_NAME}' created on ${first_node}"
    fi

    fingerprint="$(pve_cluster_fingerprint "${first_priv}")"
    [ -n "${fingerprint}" ] || die "Could not read the cluster CA fingerprint."

    # Join the remaining nodes.
    local index=2
    for node in $(lab_node_list | tail -n +2); do
        local priv
        priv="$(state_get ".instances.${node}.private_ip")"
        if pve_cmd_q "${priv}" "pvecm status | grep -q 'Quorate'"; then
            log_info "${node} is already a cluster member"
        else
            pve_cluster_join "${priv}" "${first_priv}" "${priv}" "${index}" "${fingerprint}" \
                || die "Failed to join ${node} to the cluster."
            log_ok "${node} joined the cluster"
        fi
        index=$((index + 1))
    done

    # Verify quorum.
    local quorate
    quorate="$(pve_cmd "${first_priv}" "pvecm status | grep -c 'Quorate: Yes'")"
    if [ "${quorate}" -lt 1 ]; then
        die "The cluster is not quorate. Use ./debug.sh to investigate."
    fi
    log_ok "Cluster is quorate"

    state_set ".pve.cluster" "\"${PVE_CLUSTER_NAME}\""
    state_set ".pve.cluster_formed" "true"
    state_set_phase "cluster"
}

# ---------------------------------------------------------------------------
# Phase 6 - storage
# ---------------------------------------------------------------------------
lab_phase_storage() {
    log_step "Phase 6/8 - Configuring the storage backends"

    local first_node priv
    first_node="$(lab_node_list | head -1)"
    priv="$(state_get ".instances.${first_node}.private_ip")"

    # --- shared NFS ---
    local nfs_ip
    nfs_ip="$(state_get ".instances.nfs1.private_ip")"
    if [ -z "${nfs_ip}" ]; then
        die "The NFS server is not part of the state file."
    fi

    log_info "Preparing the NFS export on ${nfs_ip}"
    lab_setup_nfs_server "${nfs_ip}"

    pve_storage_add_nfs "${priv}" "${NFS_STORAGE_ID}" "${nfs_ip}" "${NFS_EXPORT}"
    log_ok "Shared storage '${NFS_STORAGE_ID}' configured"

    # --- local LVM-thin ---
    pve_storage_add_lvmthin "${priv}" "${LOCAL_STORAGE_ID}" "${LOCAL_VG_NAME}" "${LOCAL_THINPOOL_NAME}"
    log_ok "Local storage '${LOCAL_STORAGE_ID}' configured"

    # --- local directory storage ---
    # Every node keeps its own /var/lib/vz. The cluster-wide definition points
    # at the local path, so each node resolves it against its own disk. This
    # is where the cloud-init drives live.
    if ! pve_cmd_out "${priv}" pvesm status | grep -qE "^local "; then
        log_info "Adding the local directory storage"
        pve_cmd "${priv}" pvesm add dir local --path /var/lib/vz --content iso,vztmpl,backup,snippets
    fi

    state_set ".pve.nfs_server" "\"${nfs_ip}\""
    state_set_phase "storage"
}

# Configure the NFS server: install the kernel server, mount the data volume
# and export the lab directory.
lab_setup_nfs_server() {
    local host="$1"
    local volume_id device
    volume_id="$(state_get ".instances.nfs1.data_volume")"
    device="$(resolve_volume_device "${host}" "${volume_id}" || true)"

    if [ -z "${device}" ]; then
        log_warn "Could not resolve the NFS data volume - assuming /dev/nvme1n1"
        device="/dev/nvme1n1"
    fi

    log_info "Configuring the NFS export ${NFS_EXPORT} on ${host}"
    ssh_run_local "${host}" "${LAB_ROOT_DIR}/scripts/nfs-setup.sh" "${device}" "${NFS_EXPORT}" \
        || die "The NFS server setup failed on ${host}"
    log_ok "NFS export ${NFS_EXPORT} is live on ${host}"
}

# ---------------------------------------------------------------------------
# Phase 7 - Proxmox Backup Server
# ---------------------------------------------------------------------------
lab_phase_backup() {
    log_step "Phase 7/8 - Configuring the Proxmox Backup Server"

    local pbs_ip pbs_pub volume_id device fingerprint
    pbs_ip="$(state_get ".instances.pbs1.private_ip")"
    pbs_pub="$(state_get ".instances.pbs1.public_ip")"
    [ -n "${pbs_ip}" ] || die "The PBS instance is not part of the state file."

    local password="${PBS_PASSWORD}"
    [ -n "${password}" ] || password="$(gen_password 24)"
    export PBS_PASSWORD="${password}"

    log_info "Waiting for SSH on the PBS..."
    wait_ssh "${pbs_ip}" 600 || die "Cannot reach the Proxmox Backup Server."

    volume_id="$(state_get ".instances.pbs1.data_volume")"
    device="$(resolve_volume_device "${pbs_ip}" "${volume_id}" || true)"
    [ -n "${device}" ] || device="/dev/nvme1n1"

    log_info "Preparing the PBS datastore volume (${device})"
    ssh_run_local "${pbs_ip}" "${LAB_ROOT_DIR}/scripts/pbs-setup.sh" \
        "${device}" "${PBS_DATASTORE}" "${PBS_USERNAME}" "${password}" \
        || die "The Proxmox Backup Server setup failed."

    fingerprint="$(ssh_exec "${pbs_ip}" "proxmox-backup-manager fingerprint 2>/dev/null | grep -oE '[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){31}' | head -1")"
    [ -n "${fingerprint}" ] || die "Could not read the Proxmox Backup Server fingerprint."
    log_ok "PBS fingerprint: ${fingerprint}"

    # Register the PBS datastore on the cluster.
    local first_priv
    first_priv="$(state_get ".instances.$(lab_node_list | head -1).private_ip")"
    pve_storage_add_pbs "${first_priv}" "${PBS_STORAGE_ID}" "${pbs_ip}" "${PBS_DATASTORE}" \
        "${PBS_USERNAME}" "${password}" "${fingerprint}"

    state_set ".pve.pbs_server" "\"${pbs_ip}\""
    state_set ".pve.pbs_public_ip" "\"${pbs_pub}\""
    state_set ".pve.pbs_fingerprint" "\"${fingerprint}\""
    state_set ".pve.pbs_password" "\"${password}\""
    state_set_phase "backup"
}

# ---------------------------------------------------------------------------
# Phase 8 - guests
# ---------------------------------------------------------------------------
lab_phase_guests() {
    log_step "Phase 8/8 - Provisioning the guests"

    local first_node first_priv
    first_node="$(lab_node_list | head -1)"
    first_priv="$(state_get ".instances.${first_node}.private_ip")"

    local ssh_pubkey guest_password
    ssh_pubkey="$(ssh_keygen -y -f "${PVE_SSH_KEY_PATH}" 2>/dev/null || cat "${PVE_SSH_KEY_PATH}.pub")"
    guest_password="$(state_get ".pve.guest_password")"
    if [ -z "${guest_password}" ]; then
        guest_password="$(gen_password 20)"
        state_set ".pve.guest_password" "\"${guest_password}\""
    fi

    lab_provision_vms "${first_node}" "${first_priv}" "${ssh_pubkey}" "${guest_password}"
    lab_provision_cts "${first_node}" "${first_priv}" "${ssh_pubkey}" "${guest_password}"

    state_set_phase "guests"
}

# Create the golden image VM, turn it into a template and clone it.
lab_provision_vms() {
    local node="$1" host="$2" ssh_pubkey="$3" guest_password="$4"
    local storage="${NFS_STORAGE_ID}"

    if [ "$(state_get ".pve.vms_ready")" = "true" ]; then
        log_info "The VMs are already provisioned"
        return 0
    fi

    local image="/var/lib/vz/${GUEST_OS_NAME}-genericcloud.qcow2"
    if ! ssh_exec_q "${host}" "test -f '${image}'"; then
        pve_download "${host}" "${GUEST_OS_URL}" "${image}"
    else
        log_info "The guest image is already present on ${node}"
    fi

    # --- the golden image / template ---
    local template_id="${VM_TEMPLATE_ID}"
    if ! pve_cmd_q "${host}" "qm status ${template_id} >/dev/null 2>&1"; then
        local ci_yaml
        ci_yaml="$(pve_write_cloudinit "${host}" "${template_id}" "${VM_TEMPLATE_NAME}" "${ssh_pubkey}" "${guest_password}")"
        pve_vm_create_from_cloudimage "${host}" "${template_id}" "${VM_TEMPLATE_NAME}" "${storage}" "${image}" "${ci_yaml}"
        pve_vm_make_template "${host}" "${template_id}"
        log_ok "Template ${template_id} (${VM_TEMPLATE_NAME}) created"
    fi

    # --- the clones ---
    # The guests are spread over the nodes so that the cluster looks like a
    # real one and so that the shared storage is exercised.
    local node2 node3
    node2="$(lab_node_list | sed -n 2p)"
    node3="$(lab_node_list | sed -n 3p)"

    local host2="${node2}" host3="${node3}"
    local priv2 priv3
    priv2="$(state_get ".instances.${node2}.private_ip")"
    priv3="$(state_get ".instances.${node3}.private_ip")"

    lab_clone_vm "${host}" "${priv}" "${template_id}" "${VM_WEB_ID}" "${VM_WEB_NAME}" "${storage}" full "${ssh_pubkey}" "${guest_password}"
    lab_clone_vm "${host2}" "${priv2}" "${template_id}" "${VM_CLONE_FULL_ID}" "${VM_CLONE_FULL_NAME}" "${storage}" full "${ssh_pubkey}" "${guest_password}"
    lab_clone_vm "${host3}" "${priv3}" "${template_id}" "${VM_CLONE_LINKED_ID}" "${VM_CLONE_LINKED_NAME}" "${storage}" linked "${ssh_pubkey}" "${guest_password}"

    # --- start them ---
    lab_start_vm "${host}" "${priv}" "${VM_WEB_ID}"
    lab_start_vm "${host2}" "${priv2}" "${VM_CLONE_FULL_ID}"
    lab_start_vm "${host3}" "${priv3}" "${VM_CLONE_LINKED_ID}"

    state_set ".pve.vms_ready" "true"
    state_set ".pve.guests.vms" "[\"${VM_WEB_ID}\",\"${VM_TEMPLATE_ID}\",\"${VM_CLONE_FULL_ID}\",\"${VM_CLONE_LINKED_ID}\"]"
}

# Start a VM if it is not running yet.
lab_start_vm() {
    local host="$1" priv="$2" vmid="$3"
    if pve_cmd_q "${priv}" "qm status ${vmid} | grep -q running"; then
        return 0
    fi
    log_info "Starting VM ${vmid} on ${host}"
    pve_guest_start "${priv}" vm "${vmid}" || log_warn "Could not start VM ${vmid}"
}

lab_clone_vm() {
    local host="$1" priv="$2" src="$3" newid="$4" name="$5" storage="$6" mode="$7" ssh_pubkey="$8" guest_password="$9"

    if pve_cmd_q "${priv}" "qm status ${newid} >/dev/null 2>&1"; then
        log_info "VM ${newid} (${name}) already exists"
        return 0
    fi

    pve_vm_clone "${priv}" "${src}" "${newid}" "${name}" "${storage}" "${mode}"

    # Give the clone its own identity.
    local ci_yaml
    ci_yaml="$(pve_write_cloudinit "${priv}" "${newid}" "${name}" "${ssh_pubkey}" "${guest_password}")"
    pve_vm_set_cloudinit "${priv}" "${newid}" "${name}" "${ci_yaml}"
    log_ok "VM ${newid} (${name}) created on ${host}"
}

# Create the unprivileged LXC containers.
lab_provision_cts() {
    local node="$1" host="$2" ssh_pubkey="$3" guest_password="$4"
    local storage="${NFS_STORAGE_ID}"

    if [ "$(state_get ".pve.cts_ready")" = "true" ]; then
        log_info "The containers are already provisioned"
        return 0
    fi

    # Fetch the container template into the shared storage.
    local template_file
    template_file="$(state_get ".pve.ct_template")"
    if [ -z "${template_file}" ]; then
        template_file="$(lab_fetch_ct_template "${host}")"
        state_set ".pve.ct_template" "\"${template_file}\""
    fi

    # One container per node, so that the cluster exercises the shared storage
    # for the container rootfs as well.
    local node2 priv2
    node2="$(lab_node_list | sed -n 2p)"
    priv2="$(state_get ".instances.${node2}.private_ip")"

    lab_create_ct "${host}" "${priv}" "${CT_APP_ID}" "${CT_APP_NAME}" "${storage}" "${template_file}" "${guest_password}" "${ssh_pubkey}"
    lab_create_ct "${node2}" "${priv2}" "${CT_DB_ID}" "${CT_DB_NAME}" "${storage}" "${template_file}" "${guest_password}" "${ssh_pubkey}"

    state_set ".pve.cts_ready" "true"
    state_set ".pve.guests.cts" "[\"${CT_APP_ID}\",\"${CT_DB_ID}\"]"
}

# Resolve and download the Debian 13 standard container template.
lab_fetch_ct_template() {
    local host="$1"
    local listing file

    log_info "Looking up the latest Debian 13 container template"
    listing="$(ssh_exec "${host}" "curl -fsS --max-time 60 http://download.proxmox.com/images/system/ | grep -oE 'debian-13-standard_[0-9.]+-[0-9]+_amd64\\.tar\\.zst' | sort -uV | tail -1" 2>/dev/null || true)"
    file="${listing}"

    if [ -z "${file}" ]; then
        # The deck pins this exact version - fall back to it.
        file="debian-13-standard_13.6-1_amd64.tar.zst"
        log_warn "Could not list the template directory - falling back to ${file}"
    fi
    log_info "Container template: ${file}"

    if ! pve_cmd_q "${host}" "pvesm list ${NFS_STORAGE_ID} --content vztmpl | grep -q '${file}'"; then
        log_info "Downloading ${file} into ${NFS_STORAGE_ID}"
        pve_cmd "${host}" "pvesm download-url ${NFS_STORAGE_ID} http://download.proxmox.com/images/system/${file} ${file}" \
            || log_warn "pvesm download-url failed - trying the storage mount point"
        if ! pve_cmd_q "${host}" "pvesm list ${NFS_STORAGE_ID} --content vztmpl | grep -q '${file}'"; then
            pve_cmd "${host}" "mkdir -p /mnt/pve/${NFS_STORAGE_ID}/template && \
                curl -fSL --retry 3 -o /mnt/pve/${NFS_STORAGE_ID}/template/${file} http://download.proxmox.com/images/system/${file}"
        fi
    else
        log_info "The container template is already present"
    fi

    printf '%s' "${file}"
}

lab_create_ct() {
    local host="$1" priv="$2" ctid="$3" name="$4" storage="$5" template="$6" password="$7" sshkey="$8"

    if pve_cmd_q "${priv}" "pct status ${ctid} >/dev/null 2>&1"; then
        log_info "Container ${ctid} (${name}) already exists"
        return 0
    fi

    pve_ct_create "${priv}" "${ctid}" "${name}" "${storage}" "${template}" "${password}" "${sshkey}"
    log_ok "Container ${ctid} (${name}) created on ${host}"

    # The container has to run before 'pct exec' can reach it.
    if ! pve_cmd_q "${priv}" "pct status ${ctid} | grep -q running"; then
        log_info "Starting container ${ctid}"
        pve_guest_start "${priv}" ct "${ctid}" || log_warn "Could not start container ${ctid}"
    fi

    # The QEMU guest agent lets the host query the container and freeze its
    # filesystem for backups.
    log_info "Installing the guest agent in container ${ctid}"
    pve_cmd "${priv}" "pct exec ${ctid} -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1; systemctl enable --now qemu-guest-agent'" \
        || log_warn "Could not install the guest agent in container ${ctid}"
}

# ---------------------------------------------------------------------------
# Optional - the security seminar exercises
# ---------------------------------------------------------------------------
lab_phase_security() {
    log_step "Security baseline (seminar exercises)"

    local first_priv
    first_priv="$(state_get ".instances.$(lab_node_list | head -1).private_ip")"

    local user_password
    user_password="$(state_get ".pve.sec_user_password")"
    if [ -z "${user_password}" ]; then
        user_password="$(gen_password 20)"
        state_set ".pve.sec_user_password" "\"${user_password}\""
    fi

    pve_security_realm "${first_priv}" "${SEC_REALM}"
    pve_security_user "${first_priv}" "${SEC_USER}" "${user_password}"
    pve_security_role "${first_priv}" "${SEC_ROLE}" "${SEC_ROLE_PRIVS}"
    pve_security_acl "${first_priv}" "/vms/${VM_WEB_ID}" "${SEC_USER}" "${SEC_ROLE}"

    pve_security_token "${first_priv}" "${SEC_TOKEN_USER}" "${SEC_TOKEN_NAME}"
    pve_security_token_acl "${first_priv}" "${SEC_TOKEN_PATH}" "${SEC_TOKEN_USER}!${SEC_TOKEN_NAME}" "${SEC_ROLE}"

    # shellcheck disable=SC2046  # the node list is intentionally split into words
    pve_security_acme_selfsigned "${first_priv}" $(lab_node_list)

    log_info "The datacenter firewall is NOT enabled automatically - it would cut"
    log_info "off the web UI and corosync. Enable it manually during the exercise:"
    log_info "  pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT"

    state_set ".pve.security_ready" "true"
    state_set_phase "security"
}

# ---------------------------------------------------------------------------
# Teardown helpers (shared by clean.sh and destroy.sh)
# ---------------------------------------------------------------------------

# Destroy every VM and container on every node.
lab_destroy_guests() {
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
            ssh_exec_q "${priv}" "qm destroy ${vmid} --purge 1 --destroy-unreferenced-disks 1"
        done

        local ctid
        for ctid in $(ssh_exec "${priv}" "pct list 2>/dev/null | tail -n +2 | awk '{print \$1}'"); do
            [ -n "${ctid}" ] || continue
            log_info "${node}: destroying container ${ctid}"
            ssh_exec_q "${priv}" "pct destroy ${ctid} --purge 1"
        done
    done
}

# Remove the cluster configuration from the nodes.
lab_reset_cluster() {
    log_step "Resetting the cluster configuration"

    local node priv last=""
    for node in $(lab_node_list); do
        priv="$(state_get ".instances.${node}.private_ip")"
        ssh_exec_q "${priv}" "true" || continue
        log_info "${node}: leaving the cluster"
        ssh_exec_q "${priv}" "pvecm leave --force"
        last="${priv}"
    done

    # Wipe the stored cluster configuration on the last node so that the next
    # 'pvecm create' starts from a clean slate.
    if [ -n "${last}" ]; then
        log_info "Removing the stored cluster configuration"
        ssh_exec_q "${last}" "rm -f /etc/pve/corosync.conf /etc/pve/cluster/ /etc/pve/nodes/*/corosync.conf 2>/dev/null; true"
    fi

    # The storage definitions live in the cluster configuration too.
    local first_priv
    first_priv="$(state_get ".instances.$(lab_node_list | head -1).private_ip")"
    if ssh_exec_q "${first_priv}" "true"; then
        ssh_exec_q "${first_priv}" "pvesm remove ${NFS_STORAGE_ID} 2>/dev/null; pvesm remove ${PBS_STORAGE_ID} 2>/dev/null; pvesm remove ${LOCAL_STORAGE_ID} 2>/dev/null; true"
    fi

    # Reset the recorded state so that a re-run starts from the foundation.
    state_set ".pve.cluster_formed" "false"
    state_set ".pve.vms_ready" "false"
    state_set ".pve.cts_ready" "false"
    state_set ".pve.security_ready" "false"
    state_set ".phase" "\"foundation\""
}

# Empty the shared NFS export.
lab_clean_nfs_export() {
    local nfs_ip
    nfs_ip="$(state_get ".instances.nfs1.private_ip")"
    [ -n "${nfs_ip}" ] || return 0
    if ssh_exec_q "${nfs_ip}" "true"; then
        log_step "Cleaning the shared NFS export"
        ssh_exec_q "${nfs_ip}" "rm -rf ${NFS_EXPORT}/images/* ${NFS_EXPORT}/rootfs/* ${NFS_EXPORT}/iso/* ${NFS_EXPORT}/vztmpl/* ${NFS_EXPORT}/backup/* 2>/dev/null; true"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
lab_print_summary() {
    local first_node
    first_node="$(lab_node_list | head -1)"

    print_banner "Proxmox VE seminar lab is ready"

    printf '%sWeb UI%s\n' "${C_BOLD}" "${C_RESET}"
    local node
    for node in $(lab_node_list); do
        local pub
        pub="$(state_get ".instances.${node}.public_ip")"
        printf '  %-8s https://%s:8006/   (root@pam)\n' "${node}" "${pub}"
    done
    printf '  %-8s https://%s:8007/   (Proxmox Backup Server)\n' "pbs1" "$(state_get ".instances.pbs1.public_ip")"

    printf '\n%sSSH%s\n' "${C_BOLD}" "${C_RESET}"
    for node in $(lab_node_list); do
        printf '  ssh -i %s root@%s\n' "${PVE_SSH_KEY_PATH}" "$(state_get ".instances.${node}.public_ip")"
    done

    printf '\n%sCredentials%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  Proxmox root password : %s\n' "$(state_get ".pve.root_password")"
    printf '  Guest root password   : %s\n' "$(state_get ".pve.guest_password")"
    printf '  PBS backup user       : %s\n' "${PBS_USERNAME}"
    printf '  PBS backup password   : %s\n' "$(state_get ".pve.pbs_password")"

    printf '\n%sCluster%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  Name        : %s\n' "${PVE_CLUSTER_NAME}"
    printf '  Storage     : %s (shared NFS), %s (local LVM-thin)\n' "${NFS_STORAGE_ID}" "${LOCAL_STORAGE_ID}"
    printf '  Backup      : %s -> %s\n' "${PBS_STORAGE_ID}" "$(state_get ".pve.pbs_server")"

    printf '\n%sGuests%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  VM %-5s %-20s (template)\n' "${VM_TEMPLATE_ID}" "${VM_TEMPLATE_NAME}"
    printf '  VM %-5s %-20s (full clone, live-migration target)\n' "${VM_WEB_ID}" "${VM_WEB_NAME}"
    printf '  VM %-5s %-20s (full clone)\n' "${VM_CLONE_FULL_ID}" "${VM_CLONE_FULL_NAME}"
    printf '  VM %-5s %-20s (linked clone)\n' "${VM_CLONE_LINKED_ID}" "${VM_CLONE_LINKED_NAME}"
    printf '  CT %-5s %-20s (unprivileged LXC)\n' "${CT_APP_ID}" "${CT_APP_NAME}"
    printf '  CT %-5s %-20s (unprivileged LXC)\n' "${CT_DB_ID}" "${CT_DB_NAME}"

    # Where the guests actually ended up.
    local first_priv placement
    first_priv="$(state_get ".instances.${first_node}.private_ip")"
    placement="$(pve_cmd "${first_priv}" "pvesh get /cluster/resources --output-format json" 2>/dev/null \
        | jq -r '.[] | select(.type == "qemu" or .type == "lxc") | "  \(.type) \(.vmid)\t\(.name)\t\(.node)"' 2>/dev/null || true)"
    if [ -n "${placement}" ]; then
        printf '\n%sPlacement%s\n' "${C_BOLD}" "${C_RESET}"
        printf '%s\n' "${placement}"
    fi

    printf '\n%sNext steps%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  ./debug.sh              collect a full diagnostic report\n'
    printf '  ./shutdown.sh           stop the lab for the night (keeps everything)\n'
    printf '  ./clean.sh --scope all  remove everything including the AWS resources\n'
    printf '\n'
}
