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
    aws_cli ec2 describe-nat-gateways --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=$(aws_vpc_id)" \
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
        --enable-dns-hostnames --enable-dns-support \
        --query "Vpc.VpcId" --output text)"
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

aws_natgw_create() {
    # NAT gateway in the public subnet, for the private subnets and for the
    # guest overlay traffic that is masqueraded out of the Proxmox nodes.
    local public_subnet eip nat_id
    public_subnet="$(aws_subnet_id "${SUBNET_PUBLIC_CIDR}")"
    eip="$(aws_cli ec2 allocate-address --region "${AWS_REGION}" \
        --domain "vpc" --query "AllocationId" --output text)"
    nat_id="$(aws_cli ec2 create-nat-gateway --region "${AWS_REGION}" \
        --subnet-id "${public_subnet}" --allocation-id "${eip}" \
        --query "NatGateway.NatGatewayId" --output text)"
    aws_tag_lab "${nat_id}" "natgw" "natgw"

    log_info "Waiting for the NAT gateway to become available..."
    aws_cli ec2 wait nat-gateway-available --region "${AWS_REGION}" \
        --nat-gateway-ids "${nat_id}"
    printf '%s' "${nat_id}"
}

aws_route_create() {
    # aws_route_create <route-cidr> <gateway-id> <gateway-type>
    aws_cli ec2 create-route --region "${AWS_REGION}" \
        --route-table-id "$(aws_default_route_table_id)" \
        --destination-cidr-block "$1" --gateway-id "$2" \
        --gateway-type "$3" >/dev/null
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
    aws_cli ec2 create-route --region "${AWS_REGION}" \
        --route-table-id "$1" \
        --destination-cidr-block "$2" \
        --gateway-id "$3" \
        --gateway-type "$4" >/dev/null
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

aws_sg_allow() {
    # aws_sg_allow <sg-id> <protocol> <port> <cidr> [description]
    # <port> may be a single port ("22") or a range ("5900-5999") or empty.
    local proto="$2" port="$3" cidr="$4" desc="${5:-lab rule}"
    local perms

    if [ "${proto}" = "-1" ]; then
        perms="IpProtocol=-1,CidrIp=${cidr}"
    elif [ -z "${port}" ]; then
        perms="IpProtocol=${proto},CidrIp=${cidr}"
    elif printf '%s' "${port}" | grep -q '^[0-9]\+-[0-9]\+$'; then
        local from to
        from="${port%%-*}"
        to="${port##*-}"
        perms="IpProtocol=${proto},FromPort=${from},ToPort=${to},CidrIp=${cidr}"
    else
        perms="IpProtocol=${proto},FromPort=${port},ToPort=${port},CidrIp=${cidr}"
    fi

    aws_cli ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
        --group-id "$1" --ip-permissions "${perms}" \
        --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=Description,Value=${desc}}]" >/dev/null
}

aws_sg_allow_sg() {
    # aws_sg_allow_sg <sg-id> <source-sg-id> <protocol> <port> [description]
    local proto="$3" port="$4" desc="${5:-lab rule}"
    local perms
    if [ -n "${port}" ]; then
        perms="IpProtocol=${proto},FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=$2}]"
    else
        perms="IpProtocol=${proto},UserIdGroupPairs=[{GroupId=$2}]"
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
        '[{DeviceIndex:0,SubnetId:$subnet_pub,AssociatePublicIpAddress:true,Groups:[$sg],DeleteOnTermination:true}]')"

    local bdm
    bdm="$(jq -n --arg size "${PVE_DATA_VOLUME_SIZE}" \
        '[{DeviceName:"/dev/sdf",Ebs:{VolumeSize:($size|tonumber),VolumeType:"gp3",DeleteOnTermination:false,Encrypted:true}}]')"

    local args=(ec2 run-instances --region "${AWS_REGION}"
        --image-id "${ami}"
        --instance-type "${itype}"
        --cpu-options "NestedVirtualization=enabled"
        --key-name "${PVE_KEYPAIR_NAME}"
        --availability-zone "${az}"
        --network-interfaces "${netif}"
        --block-device-mappings "${bdm}"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${LAB_TAG}-${role}-${name}},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=${role}}]"
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
        '[{DeviceIndex:0,SubnetId:$subnet,AssociatePublicIpAddress:true,Groups:[$sg],DeleteOnTermination:true}]')"

    local bdm
    bdm="$(jq -n --arg size "${size}" \
        '[{DeviceName:"/dev/sdf",Ebs:{VolumeSize:($size|tonumber),VolumeType:"gp3",DeleteOnTermination:false,Encrypted:true}}]')"

    aws_cli ec2 run-instances --region "${AWS_REGION}" \
        --image-id "${ami}" --instance-type "${itype}" \
        --key-name "${PVE_KEYPAIR_NAME}" --availability-zone "${az}" \
        --network-interfaces "${netif}" --block-device-mappings "${bdm}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${LAB_TAG}-${role}-${name}},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=${role}}]" \
        --query "Instances[0].InstanceId" --output text
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

aws_instance_eni() {
    # aws_instance_eni <instance-id> <device-index> -> eni-id
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query "Reservations[0].NetworkInterfaces[?Attachment.DeviceIndex==\`$2\`].NetworkInterfaceId | [0]" \
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
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query 'Reservations[0].BlockDeviceMappings[?DeviceName==\`/dev/sda1\`].Ebs.VolumeId | [0]' \
        --output text 2>/dev/null | sed 's/^None$//'
}

aws_instance_volume_for_device() {
    # aws_instance_volume_for_device <instance-id> <device-name>
    aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "$1" \
        --query "Reservations[0].BlockDeviceMappings[?DeviceName==\`$2\`].Ebs.VolumeId | [0]" \
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
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n'
}

aws_lab_volumes() {
    aws_cli ec2 describe-volumes --region "${AWS_REGION}" \
        --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n'
}
