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

# lab_reach_ip <instance-name> -> the address the operator uses to reach a node.
#
# This is the IPv6 address when the instance has one. The private IPv4
# address is only reachable from inside the VPC, and the public IPv4
# address is unreachable from a CGNAT network, so the IPv6 address is the
# one that works from the operator's laptop.
lab_reach_ip() {
    state_reach_ip "$1"
}

# lab_url_host <address> - the address as it appears in a URL or an ssh
# command line. An IPv6 literal has to be bracketed, otherwise the colons
# are read as a port separator.
lab_url_host() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *)   printf '%s' "$1" ;;
    esac
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

    # --- IPv6 ---
    lab_create_ipv6

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

    # --- SSM instance profile ---
    # The SSM agent on the instances opens an outbound connection to the
    # Systems Manager control plane. That is the only connection method that
    # works from a CGNAT network, where the EC2 public IPv4 address is
    # unreachable and native IPv6 is often missing too.
    local profile
    profile="$(aws_ssm_instance_profile_create)"
    log_ok "SSM instance profile ${profile} ready"
    state_set ".ssm.profile" "\"${profile}\""

    state_set_phase "foundation"
}

# Both subnets route straight to the internet gateway.
#
# The services subnet used to route through the NAT gateway, on the theory
# that the service instances do not need to be reachable from outside. That
# is wrong: a NAT gateway translates outbound traffic only, so the NFS
# server and the backup server had no inbound path at all. Not even from
# inside the VPC, and not even for the SSH server that the operator needs
# to configure the backup server.
#
# The route to the internet gateway gives the services a public IPv4
# address that the operator can reach, exactly like the Proxmox nodes.
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

    # The route to the internet gateway replaces the route to the NAT
    # gateway. An existing NAT route has to be deleted first, because a
    # route table can only have one default route.
    aws_route_delete "${rtb_private}" "0.0.0.0/0" 2>/dev/null || true
    aws_route_to "${rtb_private}" "0.0.0.0/0" "${igw}" "internet-gateway" 2>/dev/null || true
    aws_associate_route_table "${services_subnet}" "${rtb_private}" 2>/dev/null || true

    log_ok "Route tables configured (public and services -> IGW)"
}

