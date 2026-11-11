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
# The keepalive window has to outlive the long running operations of the
# provisioning: a clone of a 3 GB disk over NFS takes minutes, and the
# mirror job does not send any output while it runs. A shorter window
# kills the connection in the middle of the operation, and the phase
# aborts even though the operation itself succeeded.
ssh_options() {
    printf '%s\n' \
        "-i" "${PVE_SSH_KEY_PATH:-${LAB_STATE_DIR}/keys/${PVE_KEYPAIR_NAME:-pve-lab}.pem}" \
        "-o" "StrictHostKeyChecking=no" \
        "-o" "UserKnownHostsFile=/dev/null" \
        "-o" "LogLevel=ERROR" \
        "-o" "ConnectTimeout=${SSH_CONNECT_TIMEOUT:-15}" \
        "-o" "ServerAliveInterval=60" \
        "-o" "ServerAliveCountMax=60" \
        "-o" "BatchMode=yes"
}

# An IPv6 literal has to be bracketed in the ssh destination, otherwise the
# colons are read as a port separator.
#
# ssh_host <host> - echoes the host in the form ssh expects
ssh_host() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *)   printf '%s' "$1" ;;
    esac
}

# ssh_exec <host> <command...>
ssh_exec() {
    local host="$1"; shift
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@$(ssh_host "${host}")" "$@"
}

# ssh_exec_sh <host> <script> - pipe a script over stdin and run it with bash
ssh_exec_sh() {
    local host="$1"; shift
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@$(ssh_host "${host}")" "bash -s" "$@"
}

# ssh_exec_q <host> <command...> - quiet, returns the exit code
ssh_exec_q() {
    local host="$1"; shift
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@$(ssh_host "${host}")" "$@" >/dev/null 2>&1
}

# ssh_probe <host> - a quick reachability test.
#
# The probe uses a short timeout, because it is only used to find out
# whether an address works. A long timeout would make the fallback to the
# Systems Manager slow.
ssh_probe() {
    local host="$1"
    # shellcheck disable=SC2046
    ssh -i "${PVE_SSH_KEY_PATH:-${LAB_STATE_DIR}/keys/${PVE_KEYPAIR_NAME:-pve-lab}.pem}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=6 \
        -o BatchMode=yes \
        "${SSH_USER}@$(ssh_host "${host}")" true >/dev/null 2>&1
}

