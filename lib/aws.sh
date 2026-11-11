#!/usr/bin/env bash
# =============================================================================
# lib/aws.sh - AWS EC2/VPC wrappers used by the lab harness
# =============================================================================
# Every resource is tagged with:
#   Name    = <LAB_TAG>-<role>-<name>
#   LabTag  = <LAB_TAG>
#   LabRole = pve | nfs | pbs
# so that clean.sh can find and remove them safely by tag instead of by name.

if [ -n "${__LAB_AWS_SOURCED:-}" ]; then
    return 0
fi
__LAB_AWS_SOURCED=1

# shellcheck source=lib/common.sh
. "${LAB_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
. "${LAB_LIB_DIR}/config.sh"

LAB_TAG="${LAB_TAG:-pve-advanced-seminar-lab}"

# --- Tagging -----------------------------------------------------------------
aws_tag() {
    # aws_tag <resource-id> <key> <value>
    aws_cli ec2 create-tags --region "${AWS_REGION}" \
        --resources "$1" --tags "Key=$2,Value=$3" >/dev/null
}

aws_tag_lab() {
    # aws_tag_lab <resource-id> <name> <role>
    aws_cli ec2 create-tags --region "${AWS_REGION}" --resources "$1" \
        --tags "Key=Name,Value=${LAB_TAG}-$3-$2" \
               "Key=LabTag,Value=${LAB_TAG}" \
               "Key=LabRole,Value=$3" >/dev/null
}

# --- Lookups -----------------------------------------------------------------
aws_vpc_id() {
    aws_cli ec2 describe-vpcs --region "${AWS_REGION}" \
        --filters "Name=cidr,Values=${VPC_CIDR}" "Name=state,Values=available" \
        --query "Vpcs[0].VpcId" --output text 2>/dev/null | sed 's/^None$//'
}

aws_subnet_id() {
    # aws_subnet_id <cidr>
    aws_cli ec2 describe-subnets --region "${AWS_REGION}" \
        --filters "Name=cidr,Values=$1" \
        --query "Subnets[0].SubnetId" --output text 2>/dev/null | sed 's/^None$//'
}

aws_sg_id() {
    # aws_sg_id <name>
    aws_cli ec2 describe-security-groups --region "${AWS_REGION}" \
        --filters "Name=group-name,Values=$1" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | sed 's/^None$//'
}

aws_igw_id() {
    aws_cli ec2 describe-internet-gateways --region "${AWS_REGION}" \
        --filters "Name=attachment.vpc-id,Values=$(aws_vpc_id)" \
        --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | sed 's/^None$//'
}

aws_natgw_id() {
    # describe-nat-gateways is the one EC2 command that takes --filter
    # (singular) instead of --filters.
    aws_cli ec2 describe-nat-gateways --region "${AWS_REGION}" \
        --filter "Name=vpc-id,Values=$(aws_vpc_id)" \
        --query "NatGateways[0].NatGatewayId" --output text 2>/dev/null | sed 's/^None$//'
}

aws_az() {
    # First available, non-opt-in availability zone.
    local az
    az="$(aws_cli ec2 describe-availability-zones --region "${AWS_REGION}" \
        --filters "Name=state,Values=available" "Name=opt-in-status,Values=opt-in-not-required" \
        --query "AvailabilityZones[0].ZoneName" --output text 2>/dev/null)"
    [ "${az}" = "None" ] && az=""
    printf '%s' "${az}"
}

aws_instance_id() {
    # aws_instance_id <name>
    aws_cli ec2 describe-instances --region "${AWS_REGION}" \
        --filters "Name=tag:Name,Values=${LAB_TAG}-$2" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[0].Instances[0].InstanceId" --output text 2>/dev/null | sed 's/^None$//'
}

aws_ami_id_by_name() {
    aws_cli ec2 describe-images --region "${AWS_REGION}" --owners self \
        --filters "Name=name,Values=$1" \
        --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text 2>/dev/null | sed 's/^None$//'
}

aws_keypair_exists() {
    aws_quiet ec2 describe-key-pairs --region "${AWS_REGION}" --key-names "$1"
}

# --- Lookups / capability checks --------------------------------------------
aws_instance_supports_nested_virt() {
    # Nested virtualization is what allows Proxmox to run KVM guests.
    local features
    features="$(aws_cli ec2 describe-instance-types --region "${AWS_REGION}" \
        --instance-types "$1" \
        --query "InstanceTypes[0].ProcessorInfo.SupportedFeatures" --output json 2>/dev/null || echo '[]')"
    printf '%s' "${features}" | jq -e 'index("nested-virtualization") != null' >/dev/null 2>&1
}

