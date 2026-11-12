#!/usr/bin/env bash
# =============================================================================
# reset.sh - put the lab back into its pre-exercise state
# =============================================================================
# The long exercise starts from three standalone Proxmox nodes. This script
# removes everything the exercise created and leaves the three nodes as
# standalone installations with their network already configured.
#
# What it removes:
#   * the HA groups and the HA resources
#   * the backup jobs
#   * the guests (the VMs and the containers)
#   * the API tokens, the users, the roles and the realms
#   * the storages (the definitions, not the data on the NFS/PBS servers)
#   * the firewall rules
#   * the cluster configuration (the nodes leave the cluster)
#
# What it keeps:
#   * the nodes, their hostnames, their /etc/hosts entries
#   * the network configuration (vmbr0, dnsmasq, the NAT rules)
#   * the LVM-thin pools on the data volumes
#   * the data on the NFS server and on the PBS datastore
#
# Usage:
#   ./reset.sh --all            reset everything
#   ./reset.sh --guests         only remove the guests
#   ./reset.sh --identity       only remove the users, roles and tokens
#   ./reset.sh --storage        only remove the storage definitions
#   ./reset.sh --cluster        only dissolve the cluster
#   ./reset.sh --dry-run        show what would happen
#   ./reset.sh --yes            do not ask for confirmation
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/exlib.sh
. "${EX_ROOT_DIR}/lib/exlib.sh"
# shellcheck source=../lib/scenario.sh
. "${EX_ROOT_DIR}/lib/scenario.sh"

RESET_GUESTS=0
RESET_IDENTITY=0
RESET_STORAGE=0
RESET_CLUSTER=0
RESET_FIREWALL=0
RESET_BACKUP=0
DRY_RUN=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --all)       RESET_GUESTS=1; RESET_IDENTITY=1; RESET_STORAGE=1
                     RESET_CLUSTER=1; RESET_FIREWALL=1; RESET_BACKUP=1
                     shift ;;
        --guests)    RESET_GUESTS=1; shift ;;
        --identity)  RESET_IDENTITY=1; shift ;;
        --storage)   RESET_STORAGE=1; shift ;;
        --cluster)   RESET_CLUSTER=1; shift ;;
        --firewall)  RESET_FIREWALL=1; shift ;;
        --backup)    RESET_BACKUP=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ "$((RESET_GUESTS + RESET_IDENTITY + RESET_STORAGE + RESET_CLUSTER + RESET_FIREWALL + RESET_BACKUP))" -eq 0 ]; then
    RESET_GUESTS=1; RESET_IDENTITY=1; RESET_STORAGE=1
    RESET_CLUSTER=1; RESET_FIREWALL=1; RESET_BACKUP=1
fi

printf '\n%s%s%s\n' "${EX_C_BOLD}" "======================================================================" "${EX_C_RESET}"
printf '%s  Resetting the lab to the pre-exercise state%s\n' "${EX_C_BOLD}" "${EX_C_RESET}"
printf '%s%s%s\n' "${EX_C_BOLD}" "======================================================================" "${EX_C_RESET}"

if [ "${DRY_RUN}" -eq 1 ]; then
    printf '%s[ DRY RUN ]%s nothing is changed. The plan:\n' "${EX_C_YELLOW}" "${EX_C_RESET}"
fi

# The transport. The script runs on a node or over SSH.
ex_detect_mode
case "${EX_MODE}" in
    local) printf 'Running against the local node (%s)\n' "$(ex_out hostname)" ;;
    ssh)   printf 'Running against %s over SSH\n' "${EX_SSH_HOST}" ;;
esac

if [ "${ASSUME_YES}" -ne 1 ] && [ "${DRY_RUN}" -ne 1 ]; then
    printf '\n%sThis removes the cluster configuration, the storages, the guests and the identities.%s\n' \
        "${EX_C_YELLOW}" "${EX_C_RESET}"
    printf 'The data on the NFS server and on the PBS datastore is NOT touched.\n'
    printf 'Continue? [y/N] '
    read -r answer || answer=""
    case "${answer}" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) printf 'Aborted.\n'; exit 0 ;;
    esac