# IPv6 setup.
#
# The lab has to be reachable from wherever the operator is - a hotel Wi-Fi,
# a phone hotspot, a university network. Those are usually CGNAT networks
# where the IPv4 address is a shared translation and EC2 instance public
# IPv4 addresses are unreachable. A native IPv6 address is not translated,
# so the nodes are addressed over IPv6.
#
# Two /56 blocks are needed: AWS reserves the whole Amazon-provided /56 for
# the first subnet that asks for an IPv6 range, so a second subnet needs a
# second /56.
lab_create_ipv6() {
    local vpc_cidr public_subnet services_subnet sub_cidr

    # --- VPC level ---
    if [ -z "$(aws_vpc_ipv6_cidr)" ]; then
        log_info "Associating an IPv6 /56 with the VPC..."
        aws_vpc_ipv6_associate || die "Could not associate an IPv6 CIDR with the VPC"
        if ! aws_vpc_ipv6_wait; then
            die "The VPC IPv6 association did not complete in time."
        fi
    fi
    vpc_cidr="$(aws_vpc_ipv6_cidr)"
    [ -n "${vpc_cidr}" ] || die "The VPC has no IPv6 CIDR"
    log_ok "VPC IPv6: ${vpc_cidr}"
    state_set ".ipv6.vpc_cidr" "\"${vpc_cidr}\""

    # --- subnet level ---
    # Each subnet gets a /64 carved out of a /56 of the VPC. The first
    # subnet takes the base /64 of the first /56; a second subnet needs a
    # second /56, because AWS reserves the entire first one for the first
    # subnet.
    local role subnet
    for role in public services; do
        subnet="$(state_get ".subnets.${role}.id")"
        [ -n "${subnet}" ] || continue

        if [ -z "$(aws_subnet_ipv6_cidr "${subnet}")" ]; then
            # Try the base /64 of every /56 associated with the VPC until
            # one is accepted. AWS rejects a /64 that is already taken.
            local assoc cidr ok=0
            for assoc in $(aws_cli ec2 describe-vpcs --region "${AWS_REGION}" \
                    --filters "Name=cidr,Values=${VPC_CIDR}" \
                    --query "Vpcs[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State==\`associated\`].Ipv6CidrBlock" \
                    --output text 2>/dev/null); do
                cidr="${assoc%/*}::/64"
                if aws_subnet_ipv6_associate "${subnet}" "${cidr}" 2>/dev/null; then
                    log_ok "Subnet ${role}: IPv6 ${cidr} associated"
                    ok=1
                    break
                fi
            done
            if [ "${ok}" -eq 0 ]; then
                # All the /56s of the VPC are used up by other subnets.
                # Associate one more /56 and retry.
                log_info "Associating an additional IPv6 /56 for subnet ${role}..."
                aws_vpc_ipv6_associate || true
                aws_vpc_ipv6_wait || true
                for assoc in $(aws_cli ec2 describe-vpcs --region "${AWS_REGION}" \
                        --filters "Name=cidr,Values=${VPC_CIDR}" \
                        --query "Vpcs[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State==\`associated\`].Ipv6CidrBlock" \
                        --output text 2>/dev/null); do
                    cidr="${assoc%/*}::/64"
                    if aws_subnet_ipv6_associate "${subnet}" "${cidr}" 2>/dev/null; then
                        log_ok "Subnet ${role}: IPv6 ${cidr} associated"
                        ok=1
                        break
                    fi
                done
            fi
            [ "${ok}" -eq 1 ] || die "Could not associate an IPv6 range with subnet ${role}"
        else
            log_info "Subnet ${role} already has an IPv6 range"
        fi

        sub_cidr="$(aws_subnet_ipv6_cidr "${subnet}")"
        state_set ".subnets.${role}.ipv6_cidr" "\"${sub_cidr}\""

        # New instances get an IPv6 address automatically.
        aws_subnet_ipv6_enable_auto "${subnet}" || true
    done

    # --- routes ---
    # The public subnet routes IPv6 straight to the internet gateway. The
    # services subnet uses an egress-only internet gateway, because a NAT
    # gateway cannot be the next hop for an IPv6 destination.
    local rtb_public rtb_services eigw
    rtb_public="$(state_get ".rtb.public")"
    rtb_services="$(state_get ".rtb.private")"

    if [ -n "${rtb_public}" ]; then
        aws_route_ipv6 "${rtb_public}" "::/0" "internet-gateway" "$(state_get ".igw")" 2>/dev/null || true
    fi

    if [ -n "${rtb_services}" ]; then
        eigw="$(aws_eigw_id)"
        if [ -z "${eigw}" ]; then
            eigw="$(aws_eigw_create)"
            log_ok "Egress-only internet gateway ${eigw} created"
        fi
        aws_route_ipv6 "${rtb_services}" "::/0" "egress-only-internet-gateway" "${eigw}" 2>/dev/null || true
        state_set ".eigw" "\"${eigw}\""
    fi

    log_ok "IPv6 configured (public subnet -> IGW, services subnet -> egress-only IGW)"
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

# Keep the operator's access up to date.
#
# The operator's public IPv4 address changes. A network with a NAT gives a
# new address every time the connection is re-established, and a mobile
# network changes it while the lab is running. The security group rule
# that was written during the first provisioning run is therefore useless
# a few minutes later, and the operator loses the access to the web UI and
# to SSH - while the lab itself is perfectly fine.
#
# This function is called before every phase, so that the operator always
# has access to the nodes, no matter how the address changed in the
# meantime. It removes the stale single-host rules and adds the current
# address.
lab_sync_operator_access() {
    local pve_sg services_sg caller caller6

    pve_sg="$(state_get ".sgs.pve")"
    services_sg="$(state_get ".sgs.services")"

    # Nothing to do before the security groups exist.
    [ -n "${pve_sg}" ] || return 0

    # The address is detected again on every run: the cached value in the
    # environment would keep the stale address alive.
    AWS_CALLER_IP="$(detect_caller_ip)"
    if [ -z "${AWS_CALLER_IP}" ]; then
        log_warn "Could not detect the operator IP - the access rules are left as they are."
        return 0
    fi

    caller="${AWS_CALLER_IP}/32"

    # The IPv6 address is stable in practice, so the IPv6 rules are not
    # touched. They are the fallback for a network without IPv4.
    caller6="$(lab_caller_ipv6_cidr)"

    local changed=0
    local sg
    for sg in "${pve_sg}" "${services_sg}"; do
        [ -n "${sg}" ] || continue

        # Remove the stale rules and add the current address.
        aws_sg_revoke_operator "${sg}"

        aws_sg_allow "${sg}" tcp 22 "${caller}" "SSH from the operator"
        aws_sg_allow "${sg}" tcp 8006 "${caller}" "Proxmox web UI from the operator"
        aws_sg_allow "${sg}" tcp 8007 "${caller}" "Proxmox web UI and API from the operator"
        aws_sg_allow "${sg}" tcp "5900-5999" "${caller}" "VNC/SPICE console from the operator"

        changed=1
    done

    if [ "${changed}" = "1" ]; then
        log_ok "Operator access synced to ${caller}"
    fi
}

# The operator's public IPv6 address, as a CIDR. Empty when the operator has
# no usable IPv6 - in that case the lab is reached over IPv4.
lab_caller_ipv6_cidr() {
    if [ -z "${AWS_CALLER_IPV6:-}" ]; then
        AWS_CALLER_IPV6="$(detect_caller_ipv6)"
        export AWS_CALLER_IPV6
    fi
    [ -n "${AWS_CALLER_IPV6}" ] || return 0

    case "${AWS_CALLER_IPV6}" in
        */*) printf '%s' "${AWS_CALLER_IPV6}" ;;
        *)   printf '%s/128' "${AWS_CALLER_IPV6}" ;;
    esac
}

lab_create_security_groups() {
    local pve_sg services_sg caller caller6
    caller="$(lab_caller_cidr)"
    caller6="$(lab_caller_ipv6_cidr)"
    if [ -n "${caller6}" ]; then
        log_ok "Operator IPv6: ${caller6}"
    else
        log_warn "No operator IPv6 detected - the lab will only be reachable over IPv4."
    fi

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

    # The same rules for IPv6. The operator's IPv4 is frequently a CGNAT
    # translation, so the IPv6 rules are what actually make the lab
    # reachable from a hotel or a phone hotspot.
    if [ -n "${caller6}" ]; then
        aws_sg_allow "${pve_sg}" tcp 22 "${caller6}" "SSH from the operator (IPv6)"
        aws_sg_allow "${pve_sg}" tcp 8006 "${caller6}" "Proxmox web UI from the operator (IPv6)"
        aws_sg_allow "${pve_sg}" tcp "5900-5999" "${caller6}" "VNC/SPICE console from the operator (IPv6)"
    fi

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
    # The cluster nodes and the operator's helper instances reach the
    # services over the private addresses.
    aws_sg_allow "${services_sg}" tcp 22 "${VPC_CIDR}" "SSH inside the VPC"
    aws_sg_allow "${services_sg}" tcp 2049 "${VPC_CIDR}" "NFS from the cluster nodes"
    aws_sg_allow "${services_sg}" tcp 8007 "${VPC_CIDR}" "PBS web UI and API from the cluster"
    aws_sg_allow "${services_sg}" icmp -1 "${VPC_CIDR}" "ICMP inside the VPC"

    if [ -n "${caller6}" ]; then
        aws_sg_allow "${services_sg}" tcp 22 "${caller6}" "SSH from the operator (IPv6)"
        aws_sg_allow "${services_sg}" tcp 8007 "${caller6}" "PBS web UI from the operator (IPv6)"
    fi

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
        pve_ami="$(lab_build_ami "pve")"
        state_set ".amis.pve" "\"${pve_ami}\""
    fi

    if [ -n "${pbs_ami}" ] && aws_quiet ec2 describe-images --region "${AWS_REGION}" --image-ids "${pbs_ami}"; then
        log_info "PBS AMI ${pbs_ami} already built"
    else
        pbs_ami="$(lab_build_ami "pbs")"
        state_set ".amis.pbs" "\"${pbs_ami}\""
    fi

    # The NFS storage server gets its own AMI, so that it comes up with the
    # same boot-time network configuration as the Proxmox nodes.
    local nfs_ami
    nfs_ami="$(state_get ".amis.nfs")"
    if [ -n "${nfs_ami}" ] && aws_quiet ec2 describe-images --region "${AWS_REGION}" --image-ids "${nfs_ami}"; then
        log_info "NFS AMI ${nfs_ami} already built"
    else
        nfs_ami="$(lab_build_ami "nfs")"
        state_set ".amis.nfs" "\"${nfs_ami}\""
    fi

    state_set_phase "amis"
}

# lab_build_ami <pve|pbs>
#
# The image is built by packer/build-ami.sh rather than by Packer itself.
#
# Packer aborts a provisioner when the SSH connection to the build instance
# drops, and the link to AWS from a hotel or a campus network drops
# regularly. The build script therefore runs the whole build detached on the
# instance and the result is polled from outside, so that a dropped
# connection cannot affect the build.
lab_build_ami() {
    local kind="$1"

    log_info "Building the ${kind} AMI (this takes 20-40 minutes)..."
    # The build script prints its progress to stdout, which would otherwise
    # be captured by the command substitution this function runs in.
    if ! "${LAB_ROOT_DIR}/packer/build-ami.sh" "${kind}" >&2; then
        die "The ${kind} AMI build failed."
    fi

    # The build script writes the ID of the image that it created. The name
    # is not used for the lookup, because the build appends a timestamp to
    # it when the configured name is already taken.
    local ami
    ami="$(cat /tmp/lab-ami-id.txt 2>/dev/null || true)"
    if [ -z "${ami}" ] || [ "${ami}" = "None" ]; then
        # Fall back to the configured name.
        local ami_name
        if [ "${kind}" = "pve" ]; then
            ami_name="${PVE_AMI_NAME}"
        else
            ami_name="${PBS_AMI_NAME}"
        fi
        ami="$(aws_ami_id_by_name "${ami_name}")"
    fi

    [ -n "${ami}" ] || die "The build finished but the AMI could not be found."
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
            --arg reach "$(aws_instance_reach_ip "${instance_id}")" \
            --arg ipv6 "$(aws_instance_ipv6 "${instance_id}")" \
            --arg ipv6gw "$(aws_ipv6_gateway "${AWS_REGION}")" \
            --arg vol "$(aws_instance_volume_for_device "${instance_id}" /dev/sdf)" \
            '{id:$id, role:$role, eni0:$eni0, private_ip:$priv,
              public_ip:$pub, reach_ip:$reach, ipv6:$ipv6, ipv6_gateway:$ipv6gw,
              instance_type:$type, mac0:$mac0,
              data_volume:$vol}')"
    done

    # --- NFS server ---
    if [ -z "$(state_get ".instances.nfs1.id")" ]; then
        log_info "Launching the NFS server..."
        # The NFS server uses the AMI that was built for it, so that it
        # comes up with the same boot-time network configuration as the
        # Proxmox nodes.
        local nfs_ami
        nfs_ami="$(state_get ".amis.nfs")"
        [ -n "${nfs_ami}" ] || nfs_ami="$(aws_debian_ami)"
        instance_id="$(aws_instance_launch_service "nfs1" "nfs" "${NFS_INSTANCE_TYPE}" \
            "${nfs_ami}" "${az}" "${NFS_VOLUME_SIZE}")"
        [ -n "${instance_id}" ] || die "Failed to launch the NFS server"
        aws_wait_instance_running "${instance_id}"
        log_ok "NFS server launched: ${instance_id}"
        state_set ".instances.nfs1" "$(jq -n \
            --arg id "${instance_id}" --arg role nfs \
            --arg priv "$(aws_eni_private_ip "$(aws_instance_eni "${instance_id}" 0)")" \
            --arg pub "$(aws_instance_public_ip "${instance_id}")" \
            --arg reach "$(aws_instance_reach_ip "${instance_id}")" \
            --arg ipv6 "$(aws_instance_ipv6 "${instance_id}")" \
            --arg ipv6gw "$(aws_ipv6_gateway "${AWS_REGION}")" \
            --arg vol "$(aws_instance_volume_for_device "${instance_id}" /dev/sdf)" \
            '{id:$id, role:$role, private_ip:$priv, public_ip:$pub, reach_ip:$reach,
              ipv6:$ipv6, ipv6_gateway:$ipv6gw, data_volume:$vol}')"
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
            --arg reach "$(aws_instance_reach_ip "${instance_id}")" \
            --arg ipv6 "$(aws_instance_ipv6 "${instance_id}")" \
            --arg ipv6gw "$(aws_ipv6_gateway "${AWS_REGION}")" \
            --arg vol "$(aws_instance_volume_for_device "${instance_id}" /dev/sdf)" \
            '{id:$id, role:$role, private_ip:$priv, public_ip:$pub, reach_ip:$reach,
              ipv6:$ipv6, ipv6_gateway:$ipv6gw, data_volume:$vol}')"
    fi

    state_set_phase "nodes"
}

# ---------------------------------------------------------------------------
# Phase 4 - node bootstrap
# ---------------------------------------------------------------------------
lab_phase_bootstrap() {
    log_step "Phase 4/8 - Bootstrapping the Proxmox nodes"

    local node instance_id
    for node in $(lab_node_list); do
        instance_id="$(state_get ".instances.${node}.id")"

        if [ "$(state_get ".instances.${node}.bootstrapped")" = "true" ]; then
            log_info "Node ${node} is already bootstrapped"
            continue
        fi

        # The transport is chosen once and then stays stable: either SSH,
        # when the operator's network reaches the instance, or the Systems
        # Manager, which works from every network that can reach the AWS
        # API. The latter is the fallback for networks that block the
        # inbound traffic to the instances.
        log_info "Waiting for ${node} to become reachable..."
        if ! lab_wait_ready "${node}" 900; then
            die "Cannot reach ${node}: neither SSH nor SSM is available."
        fi
        log_info "${node} is reachable over $(transport_for "${node}")"

        # The data volume is located by its EBS serial, not by device index.
        local data_device
        data_device="$(lab_exec "${node}" \
            "sudo lsblk -ndo NAME,SERIAL | grep -F '$(state_get ".instances.${node}.data_volume" | tr -d '-')' | awk '{print \$1}'" 2>/dev/null | head -1)"
        if [ -z "${data_device}" ]; then
            data_device="$(lab_exec "${node}" \
                "sudo lsblk -ndo NAME | grep -v '^nvme0n1$' | head -1" 2>/dev/null | head -1)"
        fi
        [ -n "${data_device}" ] || die "Could not determine the data volume device on ${node}."
        log_info "Data volume on ${node}: ${data_device}"

        # The node keeps its private IPv4 address on the management interface
        # and gets the public IPv6 address as well. The operator reaches the
        # node over IPv6, the cluster talks over the private IPv4.
        local mgmt_ip ipv6 ipv6_gw
        mgmt_ip="$(state_get ".instances.${node}.private_ip")"
        ipv6="$(state_get ".instances.${node}.ipv6")"
        ipv6_gw="$(state_get ".instances.${node}.ipv6_gateway")"

        log_info "Running the bootstrap on ${node}..."
        lab_run_script "${node}" "${LAB_ROOT_DIR}/scripts/node-bootstrap.sh" \
            --name "${node}" \
            --mgmt-ip "${mgmt_ip}" \
            --mgmt-gw "${VPC_GATEWAY}" \
            --mgmt-cidr 24 \
            --mgmt-ipv6 "${ipv6}" \
            --mgmt-ipv6-cidr 64 \
            --mgmt-ipv6-gw "${ipv6_gw}" \
            --guest-cidr "$(lab_node_overlay_cidr "${node}")" \
            --guest-gw "$(lab_node_overlay_gw "${node}")" \
            --dhcp-start "$(lab_node_dhcp_start "${node}")" \
            --dhcp-end "$(lab_node_dhcp_end "${node}")" \
            --data-device "${data_device}" \
            --routes "$(lab_node_overlay_routes "${node}")" \
            --root-password "$(state_get ".pve.root_password")" \
            || die "Bootstrap failed on ${node}"

        log_info "Rebooting ${node} to apply the network configuration..."
        lab_exec_q "${node}" "sudo nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &" || true
        sleep 15
        if ! lab_wait_ready "${node}" "${BOOT_TIMEOUT}"; then
            die "${node} did not come back after the reboot. Use ./debug.sh for diagnostics."
        fi
        log_ok "${node} is back with the new network configuration"

        # Sanity check the bridge.
        if ! lab_exec_q "${node}" "sudo ip -4 addr show vmbr0 | grep -q 'inet'"; then
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
        lab_exec_q "${node}" "sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh && \
            sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C 'pve-cluster-${node}' >/dev/null" || true
        pubkey="$(lab_exec "${node}" "sudo cat /root/.ssh/id_ed25519.pub")"
        keys="${keys}${pubkey}"$'\n'
    done

    # Every node gets the public key of every other node, so that the
    # cluster can join over SSH without an interactive password.
    for node in $(lab_node_list); do
        local other
        while IFS= read -r other; do
            [ -n "${other}" ] || continue
            lab_exec_q "${node}" "sudo install -d -m 700 /root/.ssh && \
                sudo grep -qF '${other}' /root/.ssh/authorized_keys 2>/dev/null || \
                printf '%s\\n' '${other}' | sudo tee -a /root/.ssh/authorized_keys >/dev/null; \
                sudo chmod 600 /root/.ssh/authorized_keys" || true
        done <<< "${keys}"
    done

    # Create the cluster on the first node.
    #
    # The ring address of a node is its private IPv4 address.
    #
    # The cluster members talk to each other over the private network of
    # the VPC, so that is what the ring has to use. It also has to be
    # consistent: corosync refuses to start when the nodes of one link
    # use different address families, and it says so with
    #
    #   Nodes for link 0 have different IP families
    #
    # The address the operator uses to reach the node (the IPv6 address)
    # is not usable for the ring: it is not reachable from inside the
    # VPC at all.
    local first_priv first_ring fingerprint
    first_priv="$(state_reach_ip "${first_node}")"
    first_ring="$(state_get ".instances.${first_node}.private_ip")"
    [ -n "${first_ring}" ] || first_ring="${first_priv}"

    if ! pve_cmd_q "${first_priv}" "pvecm status | grep -q 'Quorate'"; then
        pve_cluster_create "${first_priv}" "${PVE_CLUSTER_NAME}" "${first_ring}" 1
        log_ok "Cluster '${PVE_CLUSTER_NAME}' created on ${first_node} (ring ${first_ring})"
    fi

    fingerprint="$(pve_cluster_fingerprint "${first_priv}")"
    [ -n "${fingerprint}" ] || die "Could not read the cluster CA fingerprint."

    # Join the remaining nodes.
    local index=2
    for node in $(lab_node_list | tail -n +2); do
        local priv ring
        priv="$(state_reach_ip "${node}")"
        ring="$(state_get ".instances.${node}.private_ip")"
        [ -n "${ring}" ] || ring="${priv}"

        if pve_cmd_q "${priv}" "pvecm status | grep -q 'Quorate'"; then
            log_info "${node} is already a cluster member"
        else
            pve_cluster_join "${priv}" "${first_priv}" "${ring}" "${index}" "${fingerprint}" "${first_ring}" \
                || die "Failed to join ${node} to the cluster."
            log_ok "${node} joined the cluster"
        fi
        index=$((index + 1))
    done

    # Verify quorum.
    #
    # The number of nodes is checked as well. A cluster that reports
    # "Quorate: Yes" with a single node is not the cluster that was
    # asked for.
    local quorate node_count
    # The '|| true' is needed: 'grep -c' returns a non-zero exit code
    # when it finds nothing, and that would abort the whole phase.
    # The output of pvecm pads the values with spaces, so the pattern
    # matches "Quorate:" and "Yes" with any number of spaces between
    # them. A pattern with a single space never matches.
    quorate="$(pve_cmd_out "${first_priv}" "pvecm status | grep -cE 'Quorate:[[:space:]]+Yes' || true" 2>/dev/null | tr -dc '0-9' | head -1)"
    node_count="$(pve_cmd_out "${first_priv}" "pvecm status | grep -cE 'Expected votes:[[:space:]]*[0-9]+' || true" 2>/dev/null | tr -dc '0-9' | head -1)"
    [ -n "${quorate}" ] || quorate=0
    [ -n "${node_count}" ] || node_count=0

    if [ "${quorate}" -lt 1 ]; then
        die "The cluster is not quorate. Use ./debug.sh to investigate."
    fi
    log_ok "Cluster is quorate"

    # The membership is checked explicitly: 'pvecm add' reports a success
    # even when the join failed, because the corosync service is started
    # asynchronously. The membership is the only reliable proof.
    local expected
    expected="$(lab_node_list | wc -w | tr -d ' ')"
    local members
    members="$(pve_cmd_out "${first_priv}" "pvecm nodes" 2>/dev/null | grep -cE '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+pve' || true)"

    if [ "${members}" -lt "${expected}" ]; then
        die "The cluster has ${members} members but ${expected} were expected. Use ./debug.sh to investigate."
    fi
    log_ok "Cluster '${PVE_CLUSTER_NAME}' has ${members} members and is quorate"

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
    priv="$(state_reach_ip "${first_node}")"

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
    device="$(lab_exec "nfs1" \
        "sudo lsblk -ndo NAME,SERIAL | grep -F '$(printf '%s' "${volume_id}" | tr -d '-')' | awk '{print \$1}'" 2>/dev/null | head -1)"
    if [ -z "${device}" ]; then
        device="$(lab_exec "nfs1" \
            "sudo lsblk -ndo NAME | grep -v '^nvme0n1$' | head -1" 2>/dev/null | head -1)"
    fi

    if [ -z "${device}" ]; then
        log_warn "Could not resolve the NFS data volume - assuming /dev/nvme1n1"
        device="/dev/nvme1n1"
    fi

    log_info "Configuring the NFS export ${NFS_EXPORT} on ${host}"
    lab_run_script "nfs1" "${LAB_ROOT_DIR}/scripts/nfs-setup.sh" "${device}" "${NFS_EXPORT}" \
        || die "The NFS server setup failed on ${host}"
    log_ok "NFS export ${NFS_EXPORT} is live on ${host}"
}

# ---------------------------------------------------------------------------
# Phase 7 - Proxmox Backup Server
# ---------------------------------------------------------------------------
lab_phase_backup() {
    log_step "Phase 7/8 - Configuring the Proxmox Backup Server"

    local pbs_ip pbs_pub volume_id device fingerprint
    pbs_ip="$(state_reach_ip "pbs1")"
    pbs_pub="$(state_get ".instances.pbs1.public_ip")"
    [ -n "${pbs_ip}" ] || die "The PBS instance is not part of the state file."

    local password="${PBS_PASSWORD}"
    [ -n "${password}" ] || password="$(gen_password 24)"
    export PBS_PASSWORD="${password}"

    log_info "Waiting for the PBS to become reachable..."
    lab_wait_ready "pbs1" 900 || die "Cannot reach the Proxmox Backup Server."

    volume_id="$(state_get ".instances.pbs1.data_volume")"
    device="$(lab_exec "pbs1" \
        "sudo lsblk -ndo NAME,SERIAL | grep -F '$(printf '%s' "${volume_id}" | tr -d '-')' | awk '{print \$1}'" 2>/dev/null | head -1)"
    if [ -z "${device}" ]; then
        device="$(lab_exec "pbs1" \
            "sudo lsblk -ndo NAME | grep -v '^nvme0n1$' | head -1" 2>/dev/null | head -1)"
    fi
    [ -n "${device}" ] || device="/dev/nvme1n1"

    log_info "Preparing the PBS datastore volume (${device})"
    lab_run_script "pbs1" "${LAB_ROOT_DIR}/scripts/pbs-setup.sh" \
        "${device}" "${PBS_DATASTORE}" "${PBS_USERNAME}" "${password}" \
        || die "The Proxmox Backup Server setup failed."

    fingerprint="$(lab_exec "pbs1" "sudo proxmox-backup-manager fingerprint 2>/dev/null | grep -oE '[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){31}' | head -1")"
    [ -n "${fingerprint}" ] || die "Could not read the Proxmox Backup Server fingerprint."
    log_ok "PBS fingerprint: ${fingerprint}"

    # Register the PBS datastore on the cluster.
    local first_priv
    first_priv="$(state_reach_ip "$(lab_node_list | head -1)")"
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
# Refuse to build the current inventory on a cluster that still holds the
# legacy one.
#
# The legacy inventory was the shared template 9001, the local template
# 9000 and the guests 100, 101 and 102. A cluster that holds those objects
# is in the old layout. Building the new inventory on top of it leaves
# both layouts in place, and the two disagree about what a template is.
#
# lab_assert_no_legacy_inventory <node-address>
lab_assert_no_legacy_inventory() {
    local priv="$1"
    local legacy="" vmid

    for vmid in 9000 9001 9002 100 101 102; do
        if pve_cmd_q "${priv}" "qm config ${vmid} >/dev/null 2>&1"; then
            legacy="${legacy} ${vmid}"
        fi
    done

    if [ -n "${legacy}" ]; then
        log_error "The legacy objects${legacy} are still on the cluster."
        log_error "The current inventory is ${VM_TEMPLATE_ID}, ${VM_TEMPLATE_ID_2}, ${VM_TEMPLATE_ID_3} and ${VM_WEB_ID}, ${VM_CLONE_FULL_ID}, ${VM_CLONE_LINKED_ID}."
        log_error "Remove the legacy objects before running this phase:"
        for vmid in ${legacy}; do
            log_error "  ssh admin@<node> 'sudo qm destroy ${vmid} --purge 1'"
        done
        die "Refusing to build a second layout on top of the legacy one."
    fi
}

lab_phase_guests() {
    log_step "Phase 8/8 - Provisioning the guests"

    local first_node first_priv
    first_node="$(lab_node_list | head -1)"
    first_priv="$(state_reach_ip "${first_node}")"

    # The legacy inventory. An earlier version of the lab used the shared
    # template 9001, the local template 9000 and the guests 100, 101 and
    # 102. A cluster that still holds those objects is in the old layout,
    # and building the new one on top of it would leave both in place.
    lab_assert_no_legacy_inventory "${first_priv}"

    local ssh_pubkey guest_password
    # The public key of the lab key pair. It is derived from the private
    # key, and the .pub file is the fallback.
    ssh_pubkey="$(ssh-keygen -y -f "${PVE_SSH_KEY_PATH}" 2>/dev/null || true)"
    if [ -z "${ssh_pubkey}" ]; then
        ssh_pubkey="$(cat "${PVE_SSH_KEY_PATH}.pub" 2>/dev/null || true)"
    fi
    [ -n "${ssh_pubkey}" ] || die "Could not read the public key of ${PVE_SSH_KEY_PATH}."
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
# lab_provision_vms <node> <node-address> <sshkey> <password>
#
# The first argument is the NAME of the node (pve1, pve2, ...), the
# second one its address. The name is what 'qm clone --target' expects,
# the address is what the SSH commands need.
#
# There are TWO templates, because the two kinds of clone have
# contradictory requirements:
#
#   A full clone can be moved to another node only when the source is on
#   shared storage. A template on the local storage of a node is refused
#   with
#
#     can't clone VM to node 'pve2' (VM uses local storage)
#
#   A linked clone is a snapshot of the template's disk, and a snapshot is
#   only possible on a storage that supports them. NFS does not, and the
#   request is refused with
#
#     Linked clone feature is not supported for 'nfs-lab:9000/...'
#
# So there is ONE template PER NODE, on the local LVM-thin storage of that
# node, and ONE running guest PER NODE, cloned from the template of the
# node it runs on.
lab_provision_vms() {
    local node="$1" host="$2" ssh_pubkey="$3" guest_password="$4"

    # The templates and the guests live on the node-local LVM-thin
    # storage, so that a template can be cloned onto its own node and
    # supports the snapshots that a linked clone needs.
    local storage="${LOCAL_STORAGE_ID}"

    if [ "$(state_get ".pve.vms_ready")" = "true" ]; then
        log_info "The VMs are already provisioned"
        return 0
    fi

    local image="/var/lib/vz/template/iso/${GUEST_OS_NAME}-generic-amd64.qcow2"

    # The address of this node. Every command that talks to a node
    # needs the address, and the name is only used for the messages.
    local priv
    priv="$(state_reach_ip "${node}")"

    # The nodes of the cluster.
    local node2 node3
    node2="$(lab_node_list | sed -n 2p)"
    node3="$(lab_node_list | sed -n 3p)"

    local priv2 priv3
    priv2="$(state_reach_ip "${node2}")"
    priv3="$(state_reach_ip "${node3}")"

    # ---------------------------------------------------------------------
    # The image and the templates.
    #
    # Every node gets its own copy of the Debian image and its own
    # template. The image is a qcow2 disk, not an ISO: it is brought in
    # with 'qm importdisk', because the 'iso/' subdirectory of a
    # directory storage only accepts real ISO extensions.
    # ---------------------------------------------------------------------
    local n name priv_of
    local ids="${VM_TEMPLATE_ID} ${VM_TEMPLATE_ID_2} ${VM_TEMPLATE_ID_3}"
    local names="${VM_TEMPLATE_NAME} ${VM_TEMPLATE_NAME_2} ${VM_TEMPLATE_NAME_3}"
    local privs="${priv} ${priv2} ${priv3}"
    local nodes="${node} ${node2} ${node3}"

    for n in 1 2 3; do
        name="$(echo "${names}" | cut -d' ' -f${n})"
        priv_of="$(echo "${privs}" | cut -d' ' -f${n})"
        local this_node this_id
        this_node="$(echo "${nodes}" | cut -d' ' -f${n})"
        this_id="$(echo "${ids}" | cut -d' ' -f${n})"

        # The image has to be on the node that will hold the template.
        if ! pve_cmd_q "${priv_of}" "test -f '${image}'"; then
            log_info "Downloading the guest image onto ${this_node}"
            pve_download "${priv_of}" "${GUEST_OS_URL}" "${image}"
        else
            log_info "The guest image is already present on ${this_node}"
        fi

        if ! pve_cmd_q "${priv_of}" "qm status ${this_id} >/dev/null 2>&1"; then
            log_info "Creating the template ${this_id} on ${this_node}"
            pve_vm_create_local_template "${priv_of}" "${this_id}" "${name}" "${storage}" "${image}"
            log_ok "Template ${this_id} (${name}) created on ${this_node}"
        else
            log_info "The template ${this_id} already exists on ${this_node}"
        fi
    done

    # ---------------------------------------------------------------------
    # The guests.
    #
    # Every guest is a FULL clone of the template on the node it runs on.
    # A full clone is used rather than a linked clone so that the three
    # guests are independent: a linked clone shares the disk of its
    # template and a write in the guest changes the template.
    # ---------------------------------------------------------------------
    lab_clone_vm "${node}"  "${priv}"  "${VM_TEMPLATE_ID}"   "${VM_WEB_ID}"          "${VM_WEB_NAME}"          "${storage}" full "${ssh_pubkey}" "${guest_password}" "${node}"
    lab_clone_vm "${node2}" "${priv2}" "${VM_TEMPLATE_ID_2}" "${VM_CLONE_FULL_ID}"   "${VM_CLONE_FULL_NAME}"   "${storage}" full "${ssh_pubkey}" "${guest_password}" "${node2}"
    lab_clone_vm "${node3}" "${priv3}" "${VM_TEMPLATE_ID_3}" "${VM_CLONE_LINKED_ID}" "${VM_CLONE_LINKED_NAME}" "${storage}" full "${ssh_pubkey}" "${guest_password}" "${node3}"

    # --- start them ---
    lab_start_vm "${node}"  "${priv}"  "${VM_WEB_ID}"
    lab_start_vm "${node2}" "${priv2}" "${VM_CLONE_FULL_ID}"
    lab_start_vm "${node3}" "${priv3}" "${VM_CLONE_LINKED_ID}"

    state_set ".pve.vms_ready" "true"
    state_set ".pve.guests.vms" "[\"${VM_TEMPLATE_ID}\",\"${VM_TEMPLATE_ID_2}\",\"${VM_TEMPLATE_ID_3}\",\"${VM_WEB_ID}\",\"${VM_CLONE_FULL_ID}\",\"${VM_CLONE_LINKED_ID}\"]"
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

# lab_clone_vm <target-node> <target-priv> <src-vmid> <newid> <name> <storage> <mode> <sshkey> <password> <template-node>
#
# The first argument is the NAME of the node that shall run the clone, the
# second one its address. The name is what 'qm clone --target' expects:
# the option refuses an address with
#
#   target: invalid format - value does not look like a valid node name
lab_clone_vm() {
    local target_node="$1" priv="$2" src="$3" newid="$4" name="$5" storage="$6" mode="$7" ssh_pubkey="$8" guest_password="$9"
    local template_node="${10}"

    if pve_cmd_q "${priv}" "qm status ${newid} >/dev/null 2>&1"; then
        log_info "VM ${newid} (${name}) already exists"
        return 0
    fi

    # The clone is started on the node that owns the template, and the
    # target node is passed with --target.
    local source_priv="${priv}"
    if [ -n "${template_node}" ]; then
        source_priv="$(state_reach_ip "${template_node}")"
    fi

    pve_vm_clone "${source_priv}" "${src}" "${newid}" "${name}" "${storage}" "${mode}" "${target_node}"

    # Give the clone its own identity.
    local ci_yaml
    ci_yaml="$(pve_write_cloudinit "${priv}" "${newid}" "${name}" "${ssh_pubkey}" "${guest_password}")"
    pve_vm_set_cloudinit "${priv}" "${newid}" "${name}" "${ci_yaml}"
    log_ok "VM ${newid} (${name}) created on ${target_node}"
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
    local node2 priv priv2
    node2="$(lab_node_list | sed -n 2p)"
    priv="$(state_reach_ip "${node}")"
    priv2="$(state_reach_ip "${node2}")"

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
    listing="$(pve_cmd_out "${host}" "curl -fsS --max-time 60 http://download.proxmox.com/images/system/ | grep -oE 'debian-13-standard_[0-9.]+-[0-9]+_amd64\\.tar\\.zst' | sort -uV | tail -1" 2>/dev/null || true)"
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
    first_priv="$(state_reach_ip "$(lab_node_list | head -1)")"

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
#
# ONLY the objects of the lab are destroyed. A blanket "destroy every VM
# that is listed" is what makes this function dangerous: it cannot tell a
# lab object from something that an operator put on the cluster on
# purpose, and it took the templates down with it when it ran against a
# cluster that also held other work.
#
# The inventory comes from the configuration. The guest templates and
# guests, and the containers, are listed there. Anything else on the
# cluster is left alone.
lab_destroy_guests() {
    log_step "Destroying the guests"

    # The lab's own objects. The templates and the guests of the three
    # nodes, and the two containers.
    local vms="${VM_TEMPLATE_ID} ${VM_TEMPLATE_ID_2} ${VM_TEMPLATE_ID_3} ${VM_WEB_ID} ${VM_CLONE_FULL_ID} ${VM_CLONE_LINKED_ID}"
    local cts="${CT_APP_ID} ${CT_DB_ID}"

    local node
    for node in $(lab_node_list); do
        if ! lab_exec_q "${node}" "true"; then
            log_warn "${node}: not reachable - its guests cannot be destroyed from here"
            continue
        fi

        local vmid
        for vmid in ${vms}; do
            [ -n "${vmid}" ] || continue
            if lab_exec_q "${node}" "sudo qm config ${vmid} >/dev/null 2>&1"; then
                log_info "${node}: destroying VM ${vmid}"
                lab_exec_q "${node}" "sudo qm destroy ${vmid} --purge 1 --destroy-unreferenced-disks 1"
            fi
        done

        local ctid
        for ctid in ${cts}; do
            [ -n "${ctid}" ] || continue
            if lab_exec_q "${node}" "sudo pct config ${ctid} >/dev/null 2>&1"; then
                log_info "${node}: destroying container ${ctid}"
                lab_exec_q "${node}" "sudo pct destroy ${ctid} --purge 1"
            fi
        done
    done
}

# Remove the cluster configuration from the nodes.
lab_reset_cluster() {
    log_step "Resetting the cluster configuration"

    local node last=""
    for node in $(lab_node_list); do
        lab_exec_q "${node}" "true" || continue
        log_info "${node}: leaving the cluster"
        lab_exec_q "${node}" "sudo pvecm leave --force"
        last="${node}"
    done

    # Wipe the stored cluster configuration on the last node so that the next
    # 'pvecm create' starts from a clean slate.
    if [ -n "${last}" ]; then
        log_info "Removing the stored cluster configuration"
        lab_exec_q "${last}" "sudo rm -f /etc/pve/corosync.conf /etc/pve/cluster/ /etc/pve/nodes/*/corosync.conf 2>/dev/null; true"
    fi

    # The storage definitions live in the cluster configuration too.
    local first_node
    first_node="$(lab_node_list | head -1)"
    if lab_exec_q "${first_node}" "true"; then
        lab_exec_q "${first_node}" "sudo pvesm remove ${NFS_STORAGE_ID} 2>/dev/null; sudo pvesm remove ${PBS_STORAGE_ID} 2>/dev/null; sudo pvesm remove ${LOCAL_STORAGE_ID} 2>/dev/null; true"
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
    if lab_exec_q "nfs1" "true"; then
        log_step "Cleaning the shared NFS export"
        lab_exec_q "nfs1" "rm -rf ${NFS_EXPORT}/images/* ${NFS_EXPORT}/rootfs/* ${NFS_EXPORT}/iso/* ${NFS_EXPORT}/vztmpl/* ${NFS_EXPORT}/backup/* 2>/dev/null; true"
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
        printf '  %-8s https://%s:8006/   (root@pam)\n' "${node}" "$(lab_url_host "$(state_reach_ip "${node}")")"
    done
    printf '  %-8s https://%s:8007/   (Proxmox Backup Server)\n' "pbs1" "$(lab_url_host "$(state_reach_ip "pbs1")")"

    printf '\n%sSSH%s\n' "${C_BOLD}" "${C_RESET}"
    for node in $(lab_node_list); do
        printf '  ssh -i %s %s@%s\n' "${PVE_SSH_KEY_PATH}" "${SSH_USER}" "$(lab_url_host "$(state_reach_ip "${node}")")"
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
    printf '  VM %-5s %-20s (template, on pve1)\n' "${VM_TEMPLATE_ID}" "${VM_TEMPLATE_NAME}"
    printf '  VM %-5s %-20s (template, on pve2)\n' "${VM_TEMPLATE_ID_2}" "${VM_TEMPLATE_NAME_2}"
    printf '  VM %-5s %-20s (template, on pve3)\n' "${VM_TEMPLATE_ID_3}" "${VM_TEMPLATE_NAME_3}"
    printf '  VM %-5s %-20s (full clone of %s, on pve1)\n' "${VM_WEB_ID}" "${VM_WEB_NAME}" "${VM_TEMPLATE_ID}"
    printf '  VM %-5s %-20s (full clone of %s, on pve2)\n' "${VM_CLONE_FULL_ID}" "${VM_CLONE_FULL_NAME}" "${VM_TEMPLATE_ID_2}"
    printf '  VM %-5s %-20s (full clone of %s, on pve3)\n' "${VM_CLONE_LINKED_ID}" "${VM_CLONE_LINKED_NAME}" "${VM_TEMPLATE_ID_3}"
    printf '  CT %-5s %-20s (unprivileged LXC)\n' "${CT_APP_ID}" "${CT_APP_NAME}"
    printf '  CT %-5s %-20s (unprivileged LXC)\n' "${CT_DB_ID}" "${CT_DB_NAME}"

    # Where the guests actually ended up.
    local first_priv placement
    first_priv="$(state_reach_ip "${first_node}")"
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
