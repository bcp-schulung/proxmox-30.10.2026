#!/bin/bash
# =============================================================================
# build-seminar-guests.sh - build the seminar guests, step by step
# =============================================================================
# The guests of the seminar lab. There is ONE template per node and ONE
# running guest per node:
#
#   pve1: template 9101 debian13-tpl-pve1  ->  running 9201 debian13-run-pve1
#   pve2: template 9102 debian13-tpl-pve2  ->  running 9202 debian13-run-pve2
#   pve3: template 9103 debian13-tpl-pve3  ->  running 9203 debian13-run-pve3
#
# Why one template per node instead of one shared template:
#
#   A full clone can be moved to another node only when the source is on
#   shared storage. A template on the local storage of a node is refused
#   with
#
#     can't clone VM to node 'pve2' (VM uses local storage)
#
#   A linked clone is a snapshot of the template's disk, and a snapshot is
#   only possible on a storage that supports them. NFS does not, and the
#   request is refused with
#
#     Linked clone feature is not supported for 'nfs-lab:9000/...'
#
# A template on the node's OWN local LVM-thin storage satisfies both
# constraints, so every node carries its own copy of the golden image and
# every guest is cloned from the template of the node it runs on.
#
# The guest image is a qcow2 DISK, not an ISO:
#
#   The 'iso/' subdirectory of a directory storage only accepts real ISO
#   extensions, so 'local:iso/debian-13-generic-amd64.qcow2' is refused by
#   the volume-name parser:
#
#     unable to parse directory volume name 'iso/debian-13-generic-amd64.qcow2'
#
#   The image is therefore brought in with 'qm importdisk', which takes a
#   plain path.
#
#   The disk number that 'qm importdisk' picks is NOT the one to assume.
#   With an 'efidisk0' already attached, the EFI vars volume takes disk-0
#   and the imported OS disk lands on disk-1. Attaching disk-0 to scsi0
#   produces a template that boots a 4 MB EFI partition instead of Debian.
#   The imported volume is read back out of 'unused0' instead of guessed.
#
# The Debian cloud image ships NO network configuration and NO root
# password of its own - everything is meant to arrive from a cloud-init
# data source. A template without a cloud-init drive boots to a login
# prompt with no network interface at all.
# =============================================================================
set -uo pipefail

LAB_ROOT="${LAB_ROOT:-/Users/bencoeppicus/Documents/proxmox-30.10.2026}"
KEY="${LAB_ROOT}/.state/keys/pve-lab.pem"
SSH_USER="admin"

# -----------------------------------------------------------------------------
# The run lock.
#
# Two runs against the same cluster destroy each other's work: one builds
# the templates while the other tears them down, and the cluster is left
# with neither. The lock is a directory, because mkdir is atomic.
#
# It is the same lock that 'provision.sh' uses, so the two cannot run at
# the same time either.
# -----------------------------------------------------------------------------
LAB_LOCK_DIR="${LAB_ROOT}/.state/run.lock"

acquire_run_lock() {
    mkdir -p "${LAB_ROOT}/.state" 2>/dev/null || true

    if mkdir "${LAB_LOCK_DIR}" 2>/dev/null; then
        printf '%s\n' "$$" > "${LAB_LOCK_DIR}/pid" 2>/dev/null || true
        printf '%s\n' "build-seminar-guests.sh" > "${LAB_LOCK_DIR}/name" 2>/dev/null || true
        trap 'rm -rf "${LAB_LOCK_DIR}" 2>/dev/null || true' EXIT INT TERM
        return 0
    fi

    local holder holder_name
    holder="$(cat "${LAB_LOCK_DIR}/pid" 2>/dev/null || true)"
    holder_name="$(cat "${LAB_LOCK_DIR}/name" 2>/dev/null || true)"

    if [ -n "${holder}" ] && kill -0 "${holder}" 2>/dev/null; then
        echo "ERROR: another run (PID ${holder}, ${holder_name}) holds ${LAB_LOCK_DIR}" >&2
        echo "       wait for it to finish, or remove the lock if it is dead." >&2
        exit 1
    fi

    echo "WARNING: removing the stale lock ${LAB_LOCK_DIR}" >&2
    rm -rf "${LAB_LOCK_DIR}" 2>/dev/null || true
    mkdir "${LAB_LOCK_DIR}" 2>/dev/null || {
        echo "ERROR: could not take the lock ${LAB_LOCK_DIR}" >&2
        exit 1
    }
    printf '%s\n' "$$" > "${LAB_LOCK_DIR}/pid" 2>/dev/null || true
    printf '%s\n' "build-seminar-guests.sh" > "${LAB_LOCK_DIR}/name" 2>/dev/null || true
    trap 'rm -rf "${LAB_LOCK_DIR}" 2>/dev/null || true' EXIT INT TERM
}

