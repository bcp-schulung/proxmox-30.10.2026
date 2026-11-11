#!/bin/bash
# =============================================================================
# 10b-proxmox-wait.sh - Packer build step: wait for the kernel install
# =============================================================================
#
# The Proxmox repository and the Proxmox kernel are installed by
# 10-proxmox-repo.sh, which starts the work detached on the instance. This
# step waits for the result.
#
# The SSH connection to the build instance drops regularly on this link, and
# Packer aborts a provisioner when the connection dies. The wait is
# therefore split into a series of identical steps, each covering a short
# interval. A step that finds the work still running exits 0, so that
# Packer continues with the next one; only a genuine failure aborts the
# build.
# =============================================================================
set -uo pipefail

LOG="/var/log/pve-kernel.log"
MARKER="/var/log/pve-kernel.rc"
INTERVAL="${WAIT_INTERVAL:-90}"

echo "Waiting up to ${INTERVAL} seconds for the Proxmox kernel install..."

deadline=$(( $(date +%s) + INTERVAL ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if sudo test -s "${MARKER}"; then
        rc="$(sudo cat "${MARKER}")"
        echo "--- the kernel step finished with exit status ${rc} ---"
        if [ "${rc}" != "0" ]; then
            echo "--- the last 40 lines of the install log ---"
            sudo tail -40 "${LOG}" || true
            exit 1
        fi
        echo "KERNEL-INSTALL-DONE"
        exit 0
    fi
    sleep 10
done

# The work is still running on the instance. The next wait step takes over.
sudo tail -3 "${LOG}" 2>/dev/null || true
echo "The kernel install is still running - continuing."
exit 0
