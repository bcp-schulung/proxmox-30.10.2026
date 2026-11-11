#!/bin/bash
# =============================================================================
# ssm-userdata.sh - cloud-init user-data that installs the SSM agent
# =============================================================================
#
# Used to bring an EXISTING instance under SSM management without SSH. A
# fresh instance runs cloud-init from scratch, so the user-data is executed
# on the first boot.
#
# Two things are needed:
#   * a working /etc/resolv.conf - the Proxmox packages break DNS
#   * the SSM agent itself
# =============================================================================
set -eux

export DEBIAN_FRONTEND=noninteractive

REGION="$(curl -s -m 5 http://169.254.169.254/latest/meta-data/placement/region || echo eu-central-1)"
echo "region: ${REGION}"

# The Proxmox packages replace the Debian networking stack with ifupdown2,
# and systemd-resolved then no longer has a usable stub resolver. The
# consequence is that /etc/resolv.conf ends up empty and no name resolves.
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    echo "Writing /etc/resolv.conf with the VPC resolver"
    rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
fi

# The package URL must use the REGIONAL S3 endpoint. The global endpoint
# answers with a 301 that does not resolve to the object.
URL="https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/debian_amd64/amazon-ssm-agent.deb"

if ! curl -fsSL -m 300 -o /tmp/ssm-agent.deb "${URL}"; then
    echo "WARN: could not download the SSM agent from ${URL}"
    exit 0
fi
ls -l /tmp/ssm-agent.deb

dpkg -i --force-confold /tmp/ssm-agent.deb || {
    apt-get -y -f install || true
    dpkg -i --force-confold /tmp/ssm-agent.deb || true
}
rm -f /tmp/ssm-agent.deb

mkdir -p /etc/ssm
printf '[agent]\nregion = %s\n' "${REGION}" > /etc/ssm/amazon-ssm-agent.conf
chmod 600 /etc/ssm/amazon-ssm-agent.conf

systemctl enable amazon-ssm-agent || systemctl enable ssm-agent || true
systemctl restart amazon-ssm-agent || systemctl restart ssm-agent || true

echo "ssm agent installed"
