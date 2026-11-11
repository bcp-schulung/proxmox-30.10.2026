#!/usr/bin/env bash
# =============================================================================
# debug.sh - diagnose the state of the seminar lab
# =============================================================================
# Walks every layer of the stack and reports PASS / WARN / FAIL:
#
#   1. local toolchain and configuration
#   2. AWS control plane (instances, ENIs, security groups, volumes)
#   3. reachability from the operator's machine
#   4. node level (services, corosync, storage, networking)
#   5. guest level (VMs, containers, guest agent)
#
# The report is written to logs/debug-<timestamp>.log and the summary is
# printed to the terminal.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/aws.sh
. "${SCRIPT_DIR}/lib/aws.sh"
# shellcheck source=lib/ssh.sh
. "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/pve.sh
. "${SCRIPT_DIR}/lib/pve.sh"
# shellcheck source=lib/lab.sh
. "${SCRIPT_DIR}/lib/lab.sh"

# --- options -----------------------------------------------------------------
ONLY_NODE=""
QUICK=0
SHOW_LOG=0

usage() {
    cat << 'EOF'
debug.sh - diagnose the Proxmox VE seminar lab

Usage:
  ./debug.sh [options]

Options:
  --node <name>   Only inspect one node (pve1, pve2, pve3)
  --quick         Skip the slow checks (guest agent, storage probes, internet)
  --show-log      Print the full report at the end
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --node)     ONLY_NODE="$2"; shift 2 ;;
        --quick)    QUICK=1; shift ;;
        --show-log) SHOW_LOG=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
done

# --- reporting ---------------------------------------------------------------
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
REPORT_FILE=""

report() {
    local status="$1" message="$2" detail="${3:-}"
    local colour
    case "${status}" in
        PASS) colour="${C_GREEN}";  PASS_COUNT=$((PASS_COUNT + 1)) ;;
        WARN) colour="${C_YELLOW}"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
        FAIL) colour="${C_RED}";    FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        *)    colour="${C_DIM}";    ;;
    esac
    printf '  %s%-4s%s %s\n' "${colour}" "${status}" "${C_RESET}" "${message}" >&2
    if [ -n "${detail}" ]; then
        printf '%s       %s%s\n' "${C_DIM}" "${detail}" "${C_RESET}" >&2
    fi
    if [ -n "${REPORT_FILE}" ]; then
        printf '[%s] %s%s\n' "${status}" "${message}" "${detail:+ - ${detail}}" >> "${REPORT_FILE}"
    fi
}

section() {
    printf '\n%s%s%s\n' "${C_BOLD}" "== $*" "${C_RESET}" >&2
    [ -n "${REPORT_FILE}" ] && printf '\n== %s\n' "$*" >> "${REPORT_FILE}"
    return 0
}

# --- layers ------------------------------------------------------------------

debug_local() {
    section "1. Local toolchain and configuration"

    local tool
    for tool in aws jq ssh scp curl; do
        if command -v "${tool}" >/dev/null 2>&1; then
            report PASS "${tool} is installed"
        else
            report FAIL "${tool} is NOT installed"
        fi
    done

    if [ -f "${PVE_SSH_KEY_PATH}" ]; then
        report PASS "SSH private key present (${PVE_SSH_KEY_PATH})"
    else
        report FAIL "SSH private key missing (${PVE_SSH_KEY_PATH})"
    fi

    if state_exists; then
        report PASS "State file found (${STATE_FILE})"
        report INFO "current phase: $(state_get ".phase")"
    else
        report FAIL "No state file - has provision.sh ever run? (${STATE_FILE})"
        return 1
    fi

    local identity
    if identity="$(aws_cli sts get-caller-identity --output json 2>&1)"; then
        report PASS "AWS credentials valid (account $(printf '%s' "${identity}" | jq -r '.Account'))"
    else
        report FAIL "AWS credentials are not usable" "${identity}"
        return 1
    fi
}

