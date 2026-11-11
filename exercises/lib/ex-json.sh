#!/bin/bash
# =============================================================================
# ex-json.sh - read a JSON document from stdin and print a value
# =============================================================================
# Proxmox VE nodes do NOT have 'jq' installed. They do have python3.
#
# This script takes a jq-like filter on the command line and applies it to
# the JSON that arrives on stdin. When 'jq' is available it is used,
# otherwise the filter is applied by the python helper next to this file.
#
# Only the small set of filters that the exercises actually use is
# supported. See ex-json-filter.py for the list.
#
# Usage:
#   pvesh get /version --output-format json | ex-json.sh '.release'
#   pvesh get /cluster/resources --type vm --output-format json \
#       | ex-json.sh '.[] | select(.vmid == 100) | .node'
#
# Exit codes:
#   0   the filter produced output
#   1   the filter produced no output
#   2   the usage is wrong
# =============================================================================
set -u

FILTER="${1:-}"
[ -n "${FILTER}" ] || { echo "usage: ex-json.sh <filter>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# The jq path - used when jq is installed.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    jq -r "${FILTER}"
    exit $?
fi

# ---------------------------------------------------------------------------
# The python3 path.
#
# The python program is a separate file, NOT a heredoc. A heredoc would
# take over the standard input and the JSON would be lost.
# ---------------------------------------------------------------------------
FILTER="${FILTER}" exec python3 "${SCRIPT_DIR}/ex-json-filter.py" "${FILTER}"
