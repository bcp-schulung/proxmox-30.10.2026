#!/usr/bin/env bash
# =============================================================================
# lib/common.sh - shared helpers: logging, error handling, process control
# =============================================================================
# Sourced by provision.sh, debug.sh, shutdown.sh and clean.sh.
# Targets bash 3.2 (macOS default) - no associative arrays, no mapfile.
# =============================================================================

if [ -n "${__LAB_COMMON_SOURCED:-}" ]; then
    return 0
fi
__LAB_COMMON_SOURCED=1

# --- Paths -------------------------------------------------------------------
LAB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT_DIR="$(cd "${LAB_LIB_DIR}/.." && pwd)"
export LAB_LIB_DIR LAB_ROOT_DIR
export LAB_CONFIG_DIR="${LAB_ROOT_DIR}/config"
export LAB_STATE_DIR="${LAB_ROOT_DIR}/.state"
export LAB_LOG_DIR="${LAB_ROOT_DIR}/logs"

# --- Colors (disabled when not a TTY or NO_COLOR is set) ----------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'

    C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

# --- Logging -----------------------------------------------------------------
#
# All log output goes to stderr. That matters: many helpers return a value
# through stdout and are used as `value="$(helper)"`. If the helper also
# logged to stdout, the log text would end up inside the captured value.
log_info()    { printf '%s[ INFO ]%s %s\n'    "${C_BLUE}"   "${C_RESET}" "$*" >&2; }
log_ok()      { printf '%s[  OK  ]%s %s\n'    "${C_GREEN}"  "${C_RESET}" "$*" >&2; }
log_warn()    { printf '%s[ WARN ]%s %s\n'    "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_error()   { printf '%s[ERROR ]%s %s\n'    "${C_RED}"    "${C_RESET}" "$*" >&2; }
log_debug()   { [ -n "${LAB_DEBUG:-}" ] && printf '%s[DEBUG ]%s %s\n' "${C_DIM}" "${C_RESET}" "$*" >&2 || true; }
log_step()    { printf '\n%s%s==> %s%s\n' "${C_BOLD}" "${C_CYAN}" "$*" "${C_RESET}" >&2; }
log_substep() { printf '    %s->%s %s\n' "${C_DIM}" "${C_RESET}" "$*" >&2; }
log_section() { printf '\n%s%s%s\n' "${C_BOLD}" "----------------------------------------------------------------------" "${C_RESET}" >&2; }

die() {
    log_error "$*"
    exit 1
}

# --- Error trap --------------------------------------------------------------
# Prints the failing line and command, then exits. Keeps output readable by
# filtering out the trap frame itself.
on_error() {
    local exit_code=$?
    local line=$1
    local cmd=$2
    printf '\n%s[ERROR ]%s Command failed (exit %s) at line %s\n' \
        "${C_RED}" "${C_RESET}" "${exit_code}" "${line}" >&2
    printf '%s         %s%s\n' "${C_DIM}" "${cmd}" "${C_RESET}" >&2
    exit "${exit_code}"
}

enable_error_trap() {
    set -Eeuo pipefail
    trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
}

# --- Prompts -----------------------------------------------------------------
# confirm <question> [yes|no] - default answer when the second arg is omitted
confirm() {
    local question="$1"
    local default="${2:-no}"
    local answer

    if [ ! -t 0 ]; then
        [ "${default}" = "yes" ] && return 0 || return 1
    fi

    if [ "${default}" = "yes" ]; then
        printf '%s [Y/n] %s' "${question}" ""
    else
        printf '%s [y/N] %s' "${question}" ""
    fi

    read -r answer || answer=""
    case "${answer}" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        [Nn]|[Nn][Oo]|"")   return 1 ;;
        *) printf '%sPlease answer y or n.%s\n' "${C_YELLOW}" "${C_RESET}" >&2; return 1 ;;
    esac
}

# --- Misc helpers ------------------------------------------------------------

# Require an external command to be present.
require_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        if [ -n "${hint}" ]; then
            die "Required command '${cmd}' not found. ${hint}"
        fi
        die "Required command '${cmd}' not found. Install it and re-run."
    fi
}

# Run a command, echo it first (unless LAB_QUIET is set), abort on failure.
run() {
    if [ -z "${LAB_QUIET:-}" ]; then
        printf '%s  $%s %s\n' "${C_DIM}" "${C_RESET}" "$*"
    fi
    "$@"
}

# Run a command but never abort the script on failure; returns its exit code.
try_run() {
    if [ -z "${LAB_QUIET:-}" ]; then
        printf '%s  $%s %s\n' "${C_DIM}" "${C_RESET}" "$*"
    fi
    "$@" || return $?
}