debug_aws() {
    section "2. AWS control plane"

    local node instance_id state
    for node in $(lab_node_list); do
        instance_id="$(state_get ".instances.${node}.id")"
        if [ -z "${instance_id}" ]; then
            report FAIL "${node}: no instance recorded in the state file"
            continue
        fi
        state="$(aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "${instance_id}" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)"
        if [ "${state}" = "running" ]; then
            report PASS "${node}: instance ${instance_id} is running"
        else
            report FAIL "${node}: instance ${instance_id} is ${state:-unknown}"
        fi

        local priv pub v6
        priv="$(state_reach_ip "${node}")"
        pub="$(state_get ".instances.${node}.public_ip")"
        v6="$(state_get ".instances.${node}.ipv6")"
        report INFO "${node}: reach=${priv} public=${pub} ipv6=${v6:-none}"

        # The instance must have nested virtualization enabled, otherwise the
        # Proxmox guests cannot run.
        local cpu_options
        cpu_options="$(aws_cli ec2 describe-instances --region "${AWS_REGION}" --instance-ids "${instance_id}" \
            --query 'Reservations[0].Instances[0].CpuOptions.NestedVirtualization' --output text 2>/dev/null)"
        if [ "${cpu_options}" = "enabled" ]; then
            report PASS "${node}: nested virtualization is enabled"
        else
            report FAIL "${node}: nested virtualization is '${cpu_options:-disabled}' - KVM guests will not start"
        fi
    done

    # Security groups
    local sg
    for sg in pve-lab services-lab; do
        if [ -n "$(aws_sg_id "${sg}")" ]; then
            report PASS "security group ${sg} exists"
        else
            report FAIL "security group ${sg} is missing"
        fi
    done

    # Storage
    local vol
    for node in $(lab_node_list); do
        vol="$(state_get ".instances.${node}.data_volume")"
        if [ -n "${vol}" ]; then
            local vol_state
            vol_state="$(aws_cli ec2 describe-volumes --region "${AWS_REGION}" --volume-ids "${vol}" \
                --query 'Volumes[0].State' --output text 2>/dev/null)"
            if [ "${vol_state}" = "in-use" ] || [ "${vol_state}" = "available" ]; then
                report PASS "${node}: data volume ${vol} is ${vol_state}"
            else
                report FAIL "${node}: data volume ${vol} is ${vol_state:-unknown}"
            fi
        else
            report FAIL "${node}: no data volume recorded"
        fi
    done
}

debug_reachability() {
    section "3. Reachability from this machine"

    # The operator's own addresses. The IPv4 address is very often a CGNAT
    # translation, and EC2 instance public IPv4 addresses are unreachable
    # from such a network - so both are reported.
    local caller4 caller6
    caller4="$(detect_caller_ip)"
    caller6="$(detect_caller_ipv6)"
    report INFO "operator IPv4: ${caller4:-none}"
    report INFO "operator IPv6: ${caller6:-none}"
    if [ -z "${caller6}" ]; then
        report WARN "no usable IPv6 - the lab is only reachable over IPv4"
    fi

    # The address the harness uses for each node.
    local node reach
    for node in $(lab_node_list); do
        reach="$(state_reach_ip "${node}")"
        [ -n "${reach}" ] || continue
        if wait_tcp "${reach}" 22 5; then
            report PASS "${node}: SSH (22) reachable at ${reach}"
        else
            report FAIL "${node}: SSH (22) NOT reachable at ${reach} - check the security group and the operator IP"
        fi
        if wait_tcp "${reach}" 8006 5; then
            report PASS "${node}: web UI (8006) reachable at ${reach}"
        else
            report FAIL "${node}: web UI (8006) NOT reachable at ${reach}"
        fi
    done

    local pbs_reach
    pbs_reach="$(state_reach_ip "pbs1")"
    if [ -n "${pbs_reach}" ]; then
        if wait_tcp "${pbs_reach}" 8007 5; then
            report PASS "pbs1: PBS web UI (8007) reachable at ${pbs_reach}"
        else
            report FAIL "pbs1: PBS web UI (8007) NOT reachable at ${pbs_reach}"
        fi
    fi
}

