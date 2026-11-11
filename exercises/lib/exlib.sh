#!/usr/bin/env bash
# =============================================================================
# exlib.sh - shared helpers for the Proxmox VE seminar exercises
# =============================================================================
# Sourced by every exercise.sh. Provides:
#
#   * the exercise identity (EX_ID, EX_TITLE)
#   * a tiny assertion framework with PASS/FAIL/SKIP reporting
#   * a transport that works both on a cluster node and from a workstation
#   * helpers for the Nordwind Logistics scenario
#
# The script is designed to run in two places:
#
#   1. Directly on a cluster node (the normal case - "copy to pve1 and run").
#      It detects that it is on a Proxmox node and uses the local CLI.
#
#   2. From a workstation. It then needs to know how to reach the cluster.
#      The target is taken from EX_TARGET (default: pve1) and the transport
#      from EX_SSH_HOST / EX_SSH_KEY, or from the seminar lab harness in the
#      repository root (../../.state/lab.json).
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================

# Guard against double sourcing.
if [ -n "${__EXLIB_SOURCED:-}" ]; then
    return 0
fi
__EXLIB_SOURCED=1

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------
#
# The Proxmox host firewall on the lab nodes runs with 'policy_in: DROP'.
# A rule set that is written wrongly cuts SSH and the web UI off, and there
# is no way back except the serial console.
#
# The exercise scripts therefore only ever READ the firewall configuration.
# Writing it is part of the exercise, and the students do it by hand, with
# the ordering rules from the material:
#
#     1. write the rules first
#     2. switch the default deny on afterwards
#     3. keep a second session open while testing
#
# This guard makes sure that a future change to an exercise script cannot
# accidentally take the cluster offline. Any attempt to write a firewall
# configuration through the helper is refused.

ex_readonly_refusal() {
    printf '%s[REFUSED]%s %s\n' "${EX_C_RED}" "${EX_C_RESET}" "$*" >&2
    printf '%s         The exercise scripts never write the firewall configuration.%s\n' \
        "${EX_C_DIM}" "${EX_C_RESET}" >&2
    printf '%s         A wrong rule set with policy_in: DROP locks you out of the node.%s\n' \
        "${EX_C_DIM}" "${EX_C_RESET}" >&2
    printf '%s         Write the rules first, then the default deny, and keep a second SSH%s\n' \
        "${EX_C_DIM}" "${EX_C_RESET}" >&2
    printf '%s         session open while you test.%s\n' "${EX_C_DIM}" "${EX_C_RESET}" >&2
    return 1
}