# retry <attempts> <sleep_seconds> <command...>
retry() {
    local attempts="$1"; shift
    local delay="$1"; shift
    local n=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "${n}" -ge "${attempts}" ]; then
            return 1
        fi
        log_warn "Command failed (attempt ${n}/${attempts}): $* - retrying in ${delay}s"
        n=$((n + 1))
        sleep "${delay}"
    done
}

# Wait until a TCP port on a host is reachable. wait_tcp <host> <port> <timeout>
wait_tcp() {
    local host="$1" port="$2" timeout="${3:-60}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
            exec 3<&- 2>/dev/null || true
            exec 3>&- 2>/dev/null || true
            return 0
        fi
        sleep 2
    done
    return 1
}

# Generate a random password that satisfies Proxmox's complexity requirements.
gen_password() {
    local length="${1:-24}"
    LC_ALL=C tr -dc 'A-Za-z0-9!@%_=+' < /dev/urandom | head -c "${length}" || true
    echo
}

# URL-encode a string (used for AWS API query parameters).
urlencode() {
    local string="$1"
    local encoded=""
    local i=0 char

    while [ "${i}" -lt "${#string}" ]; do
        char="${string:${i}:1}"
        case "${char}" in
            [a-zA-Z0-9.~_-]) encoded="${encoded}${char}" ;;
            *)
                # printf %d of a quoted character yields its byte value.
                printf -v char '%%%02X' "'${char}"
                encoded="${encoded}${char}"
                ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "${encoded}"
}

# Format a duration in seconds as a human readable string.
human_duration() {
    local seconds="$1"
    if [ "${seconds}" -lt 60 ]; then
        printf '%ss' "${seconds}"
    elif [ "${seconds}" -lt 3600 ]; then
        printf '%sm %ss' $((seconds / 60)) $((seconds % 60))
    else
        printf '%sh %sm' $((seconds / 3600)) $(((seconds % 3600) / 60))
    fi
}

# Print a boxed summary header.
print_banner() {
    printf '\n%s%s%s\n' "${C_BOLD}" "======================================================================" "${C_RESET}" >&2
    printf '%s  %s%s\n' "${C_BOLD}" "$*" "${C_RESET}" >&2
    printf '%s%s%s\n\n' "${C_BOLD}" "======================================================================" "${C_RESET}" >&2
}

# ---------------------------------------------------------------------------
# The destruction guard
# ---------------------------------------------------------------------------
# Nothing in this harness destroys a guest, a volume or an instance without
# asking first. The seminar lab holds the exercises that are built on top
# of it, and an accidental "clean up" would throw away hours of work.
#
# The guard is deliberately stronger than a yes/no question:
#
#   * it lists what is about to be destroyed
#   * it asks for a typed phrase, so that a stray keystroke cannot
#     confirm it
#   * a non-interactive shell (a script, a CI job) is always refused,
#     because nobody can answer the question
#
# The only way past the guard is the environment variable
# LAB_DESTROY_CONFIRM, which holds the same phrase. It exists for the
# rare case that the teardown has to run unattended.
# ---------------------------------------------------------------------------

# LAB_CONFIRM_DESTRUCTION <phrase> <question> <what will be destroyed>
#
# Returns 0 when the destruction may proceed.
lab_confirm_destruction() {
    local phrase="$1" question="$2" what="$3"
    local answer

    # The escape hatch for an unattended teardown.
    if [ "${LAB_DESTROY_CONFIRM:-}" = "${phrase}" ]; then
        log_warn "The destruction was confirmed through LAB_DESTROY_CONFIRM."
        return 0
    fi

    if [ ! -t 0 ]; then
        log_error "This is not an interactive shell - the destruction cannot be confirmed."
        log_error "Type the phrase '${phrase}' in the terminal, or set LAB_DESTROY_CONFIRM='${phrase}'."
        return 1
    fi

    log_warn ""
    log_warn "The following will be DESTROYED:"
    printf '%s\n' "${what}" | sed 's/^/    /' >&2
    log_warn ""

    printf '%s' "${question}" >&2
    printf "Type '%s' to confirm: " "${phrase}" >&2
    read -r answer || answer=""

    if [ "${answer}" != "${phrase}" ]; then
        return 1
    fi

    return 0
}

# The phrase for the different kinds of destruction.
LAB_CONFIRM_PHRASE_CLUSTER="destroy the guests"
LAB_CONFIRM_PHRASE_AWS="destroy the lab"