aws_debian_ami() {
    # Latest official Debian cloud image for the configured major version.
    local pattern="debian-13-amd64-*"
    aws_cli ec2 describe-images --region "${AWS_REGION}" \
        --owners "${DEBIAN_OWNER_ID}" \
        --filters "Name=name,Values=${pattern}" \
                  "Name=architecture,Values=x86_64" \
                  "Name=state,Values=available" \
                  "Name=virtualization-type,Values=hvm" \
        --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text 2>/dev/null | sed 's/^None$//'
}

# --- VPC ---------------------------------------------------------------------
aws_vpc_create() {
    local vpc_id
    vpc_id="$(aws_cli ec2 create-vpc --region "${AWS_REGION}" \
        --cidr-block "${VPC_CIDR}" \
        --query "Vpc.VpcId" --output text)"

    # DNS support and DNS hostnames are separate VPC attributes - create-vpc
    # does not accept them, and modify-vpc-attribute only accepts one
    # attribute type per call.
    aws_cli ec2 modify-vpc-attribute --region "${AWS_REGION}" --vpc-id "${vpc_id}" \
        --enable-dns-support >/dev/null
    aws_cli ec2 modify-vpc-attribute --region "${AWS_REGION}" --vpc-id "${vpc_id}" \
        --enable-dns-hostnames >/dev/null

    aws_tag_lab "${vpc_id}" "vpc" "vpc"
    log_debug "Created VPC ${vpc_id} (${VPC_CIDR})"
    printf '%s' "${vpc_id}"
}

aws_subnet_create() {
    # aws_subnet_create <cidr> <az>
    local subnet_id
    subnet_id="$(aws_cli ec2 create-subnet --region "${AWS_REGION}" \
        --vpc-id "$(aws_vpc_id)" --cidr-block "$1" --availability-zone "$2" \
        --query "Subnet.SubnetId" --output text)"
    aws_tag_lab "${subnet_id}" "subnet-$3" "subnet"
    log_debug "Created subnet ${subnet_id} ($1 in $2)"
    printf '%s' "${subnet_id}"
}

aws_igw_create() {
    local vpc_id igw_id
    vpc_id="$(aws_vpc_id)"
    igw_id="$(aws_cli ec2 create-internet-gateway --region "${AWS_REGION}" \
        --query "InternetGateway.InternetGatewayId" --output text)"
    aws_cli ec2 attach-internet-gateway --region "${AWS_REGION}" \
        --internet-gateway-id "${igw_id}" --vpc-id "${vpc_id}" >/dev/null
    aws_tag_lab "${igw_id}" "igw" "igw"
    printf '%s' "${igw_id}"
}

# --- IPv6 -------------------------------------------------------------------
#
# IPv6 is what makes the lab reachable from a CGNAT network. The operator's
# IPv4 address is very often a carrier translation, and EC2 instance public
# IPv4 addresses are unreachable from such a network. A native IPv6 address
# is not translated, so it is the address the operator uses.

