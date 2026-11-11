#!/bin/bash
# =============================================================================
# build-ami.sh - build a Proxmox VE AMI without Packer
# =============================================================================
#
# Packer aborts a provisioner when the SSH connection to the build instance
# drops, and the link to AWS from a hotel or a campus network drops
# regularly. The build therefore does not use Packer.
#
# Instead:
#
#   1. A build instance is launched from the Debian cloud image.
#   2. The build script is uploaded once, over a single SSH session.
#   3. The script installs everything and runs detached on the instance, so
#      that a dropped connection cannot affect it.
#   4. The script writes its result to a marker file.
#   5. The build polls for that marker with fresh SSH sessions.
#   6. The instance is stopped and an AMI is created from its snapshot.
#
# The script can also be driven by AWS Systems Manager, which needs no
# inbound connectivity at all.
#
# Usage:
#   ./packer/build-ami.sh pve
#   ./packer/build-ami.sh pbs
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

KIND="${1:-pve}"

# shellcheck source=lib/common.sh
. "${ROOT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
. "${ROOT_DIR}/lib/config.sh"
# shellcheck source=lib/state.sh
. "${ROOT_DIR}/lib/state.sh"
# shellcheck source=lib/aws.sh
. "${ROOT_DIR}/lib/aws.sh"

load_config
aws_export_login_credentials >/dev/null 2>&1

# The name comes from the configuration, so that the harness and the builder
# always agree on it.
AMI_NAME="${PVE_AMI_NAME:-pve-lab-amd64-v3}"
if [ "${KIND}" = "pbs" ]; then
    AMI_NAME="${PBS_AMI_NAME:-pbs-lab-amd64-v3}"
elif [ "${KIND}" = "nfs" ]; then
    AMI_NAME="${NFS_AMI_NAME:-nfs-lab-amd64-v3}"
fi

# The name has to be unique. If an image with this name exists already, the
# create-image call fails and the build would report success without
# producing an image.
existing_ami="$(aws_cli ec2 describe-images --region "${AWS_REGION}" --owners self \
    --filters "Name=name,Values=${AMI_NAME}" \
    --query 'Images[0].ImageId' --output text 2>/dev/null || true)"
if [ -n "${existing_ami}" ] && [ "${existing_ami}" != "None" ]; then
    AMI_NAME="${AMI_NAME}-$(date -u +%Y%m%d-%H%M%S)"
    echo "The name ${AMI_NAME} was taken - the image is called ${AMI_NAME} now."
fi

MARKER="/var/log/lab-ami-build.rc"
LOG="/var/log/lab-ami-build.log"

# ---------------------------------------------------------------------------
# 1. The build instance
# ---------------------------------------------------------------------------
echo "=== Preparing the build instance ==="

BASE_AMI="$(aws_cli ec2 describe-images --region "${AWS_REGION}" --owners amazon \
    --filters "Name=name,Values=debian-13-amd64-*" "Name=architecture,Values=x86_64" \
              "Name=state,Values=available" \
    --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text)"
echo "Base image: ${BASE_AMI}"

SUBNET_ID="$(state_get '.subnets.public.id')"
[ -n "${SUBNET_ID}" ] || die "No public subnet in the state file - run the foundation phase first."

# The instance runs in the lab VPC so that it is covered by the same tags
# and gets a public address from the public subnet.
BUILD_INSTANCE="$(aws_cli ec2 run-instances --region "${AWS_REGION}" \
    --image-id "${BASE_AMI}" \
    --instance-type "${BUILD_INSTANCE_TYPE:-m7i.2xlarge}" \
    --key-name "${PVE_KEYPAIR_NAME}" \
    --network-interfaces "DeviceIndex=0,SubnetId=${SUBNET_ID},AssociatePublicIpAddress=true,Groups=[$(aws_sg_id pve-lab)],DeleteOnTermination=true" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":48,"VolumeType":"gp3","DeleteOnTermination":true,"Encrypted":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=lab-ami-build-${KIND}},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=ami-build}]" \
    --query 'Instances[0].InstanceId' --output text)"

[ -n "${BUILD_INSTANCE}" ] || die "Could not launch the build instance"
echo "Build instance: ${BUILD_INSTANCE}"

aws_cli ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${BUILD_INSTANCE}"
BUILD_IP="$(aws_instance_public_ip "${BUILD_INSTANCE}")"
echo "Build instance address: ${BUILD_IP}"

