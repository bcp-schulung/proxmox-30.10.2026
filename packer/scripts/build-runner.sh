#!/bin/bash
# =============================================================================
# build-runner.sh - the whole AMI build, run detached on the build instance
# =============================================================================
#
# The runner is uploaded once and then runs on its own. It does everything
# the Packer build did, in one go, and writes its exit status to a marker
# file. The connection to the instance can drop at any time - the build is
# unaffected.
#
# Usage: build-runner.sh <pve|pbs>
# =============================================================================
set -uo pipefail

KIND="${1:-pve}"

LOG="/var/log/lab-ami-build.log"
MARKER="/var/log/lab-ami-build.rc"

# The build directory holds the step scripts.
BUILD_DIR="/opt/lab-build"
export PACKER_SCRIPTS_DIR="${BUILD_DIR}"

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

mkdir -p /var/log /opt/lab-build

# Everything is written to the log file as well, so that the progress can
# be read from outside.
exec > >(tee -a "${LOG}") 2>&1

say() { printf '[build-runner] %s\n' "$*"; }

finish() {
    printf '%s' "${1}" > "${MARKER}"
    say "finished with exit status ${1}"
    exit "${1}"
}

say "the build started at $(date -u) for ${KIND}"

# The step scripts live in the build directory.
if [ -f "${BUILD_DIR}/lib-common.sh" ]; then
    # shellcheck source=/dev/null
    . "${BUILD_DIR}/lib-common.sh"
fi

# ---------------------------------------------------------------------------
# The helper that runs a step script and waits for it.
#
# A step that needs a reboot is run in two parts: the part before the
# reboot, and the part after. The reboot is done by the runner itself, so
# that the detached script is not killed by it.
# ---------------------------------------------------------------------------
run_step() {
    local script="$1"; shift
    say "--- running ${script} ---"
    if ! bash "${BUILD_DIR}/${script}" "$@"; then
        say "ERROR: ${script} failed"
        return 1
    fi
    say "--- ${script} finished ---"
    return 0
}

# ---------------------------------------------------------------------------
# The passwordless sudo rule.
#
# The Proxmox installation resets the sudoers configuration, so the rule is
# written before every step that needs it.
# ---------------------------------------------------------------------------
ensure_sudo() {
    if ! sudo -n true 2>/dev/null; then
        printf 'admin ALL=(ALL) NOPASSWD:ALL\n' | sudo tee /etc/sudoers.d/90-lab-admin >/dev/null 2>&1 || true
        sudo chmod 440 /etc/sudoers.d/90-lab-admin 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# 1. The base image
# ---------------------------------------------------------------------------
ensure_sudo
run_step "01-base.sh" || finish 1

# ---------------------------------------------------------------------------
# 2. The SSM agent
# ---------------------------------------------------------------------------
ensure_sudo
run_step "05-ssm-agent.sh" || finish 1

# ---------------------------------------------------------------------------
# 3. The Proxmox Backup Server
#
# PBS keeps the Debian kernel, so there is no reboot and no kernel step. The
# build is a single run.
# ---------------------------------------------------------------------------
if [ "${KIND}" = "pbs" ]; then
    ensure_sudo
    run_step "40-pbs-install.sh" || finish 1
    say "the PBS build finished"
    finish 0
fi

# ---------------------------------------------------------------------------
# 3b. The NFS storage server
#
# The NFS server keeps the Debian kernel, so there is no reboot and no
# kernel step. The build is a single run.
# ---------------------------------------------------------------------------
if [ "${KIND}" = "nfs" ]; then
    ensure_sudo
    run_step "45-nfs-install.sh" || finish 1
    say "the NFS build finished"
    finish 0
fi

# ---------------------------------------------------------------------------
# 4. The Proxmox repository and kernel
# ---------------------------------------------------------------------------
ensure_sudo
run_step "10-proxmox-repo.sh" || finish 1

# ---------------------------------------------------------------------------
# 4. Reboot into the Proxmox kernel
#
# The reboot is done here, in the runner, so that the detached script
# survives it. The runner is restarted by a systemd unit that the reboot
# step installs.
# ---------------------------------------------------------------------------
say "--- rebooting into the Proxmox kernel ---"

cat > /etc/systemd/system/lab-ami-build.service << 'UNIT_EOF'
[Unit]
Description=Continue the lab AMI build after the reboot
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/lab-build/build-resume.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /opt/lab-build/build-resume.sh << 'RESUME_EOF'
#!/bin/bash
# The part of the build that runs after the reboot into the Proxmox kernel.
# It runs as root, through the systemd unit.
set -uo pipefail

LOG="/var/log/lab-ami-build.log"
MARKER="/var/log/lab-ami-build.rc"
BUILD_DIR="/opt/lab-build"
export PACKER_SCRIPTS_DIR="${BUILD_DIR}"
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exec > >(tee -a "${LOG}") 2>&1
say() { printf '[build-runner] %s\n' "$*"; }

say "the build resumed after the reboot at $(date -u)"

if [ -f "${BUILD_DIR}/lib-common.sh" ]; then
    # shellcheck source=/dev/null
    . "${BUILD_DIR}/lib-common.sh"
fi

# The passwordless sudo rule - the Proxmox installation resets it.
printf 'admin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-lab-admin
chmod 440 /etc/sudoers.d/90-lab-admin

run_step() {
    local script="$1"; shift
    say "--- running ${script} ---"
    if ! bash "${BUILD_DIR}/${script}" "$@"; then
        say "ERROR: ${script} failed"
        return 1
    fi
    say "--- ${script} finished ---"
    return 0
}

# The Proxmox packages.
run_step "20-proxmox-install.sh" || { printf '%s' "1" > "${MARKER}"; exit 1; }

# The kernel, the initramfs, GRUB, the firewall and the cleanup.
run_step "30-pve-finalize.sh" || { printf '%s' "1" > "${MARKER}"; exit 1; }

# The build is done. The unit must not run again.
systemctl disable lab-ami-build.service >/dev/null 2>&1 || true

printf '%s' "0" > "${MARKER}"
say "the build finished successfully"
RESUME_EOF

sudo chmod +x /opt/lab-build/build-resume.sh
sudo systemctl daemon-reload
sudo systemctl enable lab-ami-build.service
echo "the build unit is enabled: $(sudo systemctl is-enabled lab-ami-build.service)"

# The reboot is done with a delay, so that the unit is registered with
# systemd and the log is flushed before the machine goes down.
sudo sh -c 'nohup sh -c "sleep 8; systemctl reboot" >/dev/null 2>&1 &'
say "the reboot was triggered - the build continues through the systemd unit"
exit 0