# A firewall write helper that always refuses. It exists so that the
# intent is explicit if someone tries to add one later.
ex_firewall_write_refused() {
    ex_readonly_refusal "the firewall configuration cannot be written from here"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The exercise identity. Every exercise.sh sets these before sourcing, but the
# defaults keep the library usable on its own.
EX_ID="${EX_ID:-unknown}"
EX_TITLE="${EX_TITLE:-Proxmox VE exercise}"

# Where the cluster lives when the script runs from a workstation.
EX_TARGET="${EX_TARGET:-pve1}"
EX_SSH_HOST="${EX_SSH_HOST:-}"
EX_SSH_KEY="${EX_SSH_KEY:-}"

# The repository root, used to find the harness state file.
EX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${EX_LIB_DIR}/.." && pwd)"
EX_HARNESS_DIR="$(cd "${EX_ROOT_DIR}/.." && pwd)"

# The scenario. Nordwind Logistics - see docs/SCENARIO.md.
EX_COMPANY="${EX_COMPANY:-Nordwind Logistics}"
EX_DOMAIN="${EX_DOMAIN:-nordwind.example.com}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    EX_C_RESET=$'\033[0m'
    EX_C_BOLD=$'\033[1m'
    EX_C_DIM=$'\033[2m'
    EX_C_RED=$'\033[31m'
    EX_C_GREEN=$'\033[32m'
    EX_C_YELLOW=$'\033[33m'
    EX_C_BLUE=$'\033[34m'
    EX_C_CYAN=$'\033[36m'
else
    EX_C_RESET=""; EX_C_BOLD=""; EX_C_DIM=""
    EX_C_RED=""; EX_C_GREEN=""; EX_C_YELLOW=""; EX_C_BLUE=""; EX_C_CYAN=""
fi

EX_PASSED=0
EX_FAILED=0
EX_SKIPPED=0
EX_FAILURES=()

ex_banner() {
    printf '\n%s%s%s\n' "${EX_C_BOLD}" "======================================================================" "${EX_C_RESET}"
    printf '%s  %s%s\n' "${EX_C_BOLD}" "${EX_TITLE}" "${EX_C_RESET}"
    printf '%s  exercise: %s%s\n' "${EX_C_BOLD}" "${EX_ID}" "${EX_C_RESET}"
    printf '%s%s%s\n' "${EX_C_BOLD}" "======================================================================" "${EX_C_RESET}"
}

ex_section() {
    printf '\n%s--- %s%s\n' "${EX_C_CYAN}" "$*" "${EX_C_RESET}"
}

ex_info()    { printf '%s[ INFO ]%s %s\n' "${EX_C_BLUE}"   "${EX_C_RESET}" "$*"; }
ex_warn()    { printf '%s[ WARN ]%s %s\n' "${EX_C_YELLOW}" "${EX_C_RESET}" "$*"; }
ex_error()   { printf '%s[ERROR ]%s %s\n' "${EX_C_RED}"    "${EX_C_RESET}" "$*" >&2; }
ex_step()    { printf '%s  ->%s %s\n' "${EX_C_DIM}"     "${EX_C_RESET}" "$*"; }

ex_pass() {
    EX_PASSED=$((EX_PASSED + 1))
    printf '%s[ PASS ]%s %s\n' "${EX_C_GREEN}" "${EX_C_RESET}" "$*"
}

ex_fail() {
    EX_FAILED=$((EX_FAILED + 1))
    EX_FAILURES+=("$*")
    printf '%s[ FAIL ]%s %s\n' "${EX_C_RED}" "${EX_C_RESET}" "$*"
    if [ -n "${EX_FAIL_DETAIL:-}" ]; then
        printf '%s         %s%s\n' "${EX_C_DIM}" "${EX_FAIL_DETAIL}" "${EX_C_RESET}"
        EX_FAIL_DETAIL=""
    fi
}

ex_skip() {
    EX_SKIPPED=$((EX_SKIPPED + 1))
    printf '%s[ SKIP ]%s %s\n' "${EX_C_YELLOW}" "${EX_C_RESET}" "$*"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
#
# Each assertion takes a human readable description and a command. The command
# is evaluated with 'eval', so it can be any shell expression.

# ex_assert <description> <command...>
ex_assert() {
    local desc="$1"; shift
    local output rc
    output="$(eval "$*" 2>&1)"
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        ex_pass "${desc}"
    else
        EX_FAIL_DETAIL="command: ${*}"
        if [ -n "${output}" ]; then
            EX_FAIL_DETAIL="${EX_FAIL_DETAIL} | output: $(printf '%s' "${output}" | head -3 | tr '\n' ' ')"
        fi
        ex_fail "${desc}"
    fi
    return 0
}

# ex_assert_eq <description> <expected> <actual>
ex_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "${expected}" = "${actual}" ]; then
        ex_pass "${desc}"
    else
        EX_FAIL_DETAIL="expected '${expected}', got '${actual}'"
        ex_fail "${desc}"
    fi
    return 0
}

# ex_assert_contains <description> <haystack> <needle>
ex_assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "${haystack}" in
        *"${needle}"*) ex_pass "${desc}" ;;
        *)
            EX_FAIL_DETAIL="expected to contain '${needle}', got: $(printf '%s' "${haystack}" | head -3 | tr '\n' ' ')"
            ex_fail "${desc}"
            ;;
    esac
    return 0
}

# ex_assert_not_contains <description> <haystack> <needle>
ex_assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "${haystack}" in
        *"${needle}"*)
            EX_FAIL_DETAIL="expected NOT to contain '${needle}'"
            ex_fail "${desc}"
            ;;
        *) ex_pass "${desc}" ;;
    esac
    return 0
}

# ex_assert_empty <description> <value>
ex_assert_empty() {
    local desc="$1" value="$2"
    if [ -z "${value}" ]; then
        ex_pass "${desc}"
    else
        EX_FAIL_DETAIL="expected empty, got '${value}'"
        ex_fail "${desc}"
    fi
    return 0
}