aws_vpc_ipv6_cidr() {
    # The first Amazon-provided IPv6 CIDR of the VPC.
    aws_cli ec2 describe-vpcs --region "${AWS_REGION}" \
        --filters "Name=cidr,Values=${VPC_CIDR}" \
        --query "Vpcs[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State==\`associated\`].Ipv6CidrBlock | [0]" \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_vpc_ipv6_associate() {
    # Associate an Amazon-provided IPv6 /56 with the VPC.
    #
    # The flag is a boolean switch - it takes no value. Passing a CIDR at
    # the same time is rejected with InvalidParameterCombination.
    aws_cli ec2 associate-vpc-cidr-block --region "${AWS_REGION}" \
        --vpc-id "$(aws_vpc_id)" \
        --amazon-provided-ipv6-cidr-block >/dev/null
}

aws_vpc_ipv6_state() {
    aws_cli ec2 describe-vpcs --region "${AWS_REGION}" \
        --filters "Name=cidr,Values=${VPC_CIDR}" \
        --query "Vpcs[0].Ipv6CidrBlockAssociationSet[].Ipv6CidrBlockState.State" \
        --output text 2>/dev/null | tr ' \t' '\n' | grep -v '^$' | head -1
}

aws_vpc_ipv6_wait() {
    # Wait until the VPC IPv6 association is usable.
    local i state
    for i in $(seq 1 30); do
        state="$(aws_vpc_ipv6_state)"
        if [ "${state}" = "associated" ]; then
            return 0
        fi
        sleep 10
    done
    return 1
}

aws_subnet_ipv6_associate() {
    # aws_subnet_ipv6_associate <subnet-id> <ipv6-cidr>
    #
    # The subnet CIDR must be a /64 carved out of a /56 that is associated
    # with the VPC. A /64 outside the VPC's own blocks is rejected.
    aws_cli ec2 associate-subnet-cidr-block --region "${AWS_REGION}" \
        --subnet-id "$1" --ipv6-cidr-block "$2" >/dev/null
}

aws_subnet_ipv6_cidr() {
    # aws_subnet_ipv6_cidr <subnet-id>
    aws_cli ec2 describe-subnets --region "${AWS_REGION}" --subnet-ids "$1" \
        --query 'Subnets[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State==`associated`].Ipv6CidrBlock | [0]' \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_subnet_ipv6_enable_auto() {
    aws_cli ec2 modify-subnet-attribute --region "${AWS_REGION}" \
        --subnet-id "$1" --assign-ipv6-address-on-creation >/dev/null
}

aws_eigw_id() {
    aws_cli ec2 describe-egress-only-internet-gateways --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=$(aws_vpc_id)" \
        --query "EgressOnlyInternetGateways[0].EgressOnlyInternetGatewayId" \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_eigw_create() {
    # An egress-only internet gateway routes IPv6 traffic out of a subnet
    # that has no public IPv4 address. A NAT gateway cannot be the next hop
    # for an IPv6 destination.
    local eigw_id
    eigw_id="$(aws_cli ec2 create-egress-only-internet-gateway --region "${AWS_REGION}" \
        --vpc-id "$(aws_vpc_id)" \
        --query "EgressOnlyInternetGateway.EgressOnlyInternetGatewayId" --output text)"
    aws_tag_lab "${eigw_id}" "eigw" "igw"
    printf '%s' "${eigw_id}"
}

aws_route_ipv6() {
    # aws_route_ipv6 <route-table-id> <ipv6-cidr> <gateway-type> <gateway-id>
    local rtb="$1" cidr="$2" gwtype="$3" gwid="$4" perms
    case "${gwtype}" in
        internet-gateway) perms="--gateway-id ${gwid}" ;;
        egress-only-internet-gateway) perms="--egress-only-internet-gateway-id ${gwid}" ;;
        *) return 1 ;;
    esac
    aws_cli ec2 create-route --region "${AWS_REGION}" \
        --route-table-id "${rtb}" --destination-ipv6-cidr-block "${cidr}" \
        ${perms} >/dev/null
}

