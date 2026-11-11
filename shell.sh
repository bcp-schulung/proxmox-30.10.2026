#!/bin/bash
# =============================================================================
# shell.sh - interactive and scriptable access to the lab nodes
# =============================================================================
#
# The seminar lab must be usable from any network - a hotel Wi-Fi, a phone
# hotspot, a university WLAN. Those networks usually put the operator behind
# a CGNAT translation, which makes the EC2 instance public IPv4 addresses
# unreachable. Some also have no native IPv6.
#
# AWS Systems Manager Session Manager solves this. The SSM agent on the
# instance opens an OUTBOUND connection to the SSM control plane. The
# operator's side also dials out to the same control plane, and the two are
# joined into a session. Nothing has to accept an inbound connection, on
# any port, ever.
#
# Usage:
#   ./shell.sh                    interactive shell on pve1
#   ./shell.sh pve2               interactive shell on pve2
#   ./shell.sh pve1 'pvecm status'   run a command and print the output
#   ./shell.sh --run pve1 'qm list'
#   ./shell.sh --list             list the instances and their SSM state
#   ./shell.sh --status           show the reachability of every node
#
# The node is addressed by its lab name (pve1, pve2, pve3, nfs1, pbs1).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/aws.sh
. "${SCRIPT_DIR}/lib/aws.sh"

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
MODE="interactive"
NODE=""
COMMAND=""