acquire_run_lock

OPTS=(-i "${KEY}"
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o LogLevel=ERROR
      -o ConnectTimeout=20
      -o BatchMode=yes
      -o ServerAliveInterval=60
      -o ServerAliveCountMax=60)

node_addr() {
    case "$1" in
        pve1) printf '%s' "63.185.94.162" ;;
        pve2) printf '%s' "54.93.242.167" ;;
        pve3) printf '%s' "18.192.100.213" ;;
        *)    printf '%s' "" ;;
    esac
}

run_on() {
    local node="$1"; shift
    local addr
    addr="$(node_addr "${node}")"
    [ -n "${addr}" ] || { echo "Unknown node ${node}" >&2; return 1; }
    ssh "${OPTS[@]}" "${SSH_USER}@${addr}" "$@"
}

# -----------------------------------------------------------------------------
# The legacy layout.
#
# An earlier version of this script built a DIFFERENT inventory: the
# shared template 9001 on nfs-lab, the local template 9000 on pve3, and
# the guests 100, 101 and 102. A copy of that version was still running
# against the cluster, and it recreated the old objects while destroying
# the new ones.
#
# If the old objects are still there, this script is not the one that
# created them, and it would end up fighting them. Say so and stop,
# rather than leave a cluster with both layouts in it.
# -----------------------------------------------------------------------------
check_no_legacy_inventory() {
    local legacy="" legacy_id

    echo "=== checking for the legacy inventory ==="
    for legacy_id in 9000 9001 9002 100 101 102; do
        if run_on pve1 "sudo qm config ${legacy_id} >/dev/null 2>&1"; then
            legacy="${legacy} ${legacy_id}"
        fi
    done

    if [ -n "${legacy}" ]; then
        echo "ERROR: the legacy objects${legacy} are still on the cluster." >&2
        echo "       This script builds 9101-9103 and 9201-9203. The two" >&2
        echo "       layouts do not belong on the same cluster." >&2
        echo "       Remove the legacy objects first:" >&2
        for legacy_id in ${legacy}; do
            echo "         ssh admin@<node> 'sudo qm destroy ${legacy_id} --purge 1'" >&2
        done
        exit 1
    fi
    echo "  the cluster is clean"
}

run_detached() {
    local node="$1" log="$2" cmd="$3"
    local script="/tmp/lab-cmd-run.sh"

    printf '%s\n' "${cmd}" | \
        run_on "${node}" "sudo tee ${script} > /dev/null && sudo chmod 700 ${script}" >/dev/null 2>&1

    run_on "${node}" "sudo bash /usr/local/sbin/lab-detached ${log} ${script}" >/dev/null 2>&1
}

wait_detached() {
    local node="$1" log="$2" timeout="${3:-3600}"
    local waited=0
    local out

    while [ "${waited}" -lt "${timeout}" ]; do
        out="$(run_on "${node}" "sudo cat ${log} 2>/dev/null" 2>/dev/null)"

        if printf '%s' "${out}" | grep -q 'LAB_DONE'; then
            printf '%s\n' "${out}" | grep -v 'LAB_DONE' | tail -2
            return 0
        fi

        if printf '%s' "${out}" | grep -q 'LAB_FAILED'; then
            echo "  FAILED on ${node}:"
            printf '%s\n' "${out}" | grep -v 'LAB_' | tail -6
            return 1
        fi

        sleep 10
        waited=$(( waited + 10 ))
    done

    echo "  TIMEOUT on ${node}"
    return 1
}

