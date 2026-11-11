#!/bin/bash
# =============================================================================
# lib-common.sh - shared helpers for the Packer build steps
# =============================================================================
#
# The build instance reaches the package mirrors over the internet, and the
# SSH connection occasionally drops during the long downloads. A plain apt
# invocation then aborts the whole 40 minute build.
#
# Two things prevent that:
#
#   apt_retry   - retries apt itself, resuming a partial download
#   run_detached - runs a long step in the background on the instance and
#                  polls for the result, so that an SSH drop does not kill
#                  the build. The step keeps running on the instance even
#                  when the connection drops, and the next poll picks up
#                  the result.
# =============================================================================

# apt_retry <apt-get arguments...>
apt_retry() {
    local attempt=1
    local max=5
    while [ "${attempt}" -le "${max}" ]; do
        echo "--- apt attempt ${attempt}/${max}: apt-get $* ---"
        if sudo apt-get -o Acquire::Retries=3 "$@"; then
            return 0
        fi
        echo "WARN: apt-get $* failed - retrying in 10 seconds"
        attempt=$((attempt + 1))
        sleep 10
    done
    echo "ERROR: apt-get $* failed after ${max} attempts"
    return 1
}

# run_detached <log-file> <marker-file> <command...>
#
# Runs the command on the instance in the background, with nohup and with
# the standard streams redirected to the log file. The command writes its
# exit status to the marker file when it is done.
#
# The caller then polls for the marker file. If the SSH connection drops
# during the wait, Packer aborts the provisioner - but the command itself
# is unaffected and keeps running. A following provisioner step finds the
# marker file and continues.
run_detached() {
    local log="$1" marker="$2"; shift 2

    rm -f "${marker}" "${log}"

    # The command and its arguments are passed through a here-document so
    # that no quoting is lost.
    {
        echo "set -x"
        echo "cd /"
        echo "$*"
        echo "rc=\$?"
        echo "printf '%s' \"\${rc}\" > '${marker}'"
    } > "/tmp/pve-detached-step.sh"

    sudo chmod +x /tmp/pve-detached-step.sh
    # The redirection has to go through sudo as well: the shell opens the
    # log file before sudo runs, and /var/log is not writable by the
    # ordinary user.
    sudo sh -c "nohup setsid /tmp/pve-detached-step.sh > '${log}' 2>&1 &"
    sleep 2
    echo "Started the step in the background, log: ${log}"
}

# wait_detached <marker-file> <log-file> [timeout-seconds]
#
# Polls for the marker file and shows the log. Returns the exit status
# that the detached step recorded.
wait_detached() {
    local marker="$1" log="$2" timeout="${3:-3600}"
    local deadline=$(( $(date +%s) + timeout ))
    local size=0

    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if [ -s "${marker}" ]; then
            local rc
            rc="$(cat "${marker}")"
            echo "--- the step finished with exit status ${rc} ---"
            if [ "${rc}" != "0" ]; then
                echo "--- the last 40 lines of ${log} ---"
                tail -40 "${log}" || true
                return 1
            fi
            return 0
        fi

        # Show the progress so that a long step is not silent.
        if [ -f "${log}" ]; then
            local newsize
            newsize="$(stat -c %s "${log}" 2>/dev/null || stat -f %z "${log}" 2>/dev/null || echo 0)"
            if [ "${newsize}" -gt "${size}" ]; then
                tail -3 "${log}" || true
                size="${newsize}"
            fi
        fi

        sleep 15
    done

    echo "ERROR: the step did not finish within ${timeout} seconds"
    tail -40 "${log}" || true
    return 1
}
