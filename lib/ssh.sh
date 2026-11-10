#!/usr/bin/env bash
# =============================================================================
# lib/ssh.sh - SSH and SSM access to the lab nodes
# =============================================================================
# SSH is the primary channel. SSM Session Manager is the fallback: if a node
# loses its network because of a misapplied bridge configuration, SSM still
# gives us a way in - which matters a lot when the node's only IP lives on
# the bridge we just rewrote.

if [ -n "${__LAB_SSH_SOURCED:-}" ]; then
    return 0
fi
__LAB_SSH_SOURCED=1

# shellcheck source=lib/common.sh
. "${LAB_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
. "${LAB_LIB_DIR}/config.sh"

# The user the harness logs in as. The Debian cloud images ship with the
# unprivileged "admin" account and cloud-init does not install an
# authorized key for root, so root login with a key does not work.
SSH_USER="${SSH_USER:-admin}"

# The SSH options are built on demand: at source time the configuration has
# not been loaded yet, so PVE_SSH_KEY_PATH may not exist.
# shellcheck disable=SC2046
ssh_options() {
    printf '%s\n' \
        "-i" "${PVE_SSH_KEY_PATH:-${LAB_STATE_DIR}/keys/${PVE_KEYPAIR_NAME:-pve-lab}.pem}" \
        "-o" "StrictHostKeyChecking=no" \
        "-o" "UserKnownHostsFile=/dev/null" \
        "-o" "LogLevel=ERROR" \
        "-o" "ConnectTimeout=${SSH_CONNECT_TIMEOUT:-15}" \
        "-o" "ServerAliveInterval=15" \
        "-o" "ServerAliveCountMax=4" \
        "-o" "BatchMode=yes"
}

# ssh_exec <host> <command...>
ssh_exec() {
    local host="$1"; shift
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@${host}" "$@"
}

# ssh_exec_sh <host> <script> - pipe a script over stdin and run it with bash
ssh_exec_sh() {
    local host="$1"; shift
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@${host}" "bash -s" "$@"
}

# ssh_exec_q <host> <command...> - quiet, returns the exit code
ssh_exec_q() {
    local host="$1"; shift
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@${host}" "$@" >/dev/null 2>&1
}

# ssh_write <host> <local-file> <remote-file>
ssh_write() {
    local host="$1" src="$2" dst="$3"
    # shellcheck disable=SC2046
    scp $(ssh_options) "${src}" "${SSH_USER}@${host}:${dst}"
}

# ssh_run_local <host> <local-script> [args...] - upload to /tmp and execute
ssh_run_local() {
    local host="$1" script="$2"; shift 2
    local remote quoted=""
    remote="/tmp/$(basename "${script}").$$"
    ssh_write "${host}" "${script}" "${remote}" || return 1
    if [ $# -gt 0 ]; then
        quoted="$(printf '%q ' "$@")"
    fi
    # The setup scripts configure the system, so they run through sudo.
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@${host}" "sudo chmod +x '${remote}' && sudo '${remote}' ${quoted}; rc=\$?; rm -f '${remote}'; exit \$rc"
}

# Wait until SSH answers on a host. wait_ssh <host> [timeout]
wait_ssh() {
    local host="$1"
    local timeout="${2:-${BOOT_TIMEOUT}}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if ssh_exec_q "${host}" "true"; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# Install a public key on a host so that nodes can authenticate to each other
# (required for 'pvecm add --use_ssh' to work without an interactive prompt).
ssh_install_pubkey() {
    local host="$1"
    local pubkey="$2"
    ssh_exec "${host}" "install -d -m 700 /root/.ssh && \
        grep -qF '${pubkey}' /root/.ssh/authorized_keys 2>/dev/null || \
        printf '%s\\n' '${pubkey}' >> /root/.ssh/authorized_keys; \
        chmod 600 /root/.ssh/authorized_keys"
}

# ---------------------------------------------------------------------------
# SSM fallback
# ---------------------------------------------------------------------------
ssm_agent_installed() {
    aws_quiet ssm describe-instance-information \
        --region "${AWS_REGION}" \
        --filters "Key=InstanceIds,Values=$1"
}

# ssm_exec <instance-id> <command> - run a command through SSM Run Command
ssm_exec() {
    local instance_id="$1"; shift
    local command_id
    command_id="$(aws_cli ssm send-command --region "${AWS_REGION}" \
        --instance-ids "${instance_id}" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"$*\"]" \
        --query "Command.CommandId" --output text 2>/dev/null)"

    [ -n "${command_id}" ] && [ "${command_id}" != "None" ] || return 1

    local deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        local status
        status="$(aws_cli ssm list-command-invocations --region "${AWS_REGION}" \
            --command-id "${command_id}" \
            --query "CommandInvocations[0].Status" --output text 2>/dev/null)"
        case "${status}" in
            Success)
                aws_cli ssm get-command-invocation --region "${AWS_REGION}" \
                    --command-id "${command_id}" --instance-id "${instance_id}" \
                    --query "StandardOutputContent" --output text 2>/dev/null
                return 0
                ;;
            Failed|Cancelled|TimedOut|AccessDenied|Unavailable)
                aws_cli ssm get-command-invocation --region "${AWS_REGION}" \
                    --command-id "${command_id}" --instance-id "${instance_id}" \
                    --query "StandardErrorContent" --output text 2>/dev/null
                return 1
                ;;
        esac
        sleep 3
    done
    return 1
}

# Run a command on a host via SSH, falling back to SSM when SSH fails.
# node_exec <host> <instance-id> <command...>
node_exec() {
    local host="$1" instance_id="$2"; shift 2
    if ssh_exec_q "${host}" "true"; then
        ssh_exec "${host}" "$@"
    else
        log_warn "SSH to ${host} failed - falling back to SSM"
        ssm_exec "${instance_id}" "$@"
    fi
}

# ---------------------------------------------------------------------------
# In-guest helpers
# ---------------------------------------------------------------------------

# Resolve the on-disk device name for an EBS volume by matching the NVMe
# serial number (which AWS sets to the volume ID). Device indexes are not
# reliable on Nitro - nvme device numbering follows attachment order.
# resolve_volume_device <host> <volume-id>
resolve_volume_device() {
    local host="$1" volume_id="$2"
    ssh_exec "${host}" "lsblk -ndo NAME,SERIAL | awk -v v='${volume_id}' '\$2==v {print \$1; exit}'"
}

# Find the in-guest interface name for a MAC address.
# resolve_iface <host> <mac>
resolve_iface() {
    local host="$1" mac="$2"
    ssh_exec "${host}" "for d in /sys/class/net/*; do \
        if [ \"\$(cat \"\$d/address\" 2>/dev/null)\" = \"${mac}\" ]; then basename \"\$d\"; fi; done | head -1"
}
