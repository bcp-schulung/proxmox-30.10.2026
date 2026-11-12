#!/bin/bash
# =============================================================================
# lab-detached.sh - run a long command detached from the SSH session
# =============================================================================
# Usage: lab-detached.sh <logfile> <command-file>
#
# A long operation - the import of a guest image, a clone of a disk over
# NFS - outlives the SSH connection that started it. When the connection
# drops, the process is killed with it and the operation stops halfway:
# the volume exists, but it is only partly written.
#
# This script starts the command in its own session, so that it keeps
# running when the session ends. The output goes into the log file, and
# the exit code of the command decides the marker:
#
#   LAB_DONE     the command succeeded
#   LAB_FAILED   the command failed
#
# The command is read from a file, not from the command line. The
# command contains single quotes (--name 'debian13-run-pve1'), and every layer of
# shell would have to escape them correctly.
# =============================================================================
set -uo pipefail

LOGFILE="${1:?log file required}"
CMDFILE="${2:?command file required}"

if [ ! -r "${CMDFILE}" ]; then
    echo "The command file ${CMDFILE} cannot be read" >&2
    exit 1
fi

CMD="$(cat "${CMDFILE}")"

if [ -z "${CMD}" ]; then
    echo "The command file ${CMDFILE} is empty" >&2
    exit 1
fi

rm -f "${LOGFILE}"

# The command runs in its own session (setsid) with its output in the
# log file. The redirection is done here, as root, because the admin
# user cannot write to /var/log.
#
# The exit code is captured, so that the marker reflects the result of
# the command and not the result of the last command of a chain.
setsid nohup bash -c '
    CMD="$(cat "$1")"
    bash -c "${CMD}"
    rc=$?
    if [ "${rc}" = "0" ]; then
        echo LAB_DONE
    else
        echo LAB_FAILED
    fi
    exit "${rc}"
' _ "${CMDFILE}" > "${LOGFILE}" 2>&1 < /dev/null &

echo "started"