fi

run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s  would run:%s %s\n' "${EX_C_DIM}" "${EX_C_RESET}" "$*"
        return 0
    fi
    "$@"
}

# =============================================================================
# 1. The guests
# =============================================================================
if [ "${RESET_GUESTS}" -eq 1 ]; then
    printf '\n%s--- The guests%s\n' "${EX_C_CYAN}" "${EX_C_RESET}"

    for vmid in ${NW_VM_IDS} ${NW_VM_TEMPLATE_ID} ${NW_VM_TEST_ID} 190; do
        if ex_out "qm config ${vmid}" | grep -q .; then
            printf '  removing VM %s\n' "${vmid}"
            run ex_run "qm destroy ${vmid} --purge 1 --destroy-unreferenced-disks 1" >/dev/null 2>&1
        fi
    done

    for ctid in ${NW_CT_IDS} 391; do
        if ex_out "pct config ${ctid}" | grep -q .; then
            printf '  removing CT %s\n' "${ctid}"
            run ex_run "pct destroy ${ctid}" >/dev/null 2>&1
        fi
    done

    # The restored guests of the backup exercise.
    for vmid in 190 191 192 193 194 195 196 197 198 199; do
        if ex_out "qm config ${vmid}" | grep -q .; then
            printf '  removing VM %s\n' "${vmid}"
            run ex_run "qm destroy ${vmid} --purge 1 --destroy-unreferenced-disks 1" >/dev/null 2>&1
        fi
    done
fi

# =============================================================================
# 2. The backup jobs
# =============================================================================
if [ "${RESET_BACKUP}" -eq 1 ]; then
    printf '\n%s--- The backup jobs%s\n' "${EX_C_CYAN}" "${EX_C_RESET}"

    jobs="$(ex_out "pvesh get /cluster/backup --output-format json 2>/dev/null" | jq -r '.[].id' 2>/dev/null)"
    for job in ${jobs}; do
        printf '  removing the backup job %s\n' "${job}"
        run ex_run "pvesh delete /cluster/backup/${job}" >/dev/null 2>&1
    done
fi

# =============================================================================
# 3. The HA resources and the groups
# =============================================================================
printf '\n%s--- The high availability%s\n' "${EX_C_CYAN}" "${EX_C_RESET}"

for res in vm:9201 vm:9202 vm:9203 ct:300 ct:301 ct:302; do
    if ex_out "ha-manager status --output-format json 2>/dev/null" | grep -q "\"${res}\""; then
        printf '  removing the HA resource %s\n' "${res}"
        run ex_run "ha-manager rm ${res}" >/dev/null 2>&1
    fi
done

if ex_out "ha-manager status --output-format json 2>/dev/null" | grep -q "prod-nodes"; then
    printf '  removing the HA group prod-nodes\n'
    run ex_run "ha-manager rm group prod-nodes" >/dev/null 2>&1
fi

# =============================================================================
# 4. The identities
# =============================================================================
if [ "${RESET_IDENTITY}" -eq 1 ]; then
    printf '\n%s--- The identities%s\n' "${EX_C_CYAN}" "${EX_C_RESET}"

    # The tokens first - a token belongs to a user.
    for token in terraform terraform-full; do
        if ex_out "pveum user token list ${NW_TOKEN_USER}" | grep -q "${token}"; then
            printf '  removing the token %s!%s\n' "${NW_TOKEN_USER}" "${token}"
            run ex_run "pveum user token delete ${NW_TOKEN_USER} ${token}" >/dev/null 2>&1
        fi
    done

    for user in "${NW_USER}" "${NW_TOKEN_USER}"; do
        if ex_out "pveum user list" | grep -qF "${user}"; then
            printf '  removing the user %s\n' "${user}"
            run ex_run "pveum user delete ${user}" >/dev/null 2>&1
        fi
    done

    for role in "${NW_ROLE}"; do
        if ex_out "pveum role list" | grep -qE "^${role} "; then
            printf '  removing the role %s\n' "${role}"
            run ex_run "pveum role delete ${role}" >/dev/null 2>&1
        fi
    done

    for realm in "${NW_REALM}"; do
        if ex_out "pveum realm list" | grep -qE "^${realm} "; then
            printf '  removing the realm %s\n' "${realm}"
            run ex_run "pveum realm delete ${realm}" >/dev/null 2>&1
        fi
    done