# ssh_write <host> <local-file> <remote-file>
ssh_write() {
    local host="$1" src="$2" dst="$3"
    # shellcheck disable=SC2046
    scp $(ssh_options) "${src}" "${SSH_USER}@$(ssh_host "${host}"):${dst}"
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
    ssh $(ssh_options) "${SSH_USER}@$(ssh_host "${host}")" "sudo chmod +x '${remote}' && sudo '${remote}' ${quoted}; rc=\$?; rm -f '${remote}'; exit \$rc"
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
# AWS Systems Manager transport
# ---------------------------------------------------------------------------
#
# The lab has to be reachable from networks where the operator's IPv4 address
# is a CGNAT translation. EC2 instance public IPv4 addresses are unreachable
# from such a network, and some enterprise WLANs have no native IPv6 either.
#
# The SSM agent on the instance opens an OUTBOUND connection to the Systems
# Manager control plane. The operator's side dials out to the same control
# plane, and the two are joined into a session. Nothing has to accept an
# inbound connection on any port, ever.

# ssm_agent_registered <instance-id>
#
# Succeeds when the instance is known to Systems Manager and its agent is
# reporting in. The ping status must be Online - an instance that was seen
# once but has gone away is not usable.
ssm_agent_registered() {
    local status
    status="$(aws_quiet ssm describe-instance-information \
        --region "${AWS_REGION}" \
        --filters "Key=InstanceIds,Values=$1" \
        --query 'InstanceInformationList[0].PingStatus' --output text)"
    [ "${status}" = "Online" ]
}

# The legacy name, kept so the existing call sites keep working.
ssm_agent_installed() {
    ssm_agent_registered "$1"
}

# ssm_wait_registered <instance-id> [timeout-seconds]
#
# The agent needs a moment after the boot to install itself, download the
# agent binary and register with the control plane.
ssm_wait_registered() {
    local instance_id="$1" timeout="${2:-300}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if ssm_agent_registered "${instance_id}"; then
            return 0
        fi
        sleep 10
    done
    return 1
}

# ssm_exec <instance-id> <command...> - run a command through SSM Run Command
#
# The command is passed as a single shell string. Run Command runs it with
# /bin/sh, so the shell syntax must be POSIX, not bash.
ssm_exec() {
    local instance_id="$1"; shift
    local command="$*"
    local command_id

    # The parameters are built with jq so that quotes and newlines in the
    # command survive the JSON encoding.
    local params
    params="$(jq -n --arg cmd "${command}" '{commands:[$cmd]}')"

    command_id="$(aws_cli ssm send-command --region "${AWS_REGION}" \
        --instance-ids "${instance_id}" \
        --document-name "AWS-RunShellScript" \
        --parameters "${params}" \
        --query "Command.CommandId" --output text 2>/dev/null)"

    [ -n "${command_id}" ] && [ "${command_id}" != "None" ] || return 1

    local deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        # 'status' is a read-only variable in zsh, so it is named differently.
        local cmd_status
        cmd_status="$(aws_cli ssm list-command-invocations --region "${AWS_REGION}" \
            --command-id "${command_id}" \
            --query "CommandInvocations[0].Status" --output text 2>/dev/null)"
        case "${cmd_status}" in
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

# ssm_exec_script <instance-id> <local-script> [args...]
#
# Uploads a script and runs it with bash. This is the equivalent of
# ssh_run_local, used when the instance is only reachable over SSM.
ssm_exec_script() {
    local instance_id="$1" script="$2"; shift 2
    local remote quoted=""

    remote="/tmp/$(basename "${script}").$$"
    if ! aws_ssm_put_file "${instance_id}" "${script}" "${remote}"; then
        return 1
    fi

    if [ $# -gt 0 ]; then
        quoted="$(printf '%q ' "$@")"
    fi

    # The setup scripts configure the system, so they run through sudo.
    ssm_exec "${instance_id}" \
        "sudo chmod +x '${remote}' && sudo '${remote}' ${quoted}; rc=\$?; rm -f '${remote}'; exit \$rc"
}

# aws_ssm_put_file <instance-id> <local-file> <remote-path>
#
# Run Command cannot transfer files. The content is therefore passed through
# the command itself, base64 encoded so that it survives the JSON encoding
# and the shell quoting.
aws_ssm_put_file() {
    local instance_id="$1" src="$2" dst="$3"
    local b64
    b64="$(base64 < "${src}" | tr -d '\n')"
    [ -n "${b64}" ] || return 1

    # The Run Command parameter limit is 24 KiB per command. A script plus
    # its base64 can exceed that, so the payload is written in chunks with
    # one command per chunk.
    local chunk_size=8000
    local offset=0 part first=1
    local cmd

    while [ "${offset}" -lt "${#b64}" ]; do
        part="${b64:${offset}:${chunk_size}}"
        if [ "${first}" -eq 1 ]; then
            cmd="printf '%s' '${part}' > '${dst}.b64'"
            first=0
        else
            cmd="printf '%s' '${part}' >> '${dst}.b64'"
        fi
        ssm_exec "${instance_id}" "${cmd}" >/dev/null || return 1
        offset=$((offset + chunk_size))
    done

    ssm_exec "${instance_id}" \
        "base64 -d '${dst}.b64' > '${dst}' && chmod +x '${dst}' && rm -f '${dst}.b64'"
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
# Transport abstraction
# ---------------------------------------------------------------------------
#
# Every phase of the harness needs to run commands on a node. The transport
# can be SSH (when the operator's network allows it) or SSM (always). The
# functions below hide the difference, so the phase code does not have to
# care.

# The transport to use for a node. The result is cached in the state file,
# so the choice is made once and then stays stable for the whole run.
#
#   ssh  - the operator's network reaches the instance address
#   ssm  - the instance is reached through the Systems Manager control plane
#
# The probe is cheap: a single SSH connection attempt with a short timeout.
transport_for() {
    local name="$1" cached
    cached="$(state_get ".instances.${name}.transport")"
    case "${cached}" in
        ssh|ssm)
            printf '%s' "${cached}"
            return 0
            ;;
    esac

    local instance_id
    instance_id="$(state_get ".instances.${name}.id")"

    # The probe tries every address the node has. The IPv6 address is the
    # preferred one, because it survives a change of the operator's public
    # IPv4 address - but a network without native IPv6 cannot reach it at
    # all, so the public IPv4 address is tried as well.
    local host
    for host in $(state_reach_ips "${name}"); do
        if ssh_probe "${host}"; then
            state_set ".instances.${name}.transport" "\"ssh\""
            state_set ".instances.${name}.ssh_host" "\"${host}\""
            printf 'ssh'
            return 0
        fi
    done

    if [ -n "${instance_id}" ] && ssm_agent_registered "${instance_id}"; then
        state_set ".instances.${name}.transport" "\"ssm\""
        printf 'ssm'
        return 0
    fi

    # Nothing works. Default to SSM, which at least gives a clear error.
    printf 'ssm'
}

# lab_exec <node> <command...> - run a command on a node over the transport
lab_exec() {
    local name="$1"; shift
    local transport host instance_id
    transport="$(transport_for "${name}")"
    host="$(state_get ".instances.${name}.ssh_host")"
    [ -n "${host}" ] || host="$(state_reach_ip "${name}")"
    instance_id="$(state_get ".instances.${name}.id")"

    if [ "${transport}" = "ssh" ]; then
        ssh_exec "${host}" "$@"
        return $?
    fi
    ssm_exec "${instance_id}" "$@"
}

# lab_exec_q <node> <command...> - quiet variant, returns the exit code
lab_exec_q() {
    local name="$1"; shift
    local transport host instance_id
    transport="$(transport_for "${name}")"
    host="$(state_get ".instances.${name}.ssh_host")"
    [ -n "${host}" ] || host="$(state_reach_ip "${name}")"
    instance_id="$(state_get ".instances.${name}.id")"

    if [ "${transport}" = "ssh" ]; then
        ssh_exec_q "${host}" "$@"
        return $?
    fi
    ssm_exec "${instance_id}" "$@" >/dev/null 2>&1
}

# lab_run_script <node> <local-script> [args...] - upload and run a script
lab_run_script() {
    local name="$1" script="$2"; shift 2
    local transport host instance_id
    transport="$(transport_for "${name}")"
    host="$(state_get ".instances.${name}.ssh_host")"
    [ -n "${host}" ] || host="$(state_reach_ip "${name}")"
    instance_id="$(state_get ".instances.${name}.id")"

    if [ "${transport}" = "ssh" ]; then
        ssh_run_local "${host}" "${script}" "$@"
        return $?
    fi
    ssm_exec_script "${instance_id}" "${script}" "$@"
}

# lab_wait_ready <node> [timeout] - wait until the node answers on the
# transport that is actually available.
lab_wait_ready() {
    local name="$1" timeout="${2:-600}"
    local host instance_id deadline
    host="$(state_reach_ip "${name}")"
    instance_id="$(state_get ".instances.${name}.id")"
    deadline=$(( $(date +%s) + timeout ))

    while [ "$(date +%s)" -lt "${deadline}" ]; do
        local candidate
        for candidate in $(state_reach_ips "${name}"); do
            if ssh_probe "${candidate}"; then
                state_set ".instances.${name}.transport" "\"ssh\""
                state_set ".instances.${name}.ssh_host" "\"${candidate}\""
                return 0
            fi
        done
        if [ -n "${instance_id}" ] && ssm_agent_registered "${instance_id}"; then
            state_set ".instances.${name}.transport" "\"ssm\""
            return 0
        fi
        sleep 10
    done
    return 1
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
    # The EBS serial has no dash: "vol01442de5991586176" and not
    # "vol-01442de5991586176". The dash is therefore removed before the
    # comparison.
    local serial
    serial="$(printf '%s' "${volume_id}" | tr -d '-')"
    ssh_exec "${host}" "lsblk -ndo NAME,SERIAL | awk -v v='${serial}' '\$2==v {print \$1; exit}'"
}

# Find the in-guest interface name for a MAC address.
# resolve_iface <host> <mac>
resolve_iface() {
    local host="$1" mac="$2"
    ssh_exec "${host}" "for d in /sys/class/net/*; do \
        if [ \"\$(cat \"\$d/address\" 2>/dev/null)\" = \"${mac}\" ]; then basename \"\$d\"; fi; done | head -1"
}