aws_instance_ipv6() {
    # The first IPv6 address assigned to the instance's primary interface.
    # The address comes from the subnet, so it is globally routable.
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_eni_ipv6() {
    aws_cli ec2 describe-network-interfaces --region "${AWS_REGION}" --network-interface-ids "$1" \
        --query 'NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' --output text 2>/dev/null | sed 's/^None$//'
}

# The IPv6 default gateway of a subnet. It is the link-local address of the
# router, which AWS puts at the first address of the /64.
aws_ipv6_gateway() {
    printf 'fe80::1'
}

aws_natgw_create() {
    # NAT gateway in the public subnet, for the private subnets and for the
    # guest overlay traffic that is masqueraded out of the Proxmox nodes.
    local public_subnet eip nat_id
    public_subnet="$(aws_subnet_id "${SUBNET_PUBLIC_CIDR}")"
    eip="$(aws_cli ec2 allocate-address --region "${AWS_REGION}" \
        --domain "vpc" --query "AllocationId" --output text)"

    # Tag the address so that destroy.sh can find and release it.
    aws_cli ec2 create-tags --region "${AWS_REGION}" --resources "${eip}" \
        --tags "Key=Name,Value=${LAB_TAG}-natgw-eip" \
               "Key=LabTag,Value=${LAB_TAG}" \
               "Key=LabRole,Value=eip" >/dev/null 2>&1 || true

    nat_id="$(aws_cli ec2 create-nat-gateway --region "${AWS_REGION}" \
        --subnet-id "${public_subnet}" --allocation-id "${eip}" \
        --query "NatGateway.NatGatewayId" --output text)"
    aws_tag_lab "${nat_id}" "natgw" "natgw"

    log_info "Waiting for the NAT gateway to become available..."
    aws_cli ec2 wait nat-gateway-available --region "${AWS_REGION}" \
        --nat-gateway-ids "${nat_id}"
    printf '%s' "${nat_id}"
}

aws_default_route_table_id() {
    aws_cli ec2 describe-route-tables --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=$(aws_vpc_id)" \
        --query "RouteTables[?Associations[?Main==\`true\`]].RouteTableId | [0]" \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_create_route_table() {
    # aws_create_route_table <name> -> route table id
    local rtb
    rtb="$(aws_cli ec2 create-route-table --region "${AWS_REGION}" --vpc-id "$(aws_vpc_id)" \
        --query "RouteTable.RouteTableId" --output text)"
    aws_tag_lab "${rtb}" "rtb-$1" "rtb"
    printf '%s' "${rtb}"
}

aws_route_to() {
    # aws_route_to <route-table-id> <cidr> <gateway-id> <gateway-type>
    #
    # create-route has no --gateway-type option: the gateway type is derived
    # from the option that is used.
    local rtb="$1" cidr="$2" gw="$3" gwtype="$4"
    case "${gwtype}" in
        nat-gateway)
            aws_cli ec2 create-route --region "${AWS_REGION}" \
                --route-table-id "${rtb}" --destination-cidr-block "${cidr}" \
                --nat-gateway-id "${gw}" >/dev/null
            ;;
        *)
            aws_cli ec2 create-route --region "${AWS_REGION}" \
                --route-table-id "${rtb}" --destination-cidr-block "${cidr}" \
                --gateway-id "${gw}" >/dev/null
            ;;
    esac
}

aws_route_delete() {
    # aws_route_delete <route-table-id> <cidr>
    #
    # A route table can only have one default route, so a route has to be
    # deleted before another one is created for the same destination.
    aws_cli ec2 delete-route --region "${AWS_REGION}" \
        --route-table-id "$1" --destination-cidr-block "$2" >/dev/null 2>&1 || true
}

aws_associate_route_table() {
    # aws_associate_route_table <subnet-id> <route-table-id>
    aws_cli ec2 associate-route-table --region "${AWS_REGION}" \
        --subnet-id "$1" --route-table-id "$2" >/dev/null
}

# --- Security groups ---------------------------------------------------------
aws_sg_create() {
    # aws_sg_create <name> <description>
    local sg_id
    sg_id="$(aws_cli ec2 create-security-group --region "${AWS_REGION}" \
        --group-name "$1" --description "$2" --vpc-id "$(aws_vpc_id)" \
        --query "GroupId" --output text)"
    aws_tag_lab "${sg_id}" "$1" "sg"
    printf '%s' "${sg_id}"
}

# aws_sg_revoke <sg-id> <protocol> <port> <cidr>
#
# The counterpart of aws_sg_allow. A rule that does not exist is not an
# error.
aws_sg_revoke() {
    local sg="$1" proto="$2" port="$3" cidr="$4"
    local perms key

    case "${cidr}" in
        *:*) key="Ipv6Ranges=[{CidrIpv6=\"${cidr}\"}]" ;;
        *)   key="IpRanges=[{CidrIp=\"${cidr}\"}]" ;;
    esac

    if [ "${proto}" = "-1" ]; then
        perms="IpProtocol=-1,${key}"
    elif [ -z "${port}" ]; then
        perms="IpProtocol=${proto},${key}"
    elif printf '%s' "${port}" | grep -q '^[0-9]\+-[0-9]\+$'; then
        perms="IpProtocol=${proto},FromPort=${port%%-*},ToPort=${port##*-},${key}"
    else
        perms="IpProtocol=${proto},FromPort=${port},ToPort=${port},${key}"
    fi

    aws_cli ec2 revoke-security-group-ingress --region "${AWS_REGION}" \
        --group-id "${sg}" --ip-permissions "${perms}" >/dev/null 2>&1 || true
}

# aws_sg_revoke_operator <sg-id>
#
# Remove every single-host IPv4 rule from a security group.
#
# The operator's public IPv4 address changes: a network with a NAT gives a
# new address every time the connection is re-established, and a mobile
# network changes it while the lab is running. A rule that was written
# during the first provisioning run is therefore useless a few minutes
# later, and the operator loses the access to the web UI and to SSH.
#
# Only rules with a /32 prefix are removed. The rules for the VPC range
# and the rules for IPv6 are left alone.
aws_sg_revoke_operator() {
    local sg="$1" cidr
    local cidr_list

    cidr_list="$(aws_cli ec2 describe-security-groups --region "${AWS_REGION}" \
        --group-ids "${sg}" \
        --query "SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp" \
        --output text 2>/dev/null || true)"

    for cidr in ${cidr_list}; do
        case "${cidr}" in
            */32) aws_sg_revoke "${sg}" tcp 22 "${cidr}" ;;
        esac
    done
}

aws_sg_allow() {
    # aws_sg_allow <sg-id> <protocol> <port> <cidr> [description]
    # <port> may be a single port ("22") or a range ("5900-5999") or empty.
    #
    # An IPv6 CIDR has to go into Ipv6Ranges - the API rejects it in
    # IpRanges, and vice versa.
    local proto="$2" port="$3" cidr="$4" desc="${5:-lab rule}"
    local perms key

    case "${cidr}" in
        *:*) key="Ipv6Ranges=[{CidrIpv6=\"${cidr}\"}]" ;;
        *)   key="IpRanges=[{CidrIp=\"${cidr}\"}]" ;;
    esac

    # The shorthand syntax expects the address inside IpRanges - a bare
    # CidrIp key is rejected by the API.
    if [ "${proto}" = "-1" ]; then
        perms="IpProtocol=-1,${key}"
    elif [ -z "${port}" ]; then
        perms="IpProtocol=${proto},${key}"
    elif printf '%s' "${port}" | grep -q '^[0-9]\+-[0-9]\+$'; then
        local from to
        from="${port%%-*}"
        to="${port##*-}"
        perms="IpProtocol=${proto},FromPort=${from},ToPort=${to},${key}"
    else
        perms="IpProtocol=${proto},FromPort=${port},ToPort=${port},${key}"
    fi

    # Adding a rule that already exists is not an error for us - the rules
    # are re-applied on every run so that a partially configured security
    # group gets completed.
    local output
    if ! output="$(aws_cli ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
        --group-id "$1" --ip-permissions "${perms}" \
        --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=Description,Value=${desc}}]" 2>&1)"; then
        case "${output}" in
            *InvalidPermission.Duplicate*|*"already exists"*) return 0 ;;
            *) printf '%s\n' "${output}" >&2; return 1 ;;
        esac
    fi
}

aws_sg_allow_sg() {
    # aws_sg_allow_sg <sg-id> <source-sg-id> <protocol> <port> [description]
    local proto="$3" port="$4" desc="${5:-lab rule}"
    local perms
    if [ -n "${port}" ]; then
        perms="IpProtocol=${proto},FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=\"$2\"}]"
    else
        perms="IpProtocol=${proto},UserIdGroupPairs=[{GroupId=\"$2\"}]"
    fi
    aws_cli ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
        --group-id "$1" --ip-permissions "${perms}" \
        --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=Description,Value=${desc}}]" >/dev/null
}

# --- Key pair ----------------------------------------------------------------
aws_keypair_create() {
    # Creates a key pair and writes the private key to PVE_SSH_KEY_PATH.
    local key_path="${PVE_SSH_KEY_PATH}"
    mkdir -p "$(dirname "${key_path}")"
    aws_cli ec2 create-key-pair --region "${AWS_REGION}" \
        --key-name "${PVE_KEYPAIR_NAME}" \
        --query 'KeyMaterial' --output text > "${key_path}"
    chmod 600 "${key_path}"
    aws_tag "$(aws_cli ec2 describe-key-pairs --region "${AWS_REGION}" --key-names "${PVE_KEYPAIR_NAME}" --query 'KeyPairs[0].KeyPairId' --output text)" \
        "Name" "${LAB_TAG}-keypair" >/dev/null 2>&1 || true
    log_debug "Created key pair ${PVE_KEYPAIR_NAME} -> ${key_path}"
}

# --- EBS volumes -------------------------------------------------------------
aws_volume_create() {
    # aws_volume_create <size-gib> <az> <name>
    local vol_id
    vol_id="$(aws_cli ec2 create-volume --region "${AWS_REGION}" \
        --availability-zone "$2" --size "$1" --volume-type gp3 \
        --encrypted --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${LAB_TAG}-$3},{Key=LabTag,Value=${LAB_TAG}}]" \
        --query "VolumeId" --output text)"
    aws_cli ec2 wait volume-available --region "${AWS_REGION}" --volume-ids "${vol_id}"
    printf '%s' "${vol_id}"
}

# --- Instances ---------------------------------------------------------------

aws_ssm_instance_profile_name() {
    printf '%s-ssm' "${LAB_TAG}"
}

aws_ssm_role_exists() {
    aws_cli iam get-role --role-name "$(aws_ssm_instance_profile_name)" \
        >/dev/null 2>&1
}

aws_ssm_instance_profile_exists() {
    aws_cli iam get-instance-profile --region "${AWS_REGION}" \
        --instance-profile-name "$(aws_ssm_instance_profile_name)" \
        >/dev/null 2>&1
}

# The IAM role and instance profile that let the SSM agent register with
# Systems Manager.
#
# The agent needs exactly two permissions:
#   * ssm:UpdateInstanceInformation      - register the instance
#   * ssmmessages:CreateControlChannel    - the session data channel
#     ssmmessages:CreateDataChannel
#     ssmmessages:OpenControlChannel
#     ssmmessages:OpenDataChannel
#   * ssm:DescribeInstanceProperties     - required by the session plugin
#
# The AWS managed policy AmazonSSMManagedInstanceCore contains exactly this
# set, so it is used instead of a hand-written policy.
aws_ssm_instance_profile_create() {
    local role_name profile_name
    role_name="$(aws_ssm_instance_profile_name)"
    profile_name="${role_name}"

    if ! aws_ssm_role_exists; then
        aws_cli iam create-role --region "${AWS_REGION}" \
            --role-name "${role_name}" \
            --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
            >/dev/null
        aws_cli iam attach-role-policy --region "${AWS_REGION}" \
            --role-name "${role_name}" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null
        log_debug "Created IAM role ${role_name}"
    fi

    if ! aws_ssm_instance_profile_exists; then
        aws_cli iam create-instance-profile --region "${AWS_REGION}" \
            --instance-profile-name "${profile_name}" >/dev/null
        aws_cli iam add-role-to-instance-profile --region "${AWS_REGION}" \
            --instance-profile-name "${profile_name}" \
            --role-name "${role_name}" >/dev/null
        log_debug "Created instance profile ${profile_name}"
    fi

    printf '%s' "${profile_name}"
}

aws_ssm_instance_profile_arn() {
    aws_cli iam get-instance-profile --region "${AWS_REGION}" \
        --instance-profile-name "$(aws_ssm_instance_profile_name)" \
        --query 'InstanceProfile.Arn' --output text 2>/dev/null | sed 's/^None$//'
}

aws_instance_launch() {
    # aws_instance_launch <name> <role> <instance-type> <ami-id> <az>
    #
    # A single interface in the public subnet. The guest overlay is a purely
    # internal layer 2 segment on the node (see docs/ARCHITECTURE.md), so the
    # nodes need no second ENI.
    local name="$1" role="$2" itype="$3" ami="$4" az="$5"

    local netif
    netif="$(jq -n \
        --arg subnet_pub "$(aws_subnet_id "${SUBNET_PUBLIC_CIDR}")" \
        --arg sg "$(aws_sg_id "pve-lab")" \
        '[{DeviceIndex:0,SubnetId:$subnet_pub,AssociatePublicIpAddress:true,Groups:[$sg],DeleteOnTermination:true,Ipv6AddressCount:1}]')"

    local bdm
    bdm="$(jq -n --arg size "${PVE_DATA_VOLUME_SIZE}" \
        '[{DeviceName:"/dev/sdf",Ebs:{VolumeSize:($size|tonumber),VolumeType:"gp3",DeleteOnTermination:false,Encrypted:true}}]')"

    # The instance profile gives the SSM agent the credentials it needs to
    # register. Without it the instance can only be reached over SSH, which
    # does not work from a CGNAT network.
    #
    # The profile is given by name and not by ARN: the AWS CLI parses the
    # colons of an ARN as the shorthand syntax and rejects the value.
    local profile_name
    profile_name="$(aws_ssm_instance_profile_name)"
    local args=(ec2 run-instances --region "${AWS_REGION}"
        --image-id "${ami}"
        --instance-type "${itype}"
        --cpu-options "NestedVirtualization=enabled"
        --key-name "${PVE_KEYPAIR_NAME}"
        --placement "{\"AvailabilityZone\":\"${az}\"}"
        --network-interfaces "${netif}"
        --block-device-mappings "${bdm}")
    args+=(--iam-instance-profile "Name=${profile_name}")
    [ -f "${LAB_ROOT_DIR}/packer/scripts/ssm-userdata.sh" ] && \
        args+=(--user-data "file://${LAB_ROOT_DIR}/packer/scripts/ssm-userdata.sh")
    args+=(--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${LAB_TAG}-${role}-${name}},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=${role}}]"
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${LAB_TAG}-${role}-${name}-data},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=${role}}]"
        --query "Instances[0].InstanceId" --output text)

    aws_cli "${args[@]}"
}

aws_instance_launch_service() {
    # aws_instance_launch_service <name> <role> <instance-type> <ami-id> <az> <size>
    #   Single ENI in the services subnet, with a public IP so the operator can
    #   reach it directly (SSH is restricted to the operator's own IP).
    local name="$1" role="$2" itype="$3" ami="$4" az="$5" size="$6"

    local netif
    netif="$(jq -n \
        --arg subnet "$(aws_subnet_id "${SUBNET_SERVICES_CIDR}")" \
        --arg sg "$(aws_sg_id "services-lab")" \
        '[{DeviceIndex:0,SubnetId:$subnet,AssociatePublicIpAddress:true,Groups:[$sg],DeleteOnTermination:true,Ipv6AddressCount:1}]')"

    local bdm
    bdm="$(jq -n --arg size "${size}" \
        '[{DeviceName:"/dev/sdf",Ebs:{VolumeSize:($size|tonumber),VolumeType:"gp3",DeleteOnTermination:false,Encrypted:true}}]')"

    # The instance profile gives the SSM agent the credentials it needs to
    # register - the only way in from a CGNAT network. The profile is given
    # by name, because the AWS CLI cannot parse a bare ARN as a value.
    local profile_name
    profile_name="$(aws_ssm_instance_profile_name)"

    local args=(ec2 run-instances --region "${AWS_REGION}"
        --image-id "${ami}" --instance-type "${itype}"
        --key-name "${PVE_KEYPAIR_NAME}"
        --placement "{\"AvailabilityZone\":\"${az}\"}"
        --network-interfaces "${netif}" --block-device-mappings "${bdm}")
    args+=(--iam-instance-profile "Name=${profile_name}")
    [ -f "${LAB_ROOT_DIR}/packer/scripts/ssm-userdata.sh" ] && \
        args+=(--user-data "file://${LAB_ROOT_DIR}/packer/scripts/ssm-userdata.sh")
    args+=(--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${LAB_TAG}-${role}-${name}},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=${role}}]"
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${LAB_TAG}-${role}-${name}-data},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=${role}}]"
        --query "Instances[0].InstanceId" --output text)

    aws_cli "${args[@]}"
}

aws_wait_instance_running() {
    aws_cli ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "$1"
}

aws_wait_instance_stopped() {
    aws_cli ec2 wait instance-stopped --region "${AWS_REGION}" --instance-ids "$1"
}

aws_wait_instance_terminated() {
    aws_cli ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids "$1"
}

aws_instance_private_ip() {
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null | sed 's/^None$//'
}

aws_instance_public_ip() {
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null | sed 's/^None$//'
}

# The address the harness uses to reach a node.
#
# The operator's own IPv4 address is usually a CGNAT translation (a /32 on a
# 464XLAT network, or a shared address behind a carrier NAT), and EC2
# instance public IPs are unreachable from such a network. A native IPv6
# path is not translated, so the nodes are addressed over IPv6 whenever the
# instance has one.
aws_instance_reach_ip() {
    local v6
    v6="$(aws_instance_ipv6 "$1")"
    if [ -n "${v6}" ]; then
        printf '%s' "${v6}"
        return 0
    fi
    aws_instance_public_ip "$1"
}

aws_instance_eni() {
    # aws_instance_eni <instance-id> <device-index> -> eni-id
    #
    # The network interfaces live under Reservations[].Instances[]. The query
    # has to walk through the instance, not through the reservation.
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query "Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==\`$2\`].NetworkInterfaceId | [0]" \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_eni_private_ip() {
    aws_cli ec2 describe-network-interfaces --region "${AWS_REGION}" --network-interface-ids "$1" \
        --query 'NetworkInterfaces[0].PrivateIpAddress' --output text 2>/dev/null | sed 's/^None$//'
}

aws_eni_mac() {
    aws_cli ec2 describe-network-interfaces --region "${AWS_REGION}" --network-interface-ids "$1" \
        --query 'NetworkInterfaces[0].MacAddress' --output text 2>/dev/null | sed 's/^None$//'
}

aws_eni_subnet() {
    aws_cli ec2 describe-network-interfaces --region "${AWS_REGION}" --network-interface-ids "$1" \
        --query 'NetworkInterfaces[0].SubnetId' --output text 2>/dev/null | sed 's/^None$//'
}

aws_instance_root_volume() {
    # The root device name comes from the AMI. The Debian cloud image uses
    # /dev/xvda, but it is read from the instance so that the lookup works
    # with any base image.
    local device
    device="$(aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].RootDeviceName' --output text 2>/dev/null | sed 's/^None$//')"
    [ -n "${device}" ] || device="/dev/xvda"
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==\`${device}\`].Ebs.VolumeId | [0]" \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_instance_volume_for_device() {
    # aws_instance_volume_for_device <instance-id> <device-name>
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==\`$2\`].Ebs.VolumeId | [0]" \
        --output text 2>/dev/null | sed 's/^None$//'
}

# --- Deletion ----------------------------------------------------------------
aws_terminate_instance() {
    aws_cli ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "$1" >/dev/null 2>&1 || true
}

aws_stop_instance() {
    aws_cli ec2 stop-instances --region "${AWS_REGION}" --instance-ids "$1" >/dev/null 2>&1 || true
}

aws_delete_volume() {
    aws_cli ec2 delete-volume --region "${AWS_REGION}" --volume-id "$1" >/dev/null 2>&1 || true
}

aws_delete_eni() {
    aws_cli ec2 delete-network-interface --region "${AWS_REGION}" --network-interface-id "$1" >/dev/null 2>&1 || true
}

aws_detach_eni() {
    aws_cli ec2 detach-network-interface --region "${AWS_REGION}" \
        --attachment-id "$(aws_cli ec2 describe-network-interfaces --region "${AWS_REGION}" --network-interface-ids "$1" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)" \
        --force >/dev/null 2>&1 || true
}

aws_delete_sg() {
    aws_cli ec2 delete-security-group --region "${AWS_REGION}" --group-id "$1" >/dev/null 2>&1 || true
}

aws_delete_subnet() {
    aws_cli ec2 delete-subnet --region "${AWS_REGION}" --subnet-id "$1" >/dev/null 2>&1 || true
}

aws_delete_natgw() {
    aws_cli ec2 delete-nat-gateway --region "${AWS_REGION}" --nat-gateway-id "$1" >/dev/null 2>&1 || true
}

aws_release_eip() {
    aws_cli ec2 release-address --region "${AWS_REGION}" --allocation-id "$1" >/dev/null 2>&1 || true
}

aws_delete_igw() {
    aws_cli ec2 detach-internet-gateway --region "${AWS_REGION}" \
        --internet-gateway-id "$1" --vpc-id "$(aws_vpc_id)" >/dev/null 2>&1 || true
    aws_cli ec2 delete-internet-gateway --region "${AWS_REGION}" \
        --internet-gateway-id "$1" >/dev/null 2>&1 || true
}

aws_delete_vpc() {
    aws_cli ec2 delete-vpc --region "${AWS_REGION}" --vpc-id "$1" >/dev/null 2>&1 || true
}

aws_delete_keypair() {
    aws_cli ec2 delete-key-pair --region "${AWS_REGION}" --key-name "$1" >/dev/null 2>&1 || true
}

aws_deregister_ami() {
    aws_cli ec2 deregister-image --region "${AWS_REGION}" --image-id "$1" >/dev/null 2>&1 || true
}

aws_delete_snapshots_of_ami() {
    local ami="$1"
    local snaps
    snaps="$(aws_cli ec2 describe-snapshots --region "${AWS_REGION}" --owner-ids self \
        --filters "Name=image-id,Values=${ami}" \
        --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' '\n')"
    local snap
    for snap in ${snaps}; do
        [ -n "${snap}" ] && aws_cli ec2 delete-snapshot --region "${AWS_REGION}" --snapshot-id "${snap}" >/dev/null 2>&1 || true
    done
}

# List every resource created by this harness (by tag).
aws_lab_instances() {
    aws_cli ec2 describe-instances --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_volumes() {
    aws_cli ec2 describe-volumes --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_enis() {
    aws_cli ec2 describe-network-interfaces --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_sgs() {
    aws_cli ec2 describe-security-groups --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_subnets() {
    aws_cli ec2 describe-subnets --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Subnets[].SubnetId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_route_tables() {
    aws_cli ec2 describe-route-tables --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'RouteTables[].RouteTableId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_natgws() {
    aws_cli ec2 describe-nat-gateways --region "${AWS_REGION}" \
        --filter "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_igws() {
    aws_cli ec2 describe-internet-gateways --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_vpcs() {
    aws_cli ec2 describe-vpcs --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_amis() {
    aws_cli ec2 describe-images --region "${AWS_REGION}" --owners self \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Images[].ImageId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_snapshots() {
    aws_cli ec2 describe-snapshots --region "${AWS_REGION}" --owner-ids self \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_eips() {
    aws_cli ec2 describe-addresses --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Addresses[].AllocationId' --output text 2>/dev/null | tr '\t' '\n' || true
}

aws_lab_keypairs() {
    aws_cli ec2 describe-key-pairs --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'KeyPairs[].KeyName' --output text 2>/dev/null | tr '\t' '\n' || true
}
