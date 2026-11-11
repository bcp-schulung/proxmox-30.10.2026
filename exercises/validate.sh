#!/usr/bin/env bash
# =============================================================================
# validate.sh - static check of the exercise tree
# =============================================================================
# Checks every exercise script for:
#   * shell syntax errors
#   * unbalanced quotes (the failure mode that hides in long scripts)
#   * the four mandatory parts in every exercise directory
#   * the exercise.sh being executable
#   * every topic referenced by the long exercise existing
#
# Run it from anywhere:
#   ./validate.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""; }

ERRORS=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf '%s[ OK ]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
fail() { CHECKS=$((CHECKS + 1)); ERRORS=$((ERRORS + 1)); printf '%s[FAIL]%s %s\n' "${RED}" "${RESET}" "$*"; }
warn() { CHECKS=$((CHECKS + 1)); printf '%s[NOTE]%s %s\n' "${YELLOW}" "${RESET}" "$*"; }

printf '%s%sValidating the exercise tree in %s%s\n' "${BOLD}" "${RESET}" "${SCRIPT_DIR}" "${RESET}"

# -----------------------------------------------------------------------------
# 1. Every exercise directory has the four parts
# -----------------------------------------------------------------------------
printf '\n%s== The four parts ==%s\n' "${BOLD}" "${RESET}"

REQUIRED="introduction.md requirements.md solution.md exercise.sh"

while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    missing=""
    for part in ${REQUIRED}; do
        [ -f "${dir}/${part}" ] || missing="${missing} ${part}"
    done
    if [ -z "${missing}" ]; then
        pass "$(basename "${dir}") has all four parts"
    else
        fail "$(basename "${dir}") is missing:${missing}"
    fi
done < <(find "${SCRIPT_DIR}" -mindepth 2 -maxdepth 2 -type d -not -path '*/lib*' -not -path '*/docs*' | sort)

# -----------------------------------------------------------------------------
# 2. Every exercise.sh is executable and parses
# -----------------------------------------------------------------------------
printf '\n%s== The scripts ==%s\n' "${BOLD}" "${RESET}"

while IFS= read -r script; do
    [ -n "${script}" ] || continue
    name="$(basename "$(dirname "${script}")")/$(basename "${script}")"

    if [ -x "${script}" ]; then
        pass "${name} is executable"
    else
        fail "${name} is not executable (chmod +x ${script})"
    fi

    if output="$(bash -n "${script}" 2>&1)"; then
        pass "${name} has valid shell syntax"
    else
        fail "${name} has a shell syntax error:"
        printf '        %s\n' "${output}"
    fi

    # Unbalanced quotes are the classic failure in a long script - they
    # often survive a visual review but break the moment the script is run.
    odd=$(awk '
        {
            s = $0
            gsub(/\\./, "", s)
            gsub(/'"'"'[^'"'"']*'"'"'/, "", s)
            n = gsub(/"/, "\"", s)
            if (n % 2 == 1) printf "%d\n", NR
        }
    ' "${script}" | tr '\n' ' ')

    if [ -z "${odd}" ]; then
        pass "${name} has balanced quotes"
    else
        fail "${name} has an unbalanced quote on line(s): ${odd}"
    fi

    # The script has to source the shared library.
    if grep -q "exlib.sh" "${script}"; then
        pass "${name} sources the shared library"
    else
        fail "${name} does not source lib/exlib.sh"
    fi

    # The classic trap: an 'awk {print $N}' inside a "$( ... )" ends the
    # substitution at the closing parenthesis of the awk program. The shell
    # parses it, but the result is wrong. Use cut or sed instead.
    if grep -qE "awk '\{print \\\$" "${script}"; then
        awklines="$(grep -nE "awk '\{print \\\$" "${script}" | head -3 | cut -d: -f1 | tr '\n' ' ')"
        fail "${name} uses awk {print \$N} inside a substitution (lines ${awklines}) - use cut -d' ' -fN"
    else
        pass "${name} avoids the awk-in-substitution trap"
    fi

    # The second trap: a closing parenthesis INSIDE the quoted argument of a
    # command substitution. 'x="$(ex_out "cmd grep '^x:')"' ends the
    # substitution at the ')' inside the quotes.
    if grep -qE '\$\(ex_(out|run) "[^"]*\)"$' "${script}"; then
        badlines="$(grep -nE '\$\(ex_(out|run) "[^"]*\)"$' "${script}" | cut -d: -f1 | tr '\n' ' ')"
        fail "${name} closes a substitution inside the quoted argument (lines ${badlines}) - move the ')' outside the quotes"
    else
        pass "${name} avoids the closed-substitution trap"
    fi

    # It has to end with a summary and an exit code.
    if grep -q "ex_summary" "${script}"; then
        pass "${name} ends with a summary"
    else
        fail "${name} does not call ex_summary"
    fi
done < <(find "${SCRIPT_DIR}" -name 'exercise.sh' -type f | sort)

# -----------------------------------------------------------------------------
# 3. The shared library parses
# -----------------------------------------------------------------------------
printf '\n%s== The shared library ==%s\n' "${BOLD}" "${RESET}"

for lib in "${SCRIPT_DIR}"/lib/*.sh; do
    [ -f "${lib}" ] || continue
    if bash -n "${lib}" 2>&1; then
        pass "$(basename "${lib}") has valid shell syntax"
    else
        fail "$(basename "${lib}") has a shell syntax error"
    fi
done

# -----------------------------------------------------------------------------
# 4. The long exercise references real topics
# -----------------------------------------------------------------------------
printf '\n%s== The long exercise ==%s\n' "${BOLD}" "${RESET}"

LONG="${SCRIPT_DIR}/long-exercise/nordwind-platform"

if [ -f "${LONG}/exercise.sh" ]; then
    # Every topic directory the long exercise mentions has to exist.
    refs="$(grep -oE '\.\./topics/[0-9a-z-]+/' "${LONG}/introduction.md" | sort -u)"
    missing=""
    for ref in ${refs}; do
        target="${SCRIPT_DIR}/topics/$(basename "${ref}")"
        [ -d "${target}" ] || missing="${missing} $(basename "${ref}")"
    done
    if [ -z "${missing}" ]; then
        pass "every topic referenced by the long exercise exists"
    else
        fail "the long exercise references missing topics:${missing}"
    fi
fi

# Every topic directory has to be mentioned by the long exercise.
while IFS= read -r topic; do
    [ -n "${topic}" ] || continue
    tname="$(basename "${topic}")"
    if grep -q "${tname}" "${LONG}/requirements.md" "${LONG}/introduction.md}" 2>/dev/null; then
        pass "the long exercise mentions ${tname}"
    else
        fail "the long exercise does not mention ${tname}"
    fi
done < <(find "${SCRIPT_DIR}/topics" -mindepth 1 -maxdepth 1 -type d | sort)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n%s%s%s\n' "${BOLD}" "----------------------------------------------------------------------" "${RESET}"
if [ "${ERRORS}" -eq 0 ]; then
    printf '%sAll %d checks passed.%s\n' "${GREEN}" "${CHECKS}" "${RESET}"
    exit 0
else
    printf '%s%d of %d checks failed.%s\n' "${RED}" "${ERRORS}" "${CHECKS}" "${RESET}"
    exit 1
fi