# ---------------------------------------------------------------------------
# 2. Wait for SSH
# ---------------------------------------------------------------------------
SSH_OPTS=(-i "${PVE_SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=20 -o BatchMode=yes -o ServerAliveInterval=30)

echo "Waiting for SSH on ${BUILD_IP}..."
for i in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" "true" 2>/dev/null; then
        echo "SSH is up."
        break
    fi
    sleep 10
done

if ! ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" "true" 2>/dev/null; then
    die "SSH to the build instance did not come up."
fi

# ---------------------------------------------------------------------------
# 3. Upload the build script and start it detached
# ---------------------------------------------------------------------------
echo "Uploading the build scripts..."

# The build directory holds the runner and the step scripts.
ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" "sudo mkdir -p /opt/lab-build && sudo chown admin /opt/lab-build"

scp "${SSH_OPTS[@]}" \
    "${SCRIPT_DIR}/scripts/build-runner.sh" \
    "${SCRIPT_DIR}/scripts/01-base.sh" \
    "${SCRIPT_DIR}/scripts/05-ssm-agent.sh" \
    "${SCRIPT_DIR}/scripts/10-proxmox-repo.sh" \
    "${SCRIPT_DIR}/scripts/20-proxmox-install.sh" \
    "${SCRIPT_DIR}/scripts/30-pve-finalize.sh" \
    "${SCRIPT_DIR}/scripts/40-pbs-install.sh" \
    "${SCRIPT_DIR}/scripts/45-nfs-install.sh" \
    "${SCRIPT_DIR}/scripts/lab-network.sh" \
    "${SCRIPT_DIR}/scripts/lab-firewall.sh" \
    "${SCRIPT_DIR}/scripts/lab-netcheck.sh" \
    "admin@${BUILD_IP}:/opt/lab-build/"

# Start it detached. The instance has to survive the reboot into the
# Proxmox kernel, so the runner does that itself.
ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" \
    "sudo mkdir -p /var/log && sudo rm -f '${MARKER}' '${LOG}' && sudo chmod +x /opt/lab-build/build-runner.sh && sudo sh -c \"nohup setsid /opt/lab-build/build-runner.sh '${KIND}' > '${LOG}' 2>&1 &\" && echo started"

echo ""
echo "The build runs on the instance. Polling for the result..."

# ---------------------------------------------------------------------------
# 4. Poll for the result
# ---------------------------------------------------------------------------
DEADLINE=$(( $(date +%s) + 5400 ))
LAST=""
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    rc="$(ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" \
        "sudo test -s '${MARKER}' && sudo cat '${MARKER}' || echo PENDING" 2>/dev/null)"
    rc="$(printf '%s' "${rc}" | tr -d '[:space:]')"

    if [ -z "${rc}" ] || [ "${rc}" = "PENDING" ]; then
        # Show the progress.
        out="$(ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" \
            "sudo tail -3 '${LOG}' 2>/dev/null || true" 2>/dev/null)"
        if [ "${out}" != "${LAST}" ] && [ -n "${out}" ]; then
            LAST="${out}"
            printf '%s\n' "${out}" | tr -d '\r'
        fi
        sleep 30
        continue
    fi

    echo "The build finished with exit status ${rc}"
    if [ "${rc}" != "0" ]; then
        echo "--- the last 60 lines of the build log ---"
        ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" "sudo tail -60 '${LOG}'" 2>/dev/null
        die "The AMI build failed."
    fi
    break
done

if [ "${rc:-PENDING}" = "PENDING" ]; then
    die "The AMI build did not finish in time."
fi

# ---------------------------------------------------------------------------
# 5. Verify and create the AMI
# ---------------------------------------------------------------------------
echo "Verifying the built image..."
ssh "${SSH_OPTS[@]}" "admin@${BUILD_IP}" \
    "uname -r; pveversion -v | head -3; systemctl is-active pveproxy pvedaemon pvestatd; echo '--- firewall ---'; systemctl is-enabled pve-firewall || true; echo '--- dns ---'; getent hosts s3.${AWS_REGION}.amazonaws.com >/dev/null && echo DNS-OK; echo '--- ssm ---'; systemctl is-enabled amazon-ssm-agent || systemctl is-enabled ssm-agent"

echo ""
echo "Stopping the build instance..."
aws_cli ec2 stop-instances --region "${AWS_REGION}" --instance-ids "${BUILD_INSTANCE}" >/dev/null
aws_cli ec2 wait instance-stopped --region "${AWS_REGION}" --instance-ids "${BUILD_INSTANCE}"

echo "Creating the AMI from the build instance..."
aws_cli ec2 create-image --region "${AWS_REGION}" \
    --instance-id "${BUILD_INSTANCE}" \
    --name "${AMI_NAME}" \
    --description "Proxmox VE seminar lab node (built by build-ami.sh)" \
    --no-reboot \
    --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=LabTag,Value=${LAB_TAG}},{Key=LabRole,Value=${KIND}-ami}]" \
    --query 'ImageId' --output text > /tmp/lab-ami-id.txt

AMI_ID="$(cat /tmp/lab-ami-id.txt)"
if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" = "None" ]; then
    die "The AMI could not be created."
fi

# The name is written to a file, so that the caller can read it back.
printf '%s' "${AMI_NAME}" > /tmp/lab-ami-name.txt

echo "AMI ${AMI_ID} (${AMI_NAME}) is being created."

# ---------------------------------------------------------------------------
# 6. Clean up
# ---------------------------------------------------------------------------
echo "Terminating the build instance..."
aws_cli ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "${BUILD_INSTANCE}" >/dev/null 2>&1 || true

echo ""
echo "=== The AMI is ready: ${AMI_ID} (${AMI_NAME}) ==="
echo "It becomes usable as soon as the image reaches the 'available' state."
