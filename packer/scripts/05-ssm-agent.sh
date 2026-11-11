#!/bin/bash
# =============================================================================
# 05-ssm-agent.sh - Packer build step: DNS fix and AWS Systems Manager agent
# =============================================================================
#
# The agent gives the instance an outbound-only connection to the Systems
# Manager control plane. That is the only connection method that works from
# a CGNAT network, where the EC2 public IPv4 address is unreachable and
# native IPv6 is often missing too.
#
# The agent is installed here so that it is part of the AMI. Installing it
# at boot would need a working SSH session first - which is exactly the
# thing that is broken on a CGNAT network. Baking it in avoids the
# chicken-and-egg problem entirely.
# =============================================================================
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# The apt calls are retried, because the link to the package mirrors
# occasionally drops and a plain apt invocation would abort the build.
apt_retry() {
    local attempt=1
    local max=5
    while [ "${attempt}" -le "${max}" ]; do
        echo "--- apt attempt ${attempt}/${max}: apt-get $* ---"
        if sudo apt-get -o Acquire::Retries=3 "$@"; then
            return 0
        fi
        echo "WARN: apt-get $* failed - retrying in 10 seconds"
        attempt=$((attempt + 1))
        sleep 10
    done
    echo "ERROR: apt-get $* failed after ${max} attempts"
    return 1
}

# The region is taken from the instance metadata. AWS_REGION is not
# necessarily exported into the Packer shell, and the script runs with
# 'set -u', so an unset variable would abort the build.
REGION="${AWS_REGION:-}"
if [ -z "${REGION}" ]; then
    REGION="$(curl -s -m 5 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)"
fi
if [ -z "${REGION}" ]; then
    REGION="eu-central-1"
fi
echo "region: ${REGION}"

# -----------------------------------------------------------------------------
# DNS
#
# The Proxmox packages replace the Debian networking stack with ifupdown2,
# and systemd-resolved then no longer has a usable stub resolver. The
# consequence is that /etc/resolv.conf ends up empty and no name resolves
# - which breaks the agent download below and every apt operation.
#
# The AWS VPC resolver (169.254.169.253) is the correct resolver: it
# resolves both the internal service names and the public S3 endpoints.
# The file is written directly rather than through resolvconf, because the
# ifupdown2 stack does not integrate with the Debian resolvconf hooks.
# -----------------------------------------------------------------------------
if [ ! -s /etc/resolv.conf ] || ! grep -q "169.254.169.253" /etc/resolv.conf 2>/dev/null; then
    echo "Writing /etc/resolv.conf with the VPC resolver"
    sudo rm -f /etc/resolv.conf
    printf 'nameserver 169.254.169.253\noptions timeout:2 attempts:3\n' \
        | sudo tee /etc/resolv.conf >/dev/null
    sudo chmod 644 /etc/resolv.conf
fi

if ! getent hosts "s3.${REGION}.amazonaws.com" >/dev/null 2>&1; then
    echo "WARN: DNS does not resolve yet - the agent download may fail"
fi

# -----------------------------------------------------------------------------
# The SSM agent
#
# The package is published per region under the regional endpoint. The
# global endpoint answers with a 301 that does not resolve to the object.
# -----------------------------------------------------------------------------
AGENT_URL="https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/debian_amd64/amazon-ssm-agent.deb"

echo "Installing the SSM agent from ${AGENT_URL}"
apt_retry update
apt_retry install -y curl ca-certificates

if ! sudo curl -fsSL --retry 3 --retry-delay 5 -m 300 -o /tmp/ssm-agent.deb "${AGENT_URL}"; then
    echo "WARN: could not fetch the SSM agent package - continuing without it"
else
    ls -l /tmp/ssm-agent.deb

    # The install script tries to register the service, which fails during a
    # Packer build because the instance has no instance profile yet. The
    # postinst is therefore tolerated and the service is enabled afterwards.
    sudo dpkg -i --force-confold /tmp/ssm-agent.deb || {
        sudo apt-get -y -f install || true
        sudo dpkg -i --force-confold /tmp/ssm-agent.deb || true
    }
    sudo rm -f /tmp/ssm-agent.deb
fi

if [ -x /opt/amazon/ssm/amazon-ssm-agent ] || command -v amazon-ssm-agent >/dev/null 2>&1; then
    echo "SSM agent installed"

    # The agent must start automatically on every boot.
    sudo systemctl enable amazon-ssm-agent || \
        sudo systemctl enable ssm-agent || true

    # The region comes from the IMDS, but setting it explicitly avoids a
    # slow first registration.
    sudo mkdir -p /etc/ssm
    sudo tee /etc/ssm/amazon-ssm-agent.conf >/dev/null << EOF
[agent]
region = ${REGION}
EOF
    sudo chmod 600 /etc/ssm/amazon-ssm-agent.conf
else
    echo "WARN: the SSM agent is not available in this image"
fi

echo "ssm agent setup complete"