# The guest password and the SSH key of the lab.
GUEST_PW="$(grep -oE '^GUEST_ROOT_PASSWORD="?[^"]*"?' "${LAB_ROOT}/.env" | cut -d= -f2- | tr -d '"')"
SSH_KEY="$(cat "${LAB_ROOT}/.state/keys/pve-lab.pub")"

# -----------------------------------------------------------------------------
# The inventory. The IDs are the ones in config/default.env.
# -----------------------------------------------------------------------------
NODES="pve1 pve2 pve3"
TPL_IDS="9101 9102 9103"
TPL_NAMES="debian13-tpl-pve1 debian13-tpl-pve2 debian13-tpl-pve3"
RUN_IDS="9201 9202 9203"
RUN_NAMES="debian13-run-pve1 debian13-run-pve2 debian13-run-pve3"

# The image lives in the ISO directory of the node, and the storage that
# holds the templates is the node-local LVM-thin pool.
IMAGE="/var/lib/vz/template/iso/debian-13-generic-amd64.qcow2"
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
IMAGE_SHA512="ec8c175e39d59e711798c3a2f22ba11b9aee9bca1887c7e505a800aeffd5d7616099bd0e9fad869efba96100fe09d2c8b49d6d7001d501f0056c556bdc25b605"

# -----------------------------------------------------------------------------
# The cloud-init snippet of a guest.
# -----------------------------------------------------------------------------
write_snippet() {
    local node="$1" vmid="$2" hostname="$3"

    cat > "/tmp/ci-guest-${vmid}.yaml" << EOF
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.seminar.local
prefer_fqdn_over_hostname: false
manage_etc_hosts: true
ssh_pwauth: true
chpasswd:
  expire: false
users:
  - name: root
    lock_passwd: false
    passwd: '${GUEST_PW}'
    ssh_authorized_keys:
      - ${SSH_KEY}
package_update: false
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ sh, -c, "printf 'provisioned-by-proxmox-seminar-lab\n' > /etc/lab-provisioned" ]
EOF

    scp -q -i "${KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=20 \
        "/tmp/ci-guest-${vmid}.yaml" "${SSH_USER}@$(node_addr "${node}"):/tmp/ci-guest-${vmid}.yaml"

    run_on "${node}" "sudo mkdir -p /var/lib/vz/snippets && \
        sudo cp /tmp/ci-guest-${vmid}.yaml /var/lib/vz/snippets/ci-${vmid}.yaml && \
        sudo chmod 600 /var/lib/vz/snippets/ci-${vmid}.yaml"
}

# -----------------------------------------------------------------------------
# The image on a node. It is verified against the upstream SHA512SUMS.
# -----------------------------------------------------------------------------
ensure_image() {
    local node="$1"

    if run_on "${node}" "test -f '${IMAGE}' && \
        echo '${IMAGE_SHA512}  ${IMAGE}' | sha512sum -c --status"; then
        echo "  the image is present and verified on ${node}"
        return 0
    fi

    echo "  downloading the image onto ${node}"
    run_on "${node}" "sudo mkdir -p /var/lib/vz/template/iso && \
        sudo curl -fSL --retry 3 -o '${IMAGE}.part' '${IMAGE_URL}' && \
        echo '${IMAGE_SHA512}  ${IMAGE}.part' | sudo sha512sum -c - && \
        sudo mv '${IMAGE}.part' '${IMAGE}'"
}

