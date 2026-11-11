#!/usr/bin/env bash
# =============================================================================
# deploy.sh - install the exercise material onto the lab nodes
# =============================================================================
# Copies the exercise tree to every Proxmox node so that the students can
# work on the nodes themselves:
#
#   /opt/exercises/
#   ├── lib/
#   ├── docs/
#   ├── topics/<20 topic directories>/
#   ├── long-exercise/nordwind-platform/
#   └── validate.sh
#
# The script can run from the operator workstation or from a node.
#
# Usage:
#   ./deploy.sh                 deploy to all cluster nodes
#   ./deploy.sh --node pve1     deploy to one node
#   ./deploy.sh --remove        remove the material from all nodes
#   ./deploy.sh --list          show what is on each node
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The exercise tree is the directory this script lives in.
EX_ROOT_DIR="${SCRIPT_DIR}"
# The lab harness is the repository root, one level above.
HARNESS_DIR="$(cd "${EX_ROOT_DIR}/.." && pwd)"

# shellcheck source=../lib/exlib.sh
. "${EX_ROOT_DIR}/lib/exlib.sh"

TARGET_DIR="/opt/exercises"
MODE="deploy"
ONLY_NODE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --node)    ONLY_NODE="$2"; shift 2 ;;
        --remove)  MODE="remove"; shift ;;
        --list)    MODE="list"; shift ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# The lab harness. Its libraries expect common.sh to be sourced first,
# because that is where LAB_LIB_DIR and LAB_ROOT_DIR are set.
if [ -f "${HARNESS_DIR}/lib/ssh.sh" ]; then
    # shellcheck source=../lib/common.sh
    . "${HARNESS_DIR}/lib/common.sh"
    # shellcheck source=../lib/config.sh
    . "${HARNESS_DIR}/lib/config.sh"
    # shellcheck source=../lib/state.sh
    . "${HARNESS_DIR}/lib/state.sh"
    # shellcheck source=../lib/ssh.sh
    . "${HARNESS_DIR}/lib/ssh.sh"
    load_config >/dev/null 2>&1 || true
fi

# The nodes to deploy to.
lab_nodes() {
    if [ -n "${ONLY_NODE}" ]; then
        printf '%s\n' "${ONLY_NODE}"
        return 0
    fi
    if [ -f "${HARNESS_DIR}/.state/lab.json" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.instances | to_entries[] | select(.value.role == "pve") | .key' \
            "${HARNESS_DIR}/.state/lab.json" 2>/dev/null
        return 0
    fi
    # Fall back to the cluster members.
    pvecm nodes 2>/dev/null | awk 'NR>1 && $3 ~ /^[0-9]+$/ {print $3}'
}

# The address of a node, and the user to reach it with.
node_target() {
    local node="$1" host user

    if [ -f "${HARNESS_DIR}/.state/lab.json" ] && command -v jq >/dev/null 2>&1; then
        host="$(jq -r --arg n "${node}" \
            '.instances[$n].ssh_host // .instances[$n].reach_ip // .instances[$n].public_ip // empty' \
            "${HARNESS_DIR}/.state/lab.json" 2>/dev/null)"
    fi

    if [ -z "${host}" ]; then
        host="${node}"
    fi

    # The lab's SSH user is 'admin' - the Proxmox root account has no key
    # installed, because the Debian cloud image logs in as 'admin' and
    # cloud-init does not put a key into root's authorized_keys.
    user="${EX_SSH_USER:-${SSH_USER:-admin}}"

    printf '%s@%s' "${user}" "${host}"
}

# The SSH options. The harness builds them; they carry the key and the
# host key policy that a fresh node needs.
ssh_opts() {
    if command -v ssh_options >/dev/null 2>&1; then
        ssh_options
        return 0
    fi
    printf '%s\n' "-i" "${EX_SSH_KEY:-${PVE_SSH_KEY_PATH:-${HARNESS_DIR}/.state/keys/pve-lab.pem}}" \
        "-o" "StrictHostKeyChecking=no" \
        "-o" "UserKnownHostsFile=/dev/null" \
        "-o" "LogLevel=ERROR" \
        "-o" "ConnectTimeout=15" \
        "-o" "BatchMode=yes"
}

deploy_to() {
    local node="$1"
    local target
    target="$(node_target "${node}")"

    printf '\n%s--- %s%s\n' "${EX_C_CYAN}" "${node}" "${EX_C_RESET}"

    case "${MODE}" in
        remove)
            ssh $(ssh_opts) "${target}" "sudo rm -rf ${TARGET_DIR}" 2>/dev/null \
                && printf '  removed %s\n' "${TARGET_DIR}" \
                || printf '  could not reach %s\n' "${target}"
            ;;
        list)
            ssh $(ssh_opts) "${target}" "ls -1 ${TARGET_DIR} 2>/dev/null" 2>/dev/null \
                | sed 's/^/  /' \
                || printf '  could not reach %s\n' "${target}"
            ;;
        deploy)
            # The archive is streamed over SSH and unpacked on the node.
            #
            # macOS adds extended attribute headers to every file, and the
            # GNU tar on the node warns about each of them. That floods the
            # output and buries the result. The archive is therefore built
            # without the extended attributes.
            COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "${EX_ROOT_DIR}" . 2>/dev/null | \
                ssh $(ssh_opts) "${target}" "sudo mkdir -p ${TARGET_DIR} && sudo tar -xzf - -C ${TARGET_DIR} && \
                    sudo chmod +x ${TARGET_DIR}/validate.sh ${TARGET_DIR}/deploy.sh \
                                 ${TARGET_DIR}/lib/ex-members.sh \
                                 ${TARGET_DIR}/lib/ex-json.sh \
                                 ${TARGET_DIR}/lib/ex-json-filter.py \
                                 ${TARGET_DIR}/long-exercise/nordwind-platform/*.sh \
                                 ${TARGET_DIR}/topics/*/exercise.sh && \
                    sudo chown -R root:root ${TARGET_DIR} && \
                    echo OK" 2>/dev/null \
                | sed 's/^/  /'
            ;;
    esac
}

printf '\n%s%s%s\n' "${EX_C_BOLD}" "======================================================================" "${EX_C_RESET}"
printf '%s  Deploying the exercise material to %s%s\n' "${EX_C_BOLD}" "${TARGET_DIR}" "${EX_C_RESET}"
printf '%s%s%s\n' "${EX_C_BOLD}" "======================================================================" "${EX_C_RESET}"

nodes="$(lab_nodes)"
if [ -z "${nodes}" ]; then
    printf '%sNo nodes found.%s\n' "${EX_C_RED}" "${EX_C_RESET}"
    printf 'Run this from the repository root, or pass --node <name>.\n'
    exit 1
fi

for node in ${nodes}; do
    deploy_to "${node}"
done

printf '\n'
case "${MODE}" in
    remove) printf '%sThe material has been removed from the nodes.%s\n' "${EX_C_GREEN}" "${EX_C_RESET}" ;;
    list)   printf '%sDone.%s\n' "${EX_C_GREEN}" "${EX_C_RESET}" ;;
    deploy)
        printf '%sThe exercise material is installed on the nodes.%s\n' "${EX_C_GREEN}" "${EX_C_RESET}"
        printf '\nOn the node, the students work with:\n'
        printf '  cd %s\n' "${TARGET_DIR}"
        printf '  ./validate.sh                              # the whole tree\n'
        printf '  ./topics/03-cluster-formation/exercise.sh   # one topic\n'
        printf '  ./long-exercise/nordwind-platform/exercise.sh  # the acceptance test\n'
        ;;
esac

exit 0
