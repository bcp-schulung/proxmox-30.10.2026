#!/bin/bash
# =============================================================================
# build-guests.sh - build the guest VMs directly, with verification
# =============================================================================
# This script drives the guest provisioning without the harness, so that
# every step can be seen and checked. It is the same work that
# 'provision.sh --phase guests' does, but it reports every step and it
# waits for every long operation to finish.
#
# The guests. There is ONE template per node and ONE running guest per
# node:
#
#   pve1: template 9101 debian13-tpl-pve1  ->  running 9201 debian13-run-pve1
#   pve2: template 9102 debian13-tpl-pve2  ->  running 9202 debian13-run-pve2
#   pve3: template 9103 debian13-tpl-pve3  ->  running 9203 debian13-run-pve3
#
# The implementation lives in 'scripts/build-seminar-guests.sh'. This file
# is kept as the historical entry point and simply delegates to it, so
# that there is only ONE script that builds the guests and only ONE place
# where the inventory is written down.
#
# DO NOT run this while another provisioning run is in flight. Two runs
# against the same cluster fight each other: one deletes the templates
# while the other is cloning from them.
# =============================================================================
set -uo pipefail

LAB_ROOT="${LAB_ROOT:-/Users/bencoeppicus/Documents/proxmox-30.10.2026}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "${SCRIPT_DIR}/build-seminar-guests.sh" "$@"