# ex_assert_not_empty <description> <value>
ex_assert_not_empty() {
    local desc="$1" value="$2"
    if [ -n "${value}" ]; then
        ex_pass "${desc}"
    else
        EX_FAIL_DETAIL="expected a value, got nothing"
        ex_fail "${desc}"
    fi
    return 0
}

# A numeric comparison: ex_assert_ge <description> <actual> <minimum>
ex_assert_ge() {
    local desc="$1" actual="$2" minimum="$3"
    if [ "${actual}" -ge "${minimum}" ] 2>/dev/null; then
        ex_pass "${desc}"
    else
        EX_FAIL_DETAIL="expected >= ${minimum}, got '${actual}'"
        ex_fail "${desc}"
    fi
    return 0
}

# A numeric comparison: ex_assert_le <description> <actual> <maximum>
ex_assert_le() {
    local desc="$1" actual="$2" maximum="$3"
    if [ "${actual}" -le "${maximum}" ] 2>/dev/null; then
        ex_pass "${desc}"
    else
        EX_FAIL_DETAIL="expected <= ${maximum}, got '${actual}'"
        ex_fail "${desc}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------
#
# The exercise needs to talk to the cluster. On a cluster node the local CLI
# is used. From a workstation the commands are executed over SSH.
#
# The mode is detected once and cached in EX_MODE.

ex_detect_mode() {
    if [ -n "${EX_MODE:-}" ]; then
        return 0
    fi

    # Already inside the cluster?
    if [ -d /etc/pve ] && command -v pvesh >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
        EX_MODE="local"
        return 0
    fi

    # The harness state file knows the address of the node.
    local state="${EX_HARNESS_DIR}/.state/lab.json"
    if [ -z "${EX_SSH_HOST}" ] && [ -f "${state}" ] && command -v jq >/dev/null 2>&1; then
        local host
        host="$(jq -r --arg n "${EX_TARGET}" \
            '.instances[$n].ssh_host // .instances[$n].reach_ip // .instances[$n].public_ip // empty' \
            "${state}" 2>/dev/null || true)"
        [ -n "${host}" ] && EX_SSH_HOST="${host}"
    fi

    if [ -z "${EX_SSH_HOST}" ] && command -v pvesh >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
        EX_MODE="local"
        return 0
    fi

    EX_MODE="ssh"
}

# The path of the JSON helper, as the TARGET sees it.
#
# In local mode the file is where it is in the repository. In SSH mode the
# node has its own copy in /opt/exercises, and the command runs THERE -
# so the path has to be the one of the node, not the one of the
# workstation.
EX_JSON_CMD=""

ex_set_json_cmd() {
    if [ "${EX_MODE}" = "local" ]; then
        EX_JSON_CMD="${EX_LIB_DIR}/ex-json.sh"
    else
        EX_JSON_CMD="/opt/exercises/lib/ex-json.sh"
    fi
}
# Run a command against the cluster. stdout and stderr are captured.
#
#   ex_run <command string>
#
# The command string is passed to a shell on the target, so pipes and
# redirections work.
ex_run() {
    local cmd="$1"

    ex_detect_mode
    ex_set_json_cmd
    ex_set_members_cmd

    if [ "${EX_MODE}" = "local" ]; then
        bash -c "${cmd}" 2>&1
        return $?
    fi

    local opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes)
    if [ -n "${EX_SSH_KEY}" ] && [ -f "${EX_SSH_KEY}" ]; then
        opts+=(-i "${EX_SSH_KEY}")
    fi

    # shellcheck disable=SC2029
    ssh "${opts[@]}" "${EX_SSH_USER:-root}@${EX_SSH_HOST}" "bash -c $(printf '%q' "${cmd}")" 2>&1
}

# Run a command and return only its stdout (stderr is dropped).
ex_out() {
    ex_run "$1" 2>/dev/null
}