debug_node() {
    # debug_node <node>
    local node="$1"
    local priv
    priv="$(state_reach_ip "${node}")"

    section "4. Node ${node} (${priv})"

    if ! ssh_exec_q "${priv}" "true"; then
        report FAIL "${node}: SSH is not working"
        return 0
    fi
    report PASS "${node}: SSH works"

    # --- hostname resolution ---
    local resolved
    resolved="$(ssh_exec "${priv}" "getent hosts \$(hostname) | awk '{print \$1}' | head -1")"
    if [ "${resolved}" = "${priv}" ]; then
        report PASS "${node}: hostname resolves to ${resolved}"
    elif printf '%s' "${resolved}" | grep -q '^127\.'; then
        report FAIL "${node}: hostname resolves to the loopback address ${resolved} - pve-cluster will refuse to start"
    else
        report WARN "${node}: hostname resolves to ${resolved}, expected ${priv}"
    fi

    # --- services ---
    local svc
    for svc in pveproxy pvedaemon pvestatd corosync pve-cluster ssh; do
        if ssh_exec_q "${priv}" "systemctl is-active --quiet ${svc}"; then
            report PASS "${node}: ${svc} is running"
        else
            report FAIL "${node}: ${svc} is NOT running"
        fi
    done

    # --- nested virtualization ---
    local nested
    nested="$(ssh_exec "${priv}" "cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo missing")"
    if [ "${nested}" = "Y" ] || [ "${nested}" = "1" ]; then
        report PASS "${node}: nested virtualization is enabled in the guest kernel"
    else
        report WARN "${node}: nested virtualization is '${nested}' (host-level check: the AWS instance must run with --cpu-options NestedVirtualization=enabled)"
    fi

    # --- cluster ---
    if [ "${QUICK}" = "1" ]; then
        return 0
    fi

    local quorum
    quorum="$(ssh_exec "${priv}" "pvecm status 2>/dev/null | grep -E 'Quorate|Membership' | tr '\n' ' '")"
    if printf '%s' "${quorum}" | grep -q 'Quorate: Yes'; then
        report PASS "${node}: cluster is quorate" "${quorum}"
    elif [ -z "${quorum}" ]; then
        report WARN "${node}: not part of a cluster yet (run the 'cluster' phase)"
    else
        report FAIL "${node}: cluster is NOT quorate" "${quorum}"
    fi

    # --- storage ---
    local storage
    storage="$(ssh_exec "${priv}" "pvesm status 2>/dev/null")"
    if printf '%s' "${storage}" | grep -qE "^${NFS_STORAGE_ID}"; then
        report PASS "${node}: shared storage '${NFS_STORAGE_ID}' is available"
    else
        report FAIL "${node}: shared storage '${NFS_STORAGE_ID}' is missing" "${storage}"
    fi
    if printf '%s' "${storage}" | grep -qE "^${LOCAL_STORAGE_ID}"; then
        report PASS "${node}: local storage '${LOCAL_STORAGE_ID}' is available"
    else
        report FAIL "${node}: local storage '${LOCAL_STORAGE_ID}' is missing"
    fi

    # --- networking ---
    if ssh_exec_q "${priv}" "ip -4 addr show vmbr0 | grep -q 'inet'"; then
        report PASS "${node}: vmbr0 has an address"
    else
        report FAIL "${node}: vmbr0 has no address - the guest bridge is not up"
    fi
    if ssh_exec_q "${priv}" "systemctl is-active --quiet dnsmasq"; then
        report PASS "${node}: dnsmasq is running (DHCP for the guest overlay)"
    else
        report FAIL "${node}: dnsmasq is NOT running - guests will not get an address"
    fi
    if ssh_exec_q "${priv}" "iptables -t nat -C POSTROUTING -s $(lab_node_overlay_cidr "${node}") -j MASQUERADE 2>/dev/null"; then
        report PASS "${node}: NAT rule for the guest overlay is present"
    else
        report WARN "${node}: NAT rule for the guest overlay is missing - guests have no internet"
    fi
    if ssh_exec_q "${priv}" "sysctl -n net.ipv4.ip_forward | grep -q '^1$'"; then
        report PASS "${node}: IP forwarding is enabled"
    else
        report FAIL "${node}: IP forwarding is disabled"
    fi

    # --- time sync ---
    local chrony
    chrony="$(ssh_exec "${priv}" "chronyc tracking 2>/dev/null | grep -E 'Reference ID|System time' | head -1")"
    if [ -n "${chrony}" ]; then
        report PASS "${node}: chrony is tracking a time source" "${chrony}"
    else
        report FAIL "${node}: chrony is not tracking - corosync will fence the node"
    fi

    # --- guests ---
    local vms cts
    vms="$(ssh_exec "${priv}" "qm list 2>/dev/null | tail -n +2 | awk '{print \$1, \$2, \$3}'")"
    cts="$(ssh_exec "${priv}" "pct list 2>/dev/null | tail -n +2 | awk '{print \$1, \$2, \$3}'")"
    if [ -n "${vms}" ]; then
        report INFO "${node} VMs:"
        printf '%s\n' "${vms}" | while IFS= read -r line; do
            [ -n "${line}" ] && report INFO "  ${line}"
        done
    fi
    if [ -n "${cts}" ]; then
        report INFO "${node} containers:"
        printf '%s\n' "${cts}" | while IFS= read -r line; do
            [ -n "${line}" ] && report INFO "  ${line}"
        done
    fi

    # --- guest agent ---
    local vmid
    for vmid in ${VM_WEB_ID} ${VM_CLONE_FULL_ID} ${VM_CLONE_LINKED_ID}; do
        if ssh_exec_q "${priv}" "qm status ${vmid} 2>/dev/null | grep -q running"; then
            if ssh_exec_q "${priv}" "qm guest cmd ${vmid} ping >/dev/null 2>&1"; then
                report PASS "${node}: VM ${vmid} guest agent answers"
            else
                report WARN "${node}: VM ${vmid} guest agent does not answer"
            fi
        fi
    done

    # --- errors in the log ---
    local errors
    errors="$(ssh_exec "${priv}" "journalctl -u pvedaemon -u pveproxy --since '1 hour ago' --no-pager -p err 2>/dev/null | tail -5")"
    if [ -n "${errors}" ]; then
        report WARN "${node}: recent errors in the Proxmox service logs" "${errors}"
    else
        report PASS "${node}: no errors in the Proxmox service logs (last hour)"
    fi
}

