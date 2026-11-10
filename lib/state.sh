#!/usr/bin/env bash
# =============================================================================
# lib/state.sh - lab state persistence
# =============================================================================
# The state file (.state/lab.json) is the single source of truth for every
# resource this harness creates. All scripts read it to discover what exists
# and write to it as they go, so that the scripts are resumable and so that
# clean.sh can find resources without guessing.

if [ -n "${__LAB_STATE_SOURCED:-}" ]; then
    return 0
fi
__LAB_STATE_SOURCED=1

# shellcheck source=lib/common.sh
. "${LAB_LIB_DIR}/common.sh"

STATE_FILE="${LAB_STATE_DIR}/lab.json"

state_init() {
    mkdir -p "${LAB_STATE_DIR}"
    if [ ! -f "${STATE_FILE}" ]; then
        jq -n --arg version "${STATE_VERSION}" \
              --arg region "${AWS_REGION}" \
              --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '{version: ($version|tonumber),
                created: $created,
                region: $region,
                phase: "init",
                vpc: null, subnets: null, igw: null, natgw: null,
                sgs: null, amis: null, keypair: null,
                instances: {}, volumes: {}, guests: {}, pve: {}}' \
            > "${STATE_FILE}"
        chmod 600 "${STATE_FILE}"
        log_debug "Initialised state file ${STATE_FILE}"
    fi
}

state_exists() {
    [ -f "${STATE_FILE}" ]
}

state_get() {
    # state_get <dotted.path> [default]
    local path="$1"
    local default="${2:-}"
    if [ ! -f "${STATE_FILE}" ]; then
        printf '%s' "${default}"
        return 0
    fi
    local value
    value="$(jq -r "${path} // empty" "${STATE_FILE}" 2>/dev/null || true)"
    if [ -z "${value}" ] || [ "${value}" = "null" ]; then
        printf '%s' "${default}"
    else
        printf '%s' "${value}"
    fi
}

state_has() {
    # state_has <dotted.path> -> exit 0 when the path exists and is not null
    local path="$1"
    [ -f "${STATE_FILE}" ] || return 1
    jq -e "${path} != null" "${STATE_FILE}" >/dev/null 2>&1
}

# Convert a dotted path into a jq path array: "a.b.c" -> ["a","b","c"]
# The leading dot is a jq path prefix and is not part of the first key.
_path_to_jq_array() {
    local path="${1#.}"
    [ -z "${path}" ] && return 0
    printf '%s' "${path}" | awk -F. '{
        for (i = 1; i <= NF; i++) {
            printf "%s\"%s\"", (i > 1 ? "," : ""), $i
        }
    }'
}

state_set() {
    # state_set <dotted.path> <json-value>
    # The value is parsed as JSON, so pass numbers/quoted strings appropriately.
    local path="$1"
    local value="$2"
    [ -f "${STATE_FILE}" ] || state_init

    local array tmp
    array="$(_path_to_jq_array "${path}")"
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"

    if ! jq --argjson v "${value}" "setpath([${array}]; \$v)" "${STATE_FILE}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        log_error "Failed to set state path '${path}' to ${value}"
        return 1
    fi
    chmod 600 "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
}

state_merge() {
    # state_merge <json-object> - deep merge into the root of the state
    local patch="$1"
    [ -f "${STATE_FILE}" ] || state_init
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    if ! jq --argjson p "${patch}" '. * $p' "${STATE_FILE}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        log_error "Failed to merge state patch"
        return 1
    fi
    chmod 600 "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
}

state_del() {
    # state_del <dotted.path>
    local path="$1"
    [ -f "${STATE_FILE}" ] || return 0
    local array tmp
    array="$(_path_to_jq_array "${path}")"
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    if ! jq "delpaths([[${array}]])" "${STATE_FILE}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi
    chmod 600 "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
}

state_set_phase() {
    state_set ".phase" "\"$1\""
    log_debug "State phase -> ${1}"
}

# List the recorded PVE node names.
state_node_names() {
    if [ -f "${STATE_FILE}" ]; then
        jq -r '.instances | keys[]' "${STATE_FILE}" 2>/dev/null || true
    fi
}

# List the recorded instance names that belong to the Proxmox cluster.
state_pve_nodes() {
    if [ -f "${STATE_FILE}" ]; then
        jq -r '.instances | to_entries[] | select(.value.role == "pve") | .key' "${STATE_FILE}" 2>/dev/null || true
    fi
}

# List the recorded service instances (nfs, pbs).
state_service_instances() {
    if [ -f "${STATE_FILE}" ]; then
        jq -r '.instances | to_entries[] | select(.value.role != "pve") | .key' "${STATE_FILE}" 2>/dev/null || true
    fi
}

state_show() {
    [ -f "${STATE_FILE}" ] || { log_warn "No state file at ${STATE_FILE}"; return 1; }
    # Redact secrets before printing.
    jq 'walk(if type == "object" then
               with_entries(if (.key | test("password|secret|token"; "i")) then .value = "<redacted>" else . end)
           else . end)' "${STATE_FILE}"
}