# A quiet variant that only reports success or failure.
ex_ok() {
    ex_run "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Cluster shortcuts
# ---------------------------------------------------------------------------

# The node names in the cluster.
#
# 'pvecm nodes' prints a table like this:
#
#     Membership information
#     ----------------------
#         Nodeid      Votes Name
#              1          1 pve1 (local)
#              2          1 pve2
#
# The name is the third field, and the local node carries a ' (local)'
# suffix that has to be stripped.
ex_nodes() {
    ex_out "pvecm nodes 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]*([a-zA-Z0-9._-]*).*/\1/p' | sort"
}

# The number of cluster members.
#
# 'pvecm status' prints the members with their ADDRESS, 'pvecm nodes'
# prints them with their NAME. The name is what the exercises work with,
# so the count comes from 'pvecm nodes'.
ex_member_count() {
    local n
    n="$(ex_out "pvecm nodes 2>/dev/null | grep -cE '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[a-zA-Z0-9._-]+'")"
    printf '%s' "${n:-0}"
}

# Is the cluster quorate? "yes" / "no" / "unknown"
ex_quorate() {
    local q
    q="$(ex_out "pvecm status 2>/dev/null | grep -i 'Flags:' | head -1")"
    case "${q}" in
        *Quorate*) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}

# The quorum value. Empty when it cannot be read.
ex_quorum() {
    ex_out "pvecm status 2>/dev/null | sed -nE 's/^[[:space:]]*Quorum:[[:space:]]*([0-9]+).*/\1/p' | head -1"
}

# The name of the cluster.
ex_cluster_name() {
    ex_out "pvecm status 2>/dev/null | sed -nE 's/^[[:space:]]*Name:[[:space:]]*([^[:space:]]*).*/\1/p' | head -1"
}

# The management interface of the node. It is not always called 'eth0' -
# on the Proxmox installer and on the AWS images it is often 'enp39s0'.
ex_mgmt_if() {
    local dev
    dev="$(ex_out "ip -o route show default 2>/dev/null | cut -d' ' -f5 | head -1")"
    if [ -z "${dev}" ]; then
        dev="$(ex_out "ip -o route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9._-]+' | cut -d' ' -f2 | head -1")"
    fi
    printf '%s' "${dev}"
}

# The guest bridge.
ex_bridge() {
    ex_out "ip -o link show type bridge 2>/dev/null | cut -d' ' -f2 | tr -d ':' | head -1"
}

# Is the cluster filesystem a pmxcfs mount? The 'stat -f' output depends
# on the kernel: 'fuse.pmxcfs' on some, plain 'fuse' on others.
ex_is_pmxcfs() {
    local t
    t="$(ex_out "stat -f -c '%T' /etc/pve 2>/dev/null")"
    case "${t}" in
        *pmxcfs*|*fuse*) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}

# ---------------------------------------------------------------------------
# The other cluster members
# ---------------------------------------------------------------------------
#
# The exercises regularly need to look at the OTHER nodes - to check that a
# file is visible on them, or to compare their network configuration.
#
# The work is done by 'lib/ex-members.sh', which is installed next to this
# library. Keeping the loop in a separate script avoids the deep quoting
# that an inline version needs, and it makes the logic readable.
#
# The path of the helper script. It sits next to this library, both on the
# node and in the repository.
EX_MEMBERS_SCRIPT="${EX_LIB_DIR}/ex-members.sh"

# The path of the helper script, as the TARGET sees it.
EX_MEMBERS_CMD=""

ex_set_members_cmd() {
    if [ "${EX_MODE}" = "local" ]; then
        EX_MEMBERS_CMD="${EX_LIB_DIR}/ex-members.sh"
    else
        EX_MEMBERS_CMD="/opt/exercises/lib/ex-members.sh"
    fi
}

# ex_remote_members runs a command on every other member and prints the
# output.
ex_remote_members() {
    local cmd="$1"
    ex_run "$(printf '%q' "${EX_MEMBERS_CMD}") $(printf '%q' "${cmd}")" 2>/dev/null
}