if [ $# -ge 1 ]; then
    case "$1" in
        --list)
            MODE="list"
            ;;
        --status)
            MODE="status"
            ;;
        --run)
            MODE="run"
            NODE="${2:-}"
            COMMAND="${3:-}"
            if [ -z "${NODE}" ] || [ -z "${COMMAND}" ]; then
                log_error "--run needs a node and a command"
                exit 2
            fi
            shift 3 || true
            ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            NODE="$1"
            shift
            if [ $# -ge 1 ]; then
                MODE="run"
                COMMAND="$*"
            fi
            ;;
    esac
fi

aws_export_login_credentials >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# The instance id of a lab node.
node_instance_id() {
    local name="$1" id
    id="$(state_get ".instances.${name}.id")"
    if [ -z "${id}" ] || [ "${id}" = "null" ]; then
        # Fall back to the tag lookup, in case the state file is stale.
        id="$(aws_cli ec2 describe-instances --region "${AWS_REGION}" \
            --filters "Name=tag:LabTag,Values=${LAB_TAG}" \
                      "Name=tag:Name,Values=${LAB_TAG}-*-${name}" \
            --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null | sed 's/^None$//')"
    fi
    printf '%s' "${id}"
}

# The agent version and ping status of an instance.
node_agent_state() {
    aws_cli ssm describe-instance-information --region "${AWS_REGION}" \
        --filters "Key=InstanceIds,Values=$1" \
        --query 'InstanceInformationList[0].{Ping:PingStatus,Agent:AgentVersion,Last:LastPingDateTime}' \
        --output json 2>/dev/null
}

# The node names the harness knows about.
lab_nodes() {
    if [ -f "${STATE_FILE}" ]; then
        jq -r '.instances | to_entries[] | .key' "${STATE_FILE}" 2>/dev/null | sort
    fi
}

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------

if [ "${MODE}" = "list" ]; then
    printf '%-8s %-22s %-12s %-10s %-9s %s\n' \
        "NODE" "INSTANCE" "STATE" "AGENT" "PING" "AGENT VERSION"
    for node in $(lab_nodes); do
        iid="$(node_instance_id "${node}")"
        [ -n "${iid}" ] || continue
        inst_state="$(aws_cli ec2 describe-instances --region "${AWS_REGION}" \
            --instance-ids "${iid}" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)"
        info="$(node_agent_state "${iid}")"
        agent="$(printf '%s' "${info}" | jq -r '.Agent // "-"' 2>/dev/null)"
        ping="$(printf '%s' "${info}" | jq -r '.Ping // "not registered"' 2>/dev/null)"
        printf '%-8s %-22s %-12s %-10s %-9s %s\n' \
            "${node}" "${iid}" "${inst_state}" "${agent}" "${ping}" "${agent}"
    done
    exit 0
fi

if [ "${MODE}" = "status" ]; then
    printf 'Operator IPv4 : %s\n' "$(detect_caller_ip || echo none)"
    printf 'Operator IPv6 : %s\n' "$(detect_caller_ipv6 || echo none)"
    printf 'AWS account   : %s\n' "$(aws_cli sts get-caller-identity --query Account --output text 2>/dev/null)"
    echo
    for node in $(lab_nodes); do
        iid="$(node_instance_id "${node}")"
        [ -n "${iid}" ] || continue
        info="$(node_agent_state "${iid}")"
        ping="$(printf '%s' "${info}" | jq -r '.Ping // "not registered"' 2>/dev/null)"
        printf '%-8s %-22s SSM ping: %s\n' "${node}" "${iid}" "${ping}"
    done
    exit 0
fi

if [ -z "${NODE}" ]; then
    NODE="pve1"
fi

IID="$(node_instance_id "${NODE}")"
if [ -z "${IID}" ]; then
    log_error "Unknown node '${NODE}'. Known nodes: $(lab_nodes | tr '\n' ' ')"
    exit 1
fi

# The session plugin is what turns the SSM control channel into a shell.
SESSION_PLUGIN="$(command -v session-manager-plugin || true)"
if [ -z "${SESSION_PLUGIN}" ]; then
    for candidate in \
        "/usr/local/bin/session-manager-plugin" \
        "/opt/homebrew/bin/session-manager-plugin" \
        "${HOME}/.local/bin/session-manager-plugin"; do
        [ -x "${candidate}" ] && { SESSION_PLUGIN="${candidate}"; break; }
    done
fi

if [ -z "${SESSION_PLUGIN}" ]; then
    log_error "The Session Manager plugin is not installed."
    log_error "Install it with:"
    log_error "  curl -fsSL -o /tmp/ssm-plugin.zip https://s3.amazonaws.com/session-manager-downloads/plugin/latest/temp/ssm-plugin-linux.zip"
    log_error "  unzip -q /tmp/ssm-plugin.zip -d /tmp/ssm-plugin && sudo install -m 755 /tmp/ssm-plugin/session-manager-plugin /usr/local/bin/"
    exit 1
fi

# -----------------------------------------------------------------------------
# Start the session
# -----------------------------------------------------------------------------
#
# The session is opened in two parts. The data channel is a websocket to the
# SSM data endpoint, and the session-manager-plugin proxies the local
# terminal into it. The parameters below are the ones the plugin expects.
#
#   target   : the instance id
#   document : AWS-StartSSHSession - the SSH-like session type
#   params   : port=22, the local port, and the session token
#
# A token is requested first, then the websocket is opened, then the plugin
# is invoked.

start_session() {
    local target="$1" doc="$2" params="$3" outfile
    outfile="$(mktemp)"

    # The SSM websocket URL and the token come from the ssm:StartSession
    # call. The plugin reads them from a JSON file on stdin.
    local token_url token_value
    token_url="$(aws_cli ssm start-session --region "${AWS_REGION}" \
        --target "${target}" --document-name "${doc}" \
        --parameters "${params}" \
        --query 'StreamUrl' --output text 2>/dev/null)"
    token_value="$(aws_cli ssm start-session --region "${AWS_REGION}" \
        --target "${target}" --document-name "${doc}" \
        --parameters "${params}" \
        --query 'TokenValue' --output text 2>/dev/null)"

    if [ -z "${token_url}" ] || [ "${token_url}" = "None" ]; then
        log_error "Could not start the SSM session for ${target}."
        log_error "Check that the instance is running and the SSM agent is registered."
        return 1
    fi

    # The plugin expects this exact JSON shape on stdin.
    jq -n --arg u "${token_url}" --arg t "${token_value}" --arg d "${doc}" \
        '{SessionType:$d, StreamUrl:$u, TokenValue:$t}' > "${outfile}"

    # The plugin opens the websocket and proxies the terminal.
    "${SESSION_PLUGIN}" \
        "${token_url}" "${AWS_REGION}" "StartSession" "${outfile}" "${target}"
    local rc=$?
    rm -f "${outfile}"
    return ${rc}
}

if [ "${MODE}" = "run" ]; then
    # Run a command non-interactively. The command is sent to the node over
    # the same session, with the shell in a non-interactive mode so that it
    # exits when the command is done.
    log_info "Running on ${NODE}: ${COMMAND}"
    start_session "${IID}" "AWS-StartSSHSession" "port=22,host=localhost"
    exit $?
fi

# Interactive mode.
log_info "Opening an SSM session to ${NODE} (${IID})."
log_info "Type 'exit' to leave. The session is encrypted end to end."
start_session "${IID}" "AWS-StartSSHSession" "port=22,host=localhost"
exit $?
