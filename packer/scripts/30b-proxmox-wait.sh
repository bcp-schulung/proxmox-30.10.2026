#!/bin/bash
# =============================================================================
# 30b-proxmox-wait.sh - Packer build step: wait for the finalize step
# =============================================================================
#
# The finalize step is started by 30-pve-finalize.sh and runs detached on
# the instance. This step waits for the result.
#
# The step is repeated in the Packer template. A step that finds the work
# still running exits 0, so that Packer continues with the next one; only a
# genuine failure aborts the build.
# =============================================================================
set -uo pipefail

LOG="/var/log/pve-finalize.log"
MARKER="/var/log/pve-finalize.rc"
INTERVAL="${WAIT_INTERVAL:-90}"

echo "Waiting up to ${INTERVAL} seconds for the finalize step..."

deadline=$(( $(date +%s) + INTERVAL ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if sudo test -s "${MARKER}"; then
        rc="$(sudo cat "${MARKER}")"
        echo "--- the finalize step finished with exit status ${rc} ---"
        if [ "${rc}" != "0" ]; then
            echo "--- the last 40 lines of the log ---"
            sudo tail -40 "${LOG}" || true
            exit 1
        fi
        echo "FINALIZE-DONE"
        exit 0
    fi
    sleep 10
done

sudo tail -3 "${LOG}" 2>/dev/null || true
echo "The finalize step is still running - continuing."
exit 0