debug_cluster_connectivity() {
    section "5. Cluster interconnect"

    local first node
    first="$(lab_node_list | head -1)"
    local first_priv
    first_priv="$(state_reach_ip "${first}")"

    for node in $(lab_node_list); do
        [ "${node}" = "${first}" ] && continue
        local target_priv
        target_priv="$(state_reach_ip "${node}")"

        # Corosync uses the KNET UDP port range.
        if ssh_exec_q "${first_priv}" "timeout 5 bash -c 'cat < /dev/null > /dev/udp/${target_priv}/5405' 2>/dev/null"; then
            report PASS "${first} -> ${node}: corosync port 5405 reachable"
        else
            report WARN "${first} -> ${node}: corosync port 5405 not confirmed"
        fi

        if ssh_exec_q "${first_priv}" "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes root@${target_priv} true"; then
            report PASS "${first} -> ${node}: SSH works"
        else
            report FAIL "${first} -> ${node}: SSH does NOT work - 'pvecm add --use_ssh' will fail"
        fi
    done

    # Shared storage reachability
    local nfs_ip
    nfs_ip="$(state_get ".pve.nfs_server")"
    if [ -n "${nfs_ip}" ]; then
        if ssh_exec_q "${first_priv}" "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${nfs_ip}/2049' 2>/dev/null"; then
            report PASS "NFS server ${nfs_ip} is reachable on port 2049"
        else
            report FAIL "NFS server ${nfs_ip} is NOT reachable on port 2049"
        fi
    fi
}