# The name of the first other member, or an empty string.
ex_other_member() {
    ex_run "$(printf '%q' "${EX_MEMBERS_CMD}") --names-only" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------
#
# A Proxmox node does NOT have 'jq' installed. It does have python3.
# 'lib/ex-json.sh' applies a small jq-like filter to a JSON document that
# arrives on the standard input. It uses 'jq' when it is available, and
# the python helper otherwise.
#
# ex_json takes the filter as the first argument and the JSON on the
# standard input. It runs the whole thing on the node, so the JSON never
# has to travel over the SSH connection.
ex_json() {
    local filter="$1"
    ex_run "$(printf '%q' "${EX_JSON_CMD}") $(printf '%q' "${filter}")" 2>/dev/null
}

# The path of the JSON helper in the repository.
EX_JSON_SCRIPT="${EX_LIB_DIR}/ex-json.sh"

# The node a guest runs on. Empty when the guest does not exist.
#
# 'pvesh get /cluster/resources --type' only knows 'vm', 'storage', 'node'
# and 'sdn'. A container is a 'vm' resource too - it is distinguished by
# its 'type' field, which is 'lxc' for a container and 'qemu' for a VM.
ex_guest_node() {
    local kind="$1" id="$2"
    if [ "${kind}" = "vm" ]; then
        ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
            | jq -r --argjson id ${id} '.[] | select(.vmid==\$id and .type==\"qemu\") | .node' 2>/dev/null | head -1"
    else
        ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
            | jq -r --argjson id ${id} '.[] | select(.vmid==\$id and .type==\"lxc\") | .node' 2>/dev/null | head -1"
    fi
}

# The number of guests of a kind on the cluster.
ex_guest_count() {
    local kind="$1"
    if [ "${kind}" = "vm" ]; then
        ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
            | jq -r '[.[] | select(.type==\"qemu\")] | length' 2>/dev/null"
    else
        ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
            | jq -r '[.[] | select(.type==\"lxc\")] | length' 2>/dev/null"
    fi
}

# The status of a guest: running / stopped / unknown
ex_guest_status() {
    local kind="$1" id="$2"
    local out
    if [ "${kind}" = "vm" ]; then
        out="$(ex_out "qm status ${id} 2>/dev/null")"
    else
        out="$(ex_out "pct status ${id} 2>/dev/null")"
    fi
    case "${out}" in
        *running*)  printf 'running' ;;
        *stopped*)  printf 'stopped' ;;
        *)          printf 'unknown' ;;
    esac
}

# The configuration of a guest.
ex_vm_config()  { ex_out "qm config ${1} 2>/dev/null"; }
ex_ct_config()  { ex_out "pct config ${1} 2>/dev/null"; }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

ex_summary() {
    printf '\n%s%s%s\n' "${EX_C_BOLD}" "----------------------------------------------------------------------" "${EX_C_RESET}"
    printf '%sResult%s  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
        "${EX_C_BOLD}" "${EX_C_RESET}" \
        "${EX_C_GREEN}" "${EX_PASSED}" "${EX_C_RESET}" \
        "${EX_C_RED}"   "${EX_FAILED}" "${EX_C_RESET}" \
        "${EX_C_YELLOW}" "${EX_SKIPPED}" "${EX_C_RESET}"

    if [ "${EX_FAILED}" -gt 0 ]; then
        printf '\n%sFailed checks:%s\n' "${EX_C_RED}" "${EX_C_RESET}"
        local f
        for f in "${EX_FAILURES[@]}"; do
            printf '  - %s\n' "${f}"
        done
        printf '\n%sThe exercise is NOT complete.%s See solution.md for the expected result.\n' \
            "${EX_C_RED}" "${EX_C_RESET}"
        return 1
    fi

    printf '\n%sAll checks passed - the exercise is complete.%s\n' "${EX_C_GREEN}" "${EX_C_RESET}"
    return 0
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

EX_VERBOSE=0
EX_SECTION_FILTER=""

ex_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--verbose)
                EX_VERBOSE=1
                shift
                ;;
            -s|--section)
                EX_SECTION_FILTER="$2"
                shift 2
                ;;
            -h|--help)
                ex_usage
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
}

ex_usage() {
    cat << EOF
${EX_TITLE}

Usage: $(basename "$0") [options]

Options:
  -v, --verbose        show the output of every check
  -s, --section <s>    only run the checks of a section (substring match)
  -h, --help           this text

The script runs against the cluster. It uses the local Proxmox CLI when it is
started on a cluster node, and SSH otherwise. The target can be changed with
the EX_TARGET, EX_SSH_HOST, EX_SSH_KEY and EX_SSH_USER environment variables.

Exit code 0 = every check passed.
EOF
}

# Should the current section run? Honours --section.
ex_section_selected() {
    local section="$1"
    if [ -z "${EX_SECTION_FILTER}" ]; then
        return 0
    fi
    case "${section}" in
        *"${EX_SECTION_FILTER}"*) return 0 ;;
        *) return 1 ;;
    esac
}