fi

# =============================================================================
# 5. The firewall rules
# =============================================================================
if [ "${RESET_FIREWALL}" -eq 1 ]; then
    printf '\n%s--- The firewall rules%s\n' "${EX_C_CYAN}" "${EX_C_RESET}"

    rules="$(ex_out "pvesh get /cluster/firewall/rules --output-format json 2>/dev/null" | jq -r '.[].pos' 2>/dev/null | sort -rn)"
    for pos in ${rules}; do
        printf '  removing the firewall rule %s\n' "${pos}"
        run ex_run "pvesh delete /cluster/firewall/rules/${pos}" >/dev/null 2>&1
    done

    # The guest level rules live in their own files.
    for f in /etc/pve/firewall/9201.fw /etc/pve/firewall/9202.fw /etc/pve/firewall/9203.fw \
             /etc/pve/firewall/300.fw /etc/pve/firewall/301.fw /etc/pve/firewall/302.fw; do
        if ex_out "test -f ${f}" | grep -q .; then
            printf '  removing %s\n' "${f}"
            run ex_run "rm -f ${f}" >/dev/null 2>&1
        fi
    done
fi

# =============================================================================
# 6. The storage definitions
# =============================================================================
if [ "${RESET_STORAGE}" -eq 1 ]; then
    printf '\n%s--- The storage definitions%s\n' "${EX_C_CYAN}" "${EX_C_RESET}"

    for sid in "${NW_STORAGE_SHARED}" "${NW_STORAGE_BACKUP}" "${NW_STORAGE_LOCAL}"; do
        if ex_out "pvesm status" | grep -qE "^${sid}"; then
            printf '  removing the storage %s\n' "${sid}"
            run ex_run "pvesm remove ${sid}" >/dev/null 2>&1
        fi
    done
fi

# =============================================================================
# 7. The cluster
# =============================================================================
if [ "${RESET_CLUSTER}" -eq 1 ]; then
    printf '\n%s--- The cluster%s\n' "${EX_C_CYAN}" "${EX_C_RESET}"

    members="$(ex_out "pvecm status 2>/dev/null" | grep -c '^[0-9]*:')"

    if [ "${members:-0}" -gt 0 ]; then
        # The last node leaves the cluster, the others leave afterwards.
        nodes="$(ex_out "pvecm nodes 2>/dev/null" | awk 'NR>1 && $3 ~ /^[0-9]+$/ {print $3}' | tr '\n' ' ')"
        local_name="$(ex_out hostname)"

        for n in ${nodes}; do
            [ "${n}" = "${local_name}" ] && continue
            printf '  removing %s from the cluster\n' "${n}"
            run ex_run "pvecm delnode ${n}" >/dev/null 2>&1
        done

        printf '  leaving the cluster on %s\n' "${local_name}"
        run ex_run "pvecm leave --force" >/dev/null 2>&1
    else
        printf '  the nodes are not clustered - nothing to do\n'
    fi
fi

printf '\n%s%s%s\n' "${EX_C_BOLD}" "----------------------------------------------------------------------" "${EX_C_RESET}"
if [ "${DRY_RUN}" -eq 1 ]; then
    printf '%sDry run - nothing was changed.%s\n' "${EX_C_YELLOW}" "${EX_C_RESET}"
else
    printf '%sThe lab is back in its pre-exercise state.%s\n' "${EX_C_GREEN}" "${EX_C_RESET}"
    printf '\nThe next step is to hand over the exercise:\n'
    printf '  1. Give the students the node addresses and the root password.\n'
    printf '  2. Give them the scenario: docs/SCENARIO.md\n'
    printf '  3. Let them work through long-exercise/nordwind-platform/requirements.md\n'
    printf '  4. Check the work with long-exercise/nordwind-platform/exercise.sh\n'
fi

exit 0