debug_guests() {
    section "6. Guests"

    local node priv
    for node in $(lab_node_list); do
        priv="$(state_reach_ip "${node}")"
        ssh_exec_q "${priv}" "true" || continue

        local vmid name status
        for vmid in ${VM_WEB_ID} ${VM_TEMPLATE_ID} ${VM_CLONE_FULL_ID} ${VM_CLONE_LINKED_ID}; do
            name="$(ssh_exec "${priv}" "qm config ${vmid} 2>/dev/null | grep '^name:' | awk '{print \$2}'")"
            [ -n "${name}" ] || continue
            status="$(ssh_exec "${priv}" "qm status ${vmid} 2>/dev/null | awk '{print \$2}'")"
            if [ "${status}" = "running" ]; then
                report PASS "VM ${vmid} (${name}) is running"
            elif [ "${vmid}" = "${VM_TEMPLATE_ID}" ]; then
                report PASS "VM ${vmid} (${name}) is a template"
            else
                report WARN "VM ${vmid} (${name}) is ${status:-unknown}"
            fi
        done

        local ctid
        for ctid in ${CT_APP_ID} ${CT_DB_ID}; do
            name="$(ssh_exec "${priv}" "pct config ${ctid} 2>/dev/null | grep '^hostname:' | awk '{print \$2}'")"
            [ -n "${name}" ] || continue
            status="$(ssh_exec "${priv}" "pct status ${ctid} 2>/dev/null | awk '{print \$2}'")"
            if [ "${status}" = "running" ]; then
                report PASS "CT ${ctid} (${name}) is running"
            else
                report WARN "CT ${ctid} (${name}) is ${status:-unknown}"
            fi
        done
    done
}

main() {
    load_config
    mkdir -p "${LAB_LOG_DIR}"
    REPORT_FILE="${LAB_LOG_DIR}/debug-$(date +%Y%m%d-%H%M%S).log"

    print_banner "Proxmox VE seminar lab - diagnostics"
    printf 'Report: %s\n' "${REPORT_FILE}" >&2

    {
        printf 'Proxmox VE seminar lab diagnostics\n'
        printf 'Date    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'Region  : %s\n' "${AWS_REGION}"
        printf 'Cluster : %s\n' "${PVE_CLUSTER_NAME}"
        printf 'Phase   : %s\n' "$(state_get ".phase" "unknown")"
    } > "${REPORT_FILE}"

    debug_local || true
    debug_aws || true
    debug_reachability || true

    local node
    for node in $(lab_node_list); do
        if [ -n "${ONLY_NODE}" ] && [ "${node}" != "${ONLY_NODE}" ]; then
            continue
        fi
        debug_node "${node}"
    done

    if [ -z "${ONLY_NODE}" ]; then
        debug_cluster_connectivity || true
        if [ "${QUICK}" != "1" ]; then
            debug_guests || true
        fi
    fi

    section "Summary"
    printf '  %sPASS %s   %sWARN %s   %sFAIL %s\n' \
        "${C_GREEN}" "${PASS_COUNT}" "${C_YELLOW}" "${WARN_COUNT}" "${C_RED}" "${FAIL_COUNT}" >&2
    printf '  Full report: %s\n\n' "${REPORT_FILE}" >&2

    if [ "${SHOW_LOG}" = "1" ]; then
        cat "${REPORT_FILE}"
    fi

    [ "${FAIL_COUNT}" -eq 0 ] || exit 1
    exit 0
}

main "$@"