# -----------------------------------------------------------------------------
# The template on a node.
#
# The EFI vars disk is created FIRST, so that the imported OS disk gets a
# disk number of its own. The name of the imported volume is read back
# out of 'unused0' rather than guessed, because guessing it is what
# produces a template that boots a 4 MB EFI partition.
# -----------------------------------------------------------------------------
build_template() {
    local node="$1" vmid="$2" name="$3"

    echo ""
    echo "=== the template ${vmid} (${name}) on ${node} ==="

    if run_on "${node}" "sudo qm status ${vmid} >/dev/null 2>&1"; then
        echo "  the template exists already"
        return 0
    fi

    ensure_image "${node}"

    run_on "${node}" "sudo qm create ${vmid} --name '${name}' --memory 2048 --cores 2 --sockets 1 \
        --net0 'virtio,bridge=vmbr0' --scsihw virtio-scsi-single --ostype l26 --machine q35 \
        --bios ovmf --agent 'enabled=1,fstrim_cloned_disks=1' --tablet 1 --onboot 0 --protection 0"

    run_on "${node}" "sudo qm set ${vmid} --efidisk0 'local-lvm:1,efitype=4m,pre-enrolled-keys=1'"

    run_detached "${node}" "/var/log/lab-tpl-${vmid}.log" \
        "qm importdisk ${vmid} ${IMAGE} local-lvm"
    wait_detached "${node}" "/var/log/lab-tpl-${vmid}.log" 3600 || return 1

    # Read the name of the imported volume back instead of guessing it.
    local imported
    imported="$(run_on "${node}" \
        "sudo qm config ${vmid} | grep '^unused0:' | sed 's/^unused0: //' | cut -d, -f1" \
        2>/dev/null | tr -d '[:space:]')"

    if [ -z "${imported}" ]; then
        echo "  FAILED: the import did not produce a disk for ${vmid}"
        return 1
    fi

    run_on "${node}" "sudo qm set ${vmid} --scsi0 '${imported},discard=on,iothread=1' \
        --boot 'order=scsi0' && sudo qm template ${vmid}"
    run_on "${node}" "sudo qm config ${vmid} 2>&1 | grep -E 'template|scsi0'"
}

# -----------------------------------------------------------------------------
# The running guest on a node. It is a FULL clone of the template on that
# node, so the three guests are independent of each other.
# -----------------------------------------------------------------------------
build_guest() {
    local node="$1" src="$2" vmid="$3" name="$4"

    echo ""
    echo "=== the guest ${vmid} (${name}) on ${node} ==="

    if ! run_on "${node}" "sudo qm status ${vmid} >/dev/null 2>&1"; then
        run_detached "${node}" "/var/log/lab-clone-${vmid}.log" \
            "qm clone ${src} ${vmid} --name '${name}' --full 1 --storage local-lvm --target ${node}"
        wait_detached "${node}" "/var/log/lab-clone-${vmid}.log" 3600 || return 1
    else
        echo "  the guest exists already"
    fi

    # The cloud-init drive of the clone. The template itself has none: it
    # lives on the node-local 'local' storage, and Proxmox refuses to
    # clone a VM that uses node-local storage to another node.
    write_snippet "${node}" "${vmid}" "${name}"
    run_on "${node}" "sudo qm set ${vmid} --ide2 'local:cloudinit' --ipconfig0 'ip=dhcp' \
        --cicustom 'user=local:snippets/ci-${vmid}.yaml' 2>&1 | tail -2"

    run_on "${node}" "sudo qm start ${vmid} 2>&1 | tail -1"
    run_on "${node}" "sudo qm list 2>&1 | tail -n +2 | tr -s ' ' | grep '^ *${vmid} '"
}

# -----------------------------------------------------------------------------
# The templates, then the guests.
# -----------------------------------------------------------------------------
check_no_legacy_inventory

i=1
for node in ${NODES}; do
    tpl_id="$(echo "${TPL_IDS}" | cut -d' ' -f${i})"
    tpl_name="$(echo "${TPL_NAMES}" | cut -d' ' -f${i})"
    run_id="$(echo "${RUN_IDS}" | cut -d' ' -f${i})"
    run_name="$(echo "${RUN_NAMES}" | cut -d' ' -f${i})"

    build_template "${node}" "${tpl_id}" "${tpl_name}" || exit 1
    build_guest "${node}" "${tpl_id}" "${run_id}" "${run_name}" || exit 1

    i=$(( i + 1 ))
done

# -----------------------------------------------------------------------------
echo ""
echo "=== the cluster resources ==="
run_on pve1 "sudo pvesh get /cluster/resources --type vm --output-format json 2>&1 | python3 -c 'import json,sys
for r in json.load(sys.stdin): print(r.get(\"vmid\"), r.get(\"name\"), r.get(\"node\"), \"tmpl=\"+str(r.get(\"template\")))'"

echo ""
echo "=== the DHCP leases ==="
for n in ${NODES}; do
    printf '%-6s ' "${n}"
    run_on "${n}" "sudo cat /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print \$3, \$4}' | tr '\n' ' '"
    echo ""
done
