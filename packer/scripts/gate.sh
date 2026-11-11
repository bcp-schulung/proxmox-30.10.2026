#!/bin/bash
# =============================================================================
# gate.sh - Packer build step: verify that a detached step finished
# =============================================================================
#
# The wait steps only report progress - they exit with 0 while the work is
# still running, so that a dropped SSH connection does not abort the build.
# This gate runs after the last wait step and fails the build when the work
# really did not finish.
#
# Usage: gate.sh <marker-file> <log-file>
# =============================================================================
set -uo pipefail

MARKER="$1"
LOG="$2"

if sudo test -s "${MARKER}"; then
    rc="$(sudo cat "${MARKER}")"
    if [ "${rc}" = "0" ]; then
        echo "OK: ${MARKER} reports success"
        exit 0
    fi
    echo "ERROR: ${MARKER} reports exit status ${rc}"
    sudo tail -40 "${LOG}" || true
    exit 1
fi

echo "ERROR: ${MARKER} is missing - the detached work did not finish"
sudo tail -40 "${LOG}" || true
exit 1
