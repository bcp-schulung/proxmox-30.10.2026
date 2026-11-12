#!/usr/bin/env bash
# =============================================================================
# lib/pve.sh - Proxmox VE operations executed over SSH
# =============================================================================
# All commands run on a node as root. Because /etc/pve is replicated by
# pmxcfs, cluster-wide operations (pvesm, pveum, pvesh) can run on any node,
# while guest operations (qm, pct) must run on the node that owns the guest.

if [ -n "${__LAB_PVE_SOURCED:-}" ]; then
    return 0
fi
__LAB_PVE_SOURCED=1

# shellcheck source=lib/common.sh
. "${LAB_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
. "${LAB_LIB_DIR}/config.sh"
# shellcheck source=lib/state.sh
. "${LAB_LIB_DIR}/state.sh"
# shellcheck source=lib/ssh.sh
. "${LAB_LIB_DIR}/ssh.sh"
# The node list is needed to tell a node name apart from a host address.
# shellcheck source=lib/lab.sh
. "${LAB_LIB_DIR}/lab.sh"

# Run a command on a node with proper shell quoting.
# pve_cmd <host> <command> [args...]
# The Proxmox CLI has to run as root. The Debian cloud image logs in as the
# unprivileged "admin" user, so every command is run through sudo.
#
# The first argument is either a host address or the name of a lab node. When
# it is a node name, the command goes over the transport that actually works
# for that node - SSH or the Systems Manager. This matters because the
# operator's network often cannot reach the instance addresses.
pve_cmd() {
    local host="$1"; shift
    local cmd
    # A single argument is a command line and is passed through as it is.
    # That is what makes the shell pipelines and the command substitutions
    # work. More than one argument is a command with its arguments, and
    # every one of them is quoted.
    if [ "$#" -eq 1 ]; then
        cmd="$1"
    else
        cmd="$(printf '%q ' "$@")"
    fi
    pve_exec "${host}" "sudo ${cmd}"
}

# Same, but discards stdout and only reports success/failure.
pve_cmd_q() {
    local host="$1"; shift
    local cmd
    if [ "$#" -eq 1 ]; then
        cmd="$1"
    else
        cmd="$(printf '%q ' "$@")"
    fi
    pve_exec_q "${host}" "sudo ${cmd}"
}

# Run a Proxmox command on a node and print its stdout. stderr is passed
# through so that failures stay visible. Use this when the output has to be
# piped or parsed - pve_cmd_q swallows stdout.
pve_cmd_out() {
    local host="$1"; shift
    local cmd
    if [ "$#" -eq 1 ]; then
        cmd="$1"
    else
        cmd="$(printf '%q ' "$@")"
    fi
    pve_exec_out "${host}" "sudo ${cmd}"
}

# ---------------------------------------------------------------------------
# The transport
# ---------------------------------------------------------------------------
#
# A host address is reached over SSH. A node name is reached over the
# transport that the transport_for helper has chosen for it. The two are
# told apart by looking the host up in the state file.
# ---------------------------------------------------------------------------

# The node name for a host address, or an empty string when the host is not
# a known node.
pve_host_node() {
    local host="$1" node

    for node in $(lab_node_list 2>/dev/null); do
        local reach priv pub
        reach="$(state_reach_ip "${node}" 2>/dev/null || true)"
        priv="$(state_get ".instances.${node}.private_ip" 2>/dev/null || true)"
        pub="$(state_get ".instances.${node}.public_ip" 2>/dev/null || true)"

        if [ "${host}" = "${reach}" ] || [ "${host}" = "${priv}" ] || [ "${host}" = "${pub}" ] \
           || [ "${host}" = "${node}" ]; then
            printf '%s' "${node}"
            return 0
        fi
    done

    printf ''
}

# Run a command on a node or a host address.
pve_exec() {
    local host="$1"; shift
    local node
    node="$(pve_host_node "${host}")"

    if [ -n "${node}" ]; then
        lab_exec "${node}" "$@"
    else
        ssh_exec "${host}" "$@"
    fi
}

# Same, but discards stdout and only reports success/failure.
pve_exec_q() {
    local host="$1"; shift
    local node
    node="$(pve_host_node "${host}")"

    if [ -n "${node}" ]; then
        lab_exec_q "${node}" "$@"
    else
        ssh_exec_q "${host}" "$@"
    fi
}

# Same, but prints stdout and passes stderr through.
pve_exec_out() {
    local host="$1"; shift
    local node
    node="$(pve_host_node "${host}")"

    if [ -n "${node}" ]; then
        lab_exec "${node}" "$@"
    else
        # shellcheck disable=SC2046
        ssh $(ssh_options) "${SSH_USER}@${host}" "$@"
    fi
}

# Run a Proxmox command on the node that currently holds the cluster (any
# node works for cluster-wide operations).
pve_cluster_cmd() {
    local host="$1"; shift
    pve_cmd "${host}" "$@"
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

# pve_cluster_create <host> <cluster-name> <link0-ip> <nodeid>
pve_cluster_create() {
    local host="$1" cluster="$2" link0="$3" nodeid="$4"
    log_info "Creating cluster '${cluster}' on ${host}"
    pve_cmd "${host}" pvecm create "${cluster}" --link0 "${link0}" --nodeid "${nodeid}"
}

# pve_cluster_join <host> <seed-host> <link0-ip> <nodeid> <fingerprint> [seed-ring-ip]
#
# 'pvecm add --use_ssh' distributes the cluster SSH keys with
# 'ssh-copy-id'. That command verifies the host key of the seed node and
# refuses to continue when the key is not known:
#
#   ERROR: Host key verification failed.
#
# The known hosts file of a Proxmox node lives in the cluster filesystem
# (/etc/pve/priv/known_hosts), which only exists once the node is part of
# a cluster. A node that is joining therefore has no known host for the
# seed node, and the join fails.
#
# The host key of the seed node is therefore fetched from the seed node
# itself and written into the local known hosts file before the join.
pve_cluster_join() {
    local host="$1" seed="$2" link0="$3" nodeid="$4" fingerprint="$5"
    local seed_ring="${6:-}"

    log_info "Joining ${host} to the cluster via ${seed}"

    # The address of the seed node has to be of the same address family
    # as the ring address of the joining node. Otherwise corosync builds
    # a configuration with mixed families and refuses to start.
    if [ -n "${seed_ring}" ]; then
        seed="${seed_ring}"
    fi

    # The host key of the seed node, read from the seed node itself. The
    # private address of the seed node is used, because that is the
    # address the cluster members talk to each other on.
    local seed_key seed_ip
    # The address is taken with cut and not with awk: the command
    # quoting of the transport layer would escape the dollar sign of the
    # awk expression, and awk would then fail to parse it.
    seed_ip="$(pve_cmd_out "${seed}" "hostname -I 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+\.' | head -1" 2>/dev/null | tr -d '\r' | head -1)"
    [ -n "${seed_ip}" ] || seed_ip="${seed}"

    # The public host keys of the seed node. Reading them from the seed
    # node itself is more reliable than scanning the network: the scan
    # needs a working SSH daemon and returns nothing when the firewall
    # drops the probe.
    seed_key="$(pve_cmd_out "${seed}" "cat /etc/ssh/ssh_host_rsa_key.pub /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null" 2>/dev/null | tr -d '\r' | cut -d' ' -f1,2 | sed "s|^|${seed_ip} |" | sort -u || true)"

    if [ -z "${seed_key}" ]; then
        # The scan is the second chance.
        seed_key="$(pve_cmd_out "${seed}" "ssh-keyscan -T 10 -t rsa,ecdsa,ed25519 ${seed_ip} 2>/dev/null | sort -u" 2>/dev/null | tr -d '\r' || true)"
    fi

    if [ -n "${seed_key}" ]; then
        log_info "Adding the host key of the seed node to the known hosts of ${host}"

        # The known hosts file is base64 encoded, so that the quoting of
        # the shell and of the AWS CLI cannot mangle it.
        local encoded
        encoded="$(printf '%s\n' "${seed_key}" | base64 | tr -d '\n')"

        # OpenSSH looks for the file in /root/.ssh/known_hosts. On a node
        # that is not clustered yet, that is a real file - the cluster
        # file is a symlink to the system file.
        pve_cmd_q "${host}" "sudo mkdir -p /root/.ssh /etc/pve/priv && sudo touch /root/.ssh/known_hosts && sudo chmod 644 /root/.ssh/known_hosts"
        pve_cmd_q "${host}" "printf '%s' '${encoded}' | base64 -d | sudo tee -a /root/.ssh/known_hosts >/dev/null"

        # The system wide file as well. The Proxmox code copies the
        # cluster file into it when the path is a symlink, but a node that
        # is not clustered yet has a real file there.
        pve_cmd_q "${host}" "sudo touch /etc/ssh/ssh_known_hosts && sudo chmod 644 /etc/ssh/ssh_known_hosts"
        pve_cmd_q "${host}" "printf '%s' '${encoded}' | base64 -d | sudo tee -a /etc/ssh/ssh_known_hosts >/dev/null"
    else
        log_warn "Could not read the host key of the seed node - the join may fail"
    fi

    pve_cmd "${host}" pvecm add "${seed}" \
        --link0 "${link0}" \
        --nodeid "${nodeid}" \
        --fingerprint "${fingerprint}" \
        --use_ssh

    # 'pvecm add' reports a success even when the join failed.
    #
    # The corosync service is started asynchronously, so the command
    # returns before the configuration has been written and before
    # corosync has had a chance to reject the configuration. The two
    # failure modes that are seen in practice are:
    #
    #   * the host key of the seed node is not known, and ssh-copy-id
    #     refuses to continue
    #   * the nodes of the ring use different address families, and
    #     corosync refuses to start
    #
    # Both are caught by looking at the result: the configuration has to
    # exist, and the node has to be a member of the cluster.
    # The proof that the join worked is the membership, not the presence
    # of the configuration file. The file is written by the cluster
    # service a moment after the join command returned, so a check for
    # the file alone races with the join.
    local waited=0
    while [ "${waited}" -lt 90 ]; do
        if pve_cmd_q "${host}" "pvecm nodes 2>/dev/null | grep -qE '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+'"; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if ! pve_cmd_q "${host}" "pvecm nodes 2>/dev/null | grep -qE '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+'"; then
        log_error "The join of ${host} failed: the node is not a member of the cluster."
        pve_cmd_out "${host}" "pvecm status 2>&1 | head -20" 2>/dev/null | sed 's/^/    /' || true
        return 1
    fi

    # The corosync service has to be running. A configuration that
    # corosync rejects leaves the service inactive.
    waited=0
    while [ "${waited}" -lt 60 ]; do
        if pve_cmd_q "${host}" "systemctl is-active --quiet corosync"; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if ! pve_cmd_q "${host}" "systemctl is-active --quiet corosync"; then
        log_error "The join of ${host} failed: corosync did not start."
        pve_cmd_out "${host}" "journalctl -u corosync --no-pager -n 10" 2>/dev/null | sed 's/^/    /' || true
        return 1
    fi

    return 0
}

pve_cluster_status() {
    pve_cmd "$1" pvecm status || true
}

pve_cluster_nodes() {
    pve_cmd "$1" pvecm nodes || true
}

# The fingerprint of the cluster CA, required by 'pvecm add'.
pve_cluster_fingerprint() {
    local host="$1"
    local fingerprint

    fingerprint="$(pve_cmd "${host}" "pvecm updatecerts --fingerprint 2>/dev/null | grep -oE '([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}' | head -1" || true)"

    if [ -z "${fingerprint}" ]; then
        # Fall back to the CA certificate in the node's own SSL configuration.
        fingerprint="$(pve_cmd "${host}" "openssl x509 -in /etc/pve/nodes/\$(hostname)/pve-ssl.pem -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ':' | sed 's/../&:/g; s/:$//' | tr 'a-f' 'A-F'" || true)"
    fi

    printf '%s' "${fingerprint}"
}

# pve_cluster_leave <host>
pve_cluster_leave() {
    pve_cmd "$1" pvecm leave --force
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

# pve_storage_add_lvmthin <host> <storage-id> <vg> <thinpool>
#
# The definition is cluster-wide and every node resolves it against its own
# local volume group - this is exactly how the PVE installer behaves when
# nodes are clustered, so the storage ID stays 'local-lvm' as the seminar
# material expects.
pve_storage_add_lvmthin() {
    local host="$1" sid="$2" vg="$3" pool="$4"
    if pve_cmd_out "${host}" pvesm status | grep -qE "^${sid}"; then
        log_info "Storage '${sid}' already defined"
        return 0
    fi
    log_info "Adding LVM-thin storage '${sid}' (${vg}/${pool})"
    pve_cmd "${host}" pvesm add lvmthin "${sid}" --vgname "${vg}" --thinpool "${pool}" \
        --content images,rootdir
}

# pve_storage_add_nfs <host> <storage-id> <server> <export>
pve_storage_add_nfs() {
    local host="$1" sid="$2" server="$3" export="$4"
    if pve_cmd_out "${host}" pvesm status | grep -qE "^${sid}"; then
        log_info "Storage '${sid}' already defined"
        return 0
    fi
    log_info "Adding NFS storage '${sid}' -> ${server}:${export}"
    pve_cmd "${host}" pvesm add nfs "${sid}" \
        --server "${server}" \
        --export "${export}" \
        --content images,rootdir,iso,vztmpl,backup,snippets \
        --options "vers=4.1,hard,proto=tcp"
}

# pve_storage_add_pbs <host> <storage-id> <server> <datastore> <user> <password> <fingerprint>
pve_storage_add_pbs() {
    local host="$1" sid="$2" server="$3" datastore="$4" user="$5" password="$6" fingerprint="$7"
    if pve_cmd_out "${host}" pvesm status | grep -qE "^${sid}"; then
        log_info "Storage '${sid}' already defined"
        return 0
    fi
    log_info "Adding PBS storage '${sid}' -> ${server}:${datastore}"
    pve_cmd "${host}" pvesm add pbs "${sid}" \
        --server "${server}" \
        --datastore "${datastore}" \
        --username "${user}" \
        --password "${password}" \
        --fingerprint "${fingerprint}" \
        --content backup
}

# hostname of the node we are talking to
hostname_on() {
    pve_cmd "$1" hostname 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Guests
# ---------------------------------------------------------------------------

# Download a guest OS image onto a node.
# pve_download <host> <url> <destination>
pve_download() {
    local host="$1" url="$2" dest="$3"
    log_info "Downloading ${url}"
    # The download and the move both run as root: the target is under
    # /var/lib/vz, which the unprivileged admin user cannot write to.
    pve_cmd "${host}" "sudo curl -fSL --retry 3 --retry-delay 5 -o '${dest}.part' '${url}' && sudo mv -f '${dest}.part' '${dest}'"
}

# Write a cloud-init user-data snippet to a node.
# pve_write_cloudinit <host> <vmid> <hostname> <ssh-public-key> <password>
pve_write_cloudinit() {
    local host="$1" vmid="$2" guest_hostname="$3" sshkey="$4" password="$5"

    # The file has to be in the snippets directory of the node: the
    # 'cicustom' option expects the value 'user=local:snippets/<file>',
    # and a path outside the snippets directory is refused with
    #
    #   volume 'local:snippets/ci-9101.yaml' does not exist
    #
    local remote="snippets/ci-${vmid}.yaml"
    local content
    content="$(cat << EOF
#cloud-config
hostname: ${guest_hostname}
fqdn: ${guest_hostname}.seminar.local
prefer_fqdn_over_hostname: false
manage_etc_hosts: true
ssh_pwauth: true
chpasswd:
  expire: false
users:
  - name: root
    lock_passwd: false
    passwd: '${password}'
    ssh_authorized_keys:
      - ${sshkey}
package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - curl
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ sh, -c, "printf 'provisioned-by-proxmox-seminar-lab\\n' > /etc/lab-provisioned" ]
EOF
)"
    # The file is written through the snippet directory, with the
    # permissions that Proxmox expects.
    printf '%s\n' "${content}" | \
        pve_exec "${host}" "sudo mkdir -p /var/lib/vz/snippets && sudo tee /var/lib/vz/${remote} > /dev/null && sudo chmod 600 /var/lib/vz/${remote}"
    printf '%s' "${remote}"
}

# Create the per-node template.
#
# pve_vm_create_local_template <host> <vmid> <name> <storage> <qcow2-image>
#
# The template holds the disk on the local LVM-thin storage of the node.
#
# A template on the node's own local storage satisfies both clone
# constraints:
#
#   A linked clone is a snapshot of the template's disk, and a snapshot is
#   only possible on a storage that supports them. NFS does not, and the
#   request is refused with
#
#     Linked clone feature is not supported for 'nfs-lab:9000/...'
#
#   A full clone can be moved to another node only when the source is on
#   shared storage, so a template on a node's local storage must NOT be
#   cloned onto a different node:
#
#     can't clone VM to node 'pve2' (VM uses local storage)
#
# The image is a qcow2 DISK, not an ISO. It cannot be referenced as
# 'local:iso/<file>.qcow2', because the 'iso/' subdirectory of a directory
# storage only accepts real ISO extensions and the volume-name parser
# refuses it with
#
#   unable to parse directory volume name 'iso/debian-13-generic-amd64.qcow2'
#
# It is brought in with 'qm importdisk', which takes a plain path.
#
# The disk number that 'qm importdisk' picks is NOT the one to assume: with
# an 'efidisk0' already attached, the EFI vars volume takes disk-0 and the
# imported OS disk lands on disk-1. Attaching disk-0 to scsi0 produces a
# template that boots a 4 MB EFI partition instead of Debian, and it looks
# correct at first glance because the size is read from the config rather
# than from the volume. The imported volume is therefore read back out of
# 'unused0' instead of being guessed.
pve_vm_create_local_template() {
    local host="$1" vmid="$2" name="$3" storage="$4" image="$5"

    log_info "Creating the template ${vmid} (${name}) on ${host}"
    pve_cmd "${host}" qm create "${vmid}" \
        --name "${name}" \
        --memory "${GUEST_MEM_MB}" \
        --cores "${GUEST_CORES}" \
        --sockets 1 \
        --net0 "virtio,bridge=vmbr0" \
        --scsihw virtio-scsi-single \
        --ostype l26 \
        --machine q35 \
        --bios ovmf \
        --agent "enabled=1,fstrim_cloned_disks=1" \
        --tablet 1 \
        --onboot 0 \
        --protection 0

    # The EFI vars disk. It is created BEFORE the import, so that the
    # imported OS disk gets a disk number of its own.
    pve_cmd "${host}" qm set "${vmid}" \
        --efidisk0 "${storage}:1,efitype=4m,pre-enrolled-keys=1"

    # The import moves 3 GB and takes minutes. It runs detached, so that
    # it is not killed when the SSH session drops.
    pve_cmd_detached "${host}" "qm importdisk ${vmid} ${image} ${storage}" 3600

    # Read the name of the imported volume back instead of guessing it.
    local imported
    imported="$(pve_cmd_out "${host}" \
        "qm config ${vmid} | grep '^unused0:' | sed 's/^unused0: //' | cut -d, -f1" 2>/dev/null | tr -d '[:space:]')"

    if [ -z "${imported}" ]; then
        log_error "The import did not produce a disk for VM ${vmid}"
        return 1
    fi

    pve_cmd "${host}" qm set "${vmid}" \
        --scsi0 "${imported},discard=on,iothread=1" \
        --boot "order=scsi0"

    # The volume that was imported is now attached. Remove the reference
    # to the unused disk without touching the volume itself.
    pve_cmd "${host}" qm set "${vmid}" --delete unused0 2>/dev/null || true

    pve_vm_make_template "${host}" "${vmid}"
}

# Run a long command on a node, detached from the SSH session.
#
# pve_cmd_detached <host> <command> [timeout-seconds]
#
# A long operation - the import of a 3 GB guest image, a clone of a disk
# over NFS - outlives the SSH connection that started it. When the
# connection drops, the process on the node is killed with it, and the
# operation stops halfway: the volume exists, but it is only partly
# written.
#
# The command is therefore started with 'setsid' and redirected to a log
# file, so that it keeps running when the session ends. The harness then
# waits for the log to show that the command finished.
pve_cmd_detached() {
    local host="$1" cmd="$2" timeout="${3:-1800}"
    local logfile="/var/log/lab-detached-$$.log"

    log_info "Starting a long operation on ${host} (detached)"

    # The command runs in its own session, with its output in a log.
    #
    # The 'sudo' is applied to the whole thing with a single call, so
    # that the detached process runs as root. It cannot be applied to
    # the inner command alone: pve_cmd already prefixes the command
    # line with sudo, and a second sudo inside a detached shell would
    # wait for a password that never comes.
    # The redirection has to happen inside the sudo. The admin user
    # cannot write to /var/log, so a redirection that is made outside
    # the sudo fails with "Permission denied" and the log is never
    # created.
    # The helper script does the work. Doing it with a nested quoting
    # in the command line is fragile: the redirection has to happen
    # inside the sudo, because the admin user cannot write to /var/log.
    # The command is passed as one argument. The quoting has to survive
    # the shell on both sides: the command itself contains single quotes
    # (--name 'debian13-run-pve1'), so it is passed through the environment of the
    # helper rather than through the command line.
    # The command is written into a file on the node, and the helper
    # reads it from there. Passing the command on the command line is
    # fragile: the command itself contains single quotes (--name
    # 'debian13-run-pve1'), and every layer of shell would have to be escaped
    # correctly.
    local script="/tmp/lab-cmd-$$.sh"
    printf '%s\n' "${cmd}" | \
        pve_exec "${host}" "sudo tee ${script} > /dev/null && sudo chmod 700 ${script}"

    pve_exec "${host}" "sudo bash /usr/local/sbin/lab-detached ${logfile} ${script}"

    # The harness polls the log file for the marker that the command
    # wrote when it finished.
    local waited=0
    while [ "${waited}" -lt "${timeout}" ]; do
        local out
        out="$(pve_cmd_out "${host}" "cat ${logfile} 2>/dev/null || true" 2>/dev/null || true)"

        if printf '%s' "${out}" | grep -q 'LAB_DONE'; then
            # The command finished. The output without the marker is
            # shown, so that an error is visible.
            printf '%s' "${out}" | sed 's/LAB_DONE.*//' | grep -v '^$' && true
            if printf '%s' "${out}" | grep -q 'LAB_FAILED'; then
                die "The long operation on ${host} failed."
            fi
            log_ok "The long operation on ${host} finished"
            pve_cmd "${host}" "rm -f ${logfile}" >/dev/null 2>&1 || true
            return 0
        fi

        sleep 10
        waited=$(( waited + 10 ))
    done

    log_warn "The long operation on ${host} did not finish within ${timeout} seconds"
    return 1
}

# Create the golden-image VM and import the cloud image into it.
# pve_vm_create_from_cloudimage <host> <vmid> <name> <storage> <qcow2-path> <ci-yaml-path>
pve_vm_create_from_cloudimage() {
    local host="$1" vmid="$2" name="$3" storage="$4" image="$5" ciyaml="$6"

    log_info "Creating VM ${vmid} (${name}) on ${host}"
    pve_cmd "${host}" qm create "${vmid}" \
        --name "${name}" \
        --memory "${GUEST_MEM_MB}" \
        --cores "${GUEST_CORES}" \
        --sockets 1 \
        --net0 "virtio,bridge=vmbr0" \
        --scsihw virtio-scsi-single \
        --ostype l26 \
        --machine q35 \
        --bios ovmf \
        --agent "enabled=1,fstrim_cloned_disks=1" \
        --tablet 1 \
        --onboot 1 \
        --protection 0

    log_info "Importing the guest image into VM ${vmid}"
    # The import moves 3 GB and takes minutes. It runs detached, so that
    # it is not killed when the SSH session drops.
    pve_cmd_detached "${host}" "qm importdisk ${vmid} ${image} ${storage}" 3600

    pve_cmd "${host}" qm set "${vmid}" \
        --scsi0 "${storage}:vm-${vmid}-disk-0,discard=on,iothread=1" \
        --efidisk0 "${storage}:1,efitype=4m,pre-enrolled-keys=1" \
        --boot "order=scsi0" \
        --ide2 "local:cloudinit" \
        --ipconfig0 "ip=dhcp" \
        --cicustom "user=local:${ciyaml}"
}

# Convert a VM into a template.
pve_vm_make_template() {
    local host="$1" vmid="$2"
    log_info "Converting VM ${vmid} into a template"
    pve_cmd "${host}" qm template "${vmid}"
}

# Clone a template. mode: full | linked
#
# pve_vm_clone <source-host> <src-vmid> <newid> <name> <storage> <mode> [target-node]
#
# The clone is always started on the node that holds the template. The
# target node is passed with --target, so that Proxmox creates the clone
# there.
#
# Running the clone on the target node does not work: the configuration
# of a template is only known to the node that owns it, and the other
# node answers with
#
#   unable to find configuration file for VM 9101 on node 'pve2'
#
pve_vm_clone() {
    local host="$1" src="$2" newid="$3" name="$4" storage="$5" mode="$6"
    local target="${7:-}"
    log_info "Cloning VM ${src} -> ${newid} (${name}, ${mode} clone${target:+, on ${target}})"

    local full=1
    [ "${mode}" = "linked" ] && full=0

    local target_opt=""
    if [ -n "${target}" ]; then
        target_opt="--target ${target}"
    fi

    # A linked clone is a reference to the template's disk and cannot
    # live on a different storage than the template. Proxmox refuses the
    # request with
    #
    #   parameter 'storage' not allowed for linked clones
    #
    # so the storage is only given for a full clone.
    local storage_opt=""
    if [ "${full}" = "1" ]; then
        storage_opt="--storage ${storage}"
    fi

    # A full clone copies 3 GB. It runs detached, so that it is not
    # killed when the SSH session drops.
    if [ "${full}" = "1" ]; then
        # The marker is added by the helper script, according to the
        # exit code of the command. It must not be part of the command
        # itself: a chain like 'cmd && echo DONE || echo FAILED' reports
        # the result of the last command of the chain, not the result of
        # the clone.
        pve_cmd_detached "${host}" \
            "qm clone ${src} ${newid} --name '${name}' --full 1 ${storage_opt} ${target_opt}" \
            3600
    else
        pve_cmd "${host}" "qm clone ${src} ${newid} --name '${name}' --full 0 ${target_opt}"
    fi
}

# Apply the cloud-init configuration to a clone (clones inherit the drive but
# need their own hostname and credentials).
pve_vm_set_cloudinit() {
    local host="$1" vmid="$2" guest_hostname="$3" ciyaml="$4"
    # The cicustom option takes a key=value pair: the file is
    # identified by the storage and the path inside the snippets
    # directory.
    pve_cmd "${host}" qm set "${vmid}" \
        --ide2 "local:cloudinit" \
        --ipconfig0 "ip=dhcp" \
        --cicustom "user=local:${ciyaml}"
}

# Create an unprivileged LXC container.
# pve_ct_create <host> <ctid> <hostname> <storage> <template> <password> <sshkey>
pve_ct_create() {
    local host="$1" ctid="$2" name="$3" storage="$4" template="$5" password="$6" sshkey="$7"
    log_info "Creating container ${ctid} (${name}) on ${host}"
    pve_cmd "${host}" pct create "${ctid}" "${storage}:vztmpl/${template}" \
        --hostname "${name}" \
        --memory "${CT_MEM_MB}" \
        --cores "${CT_CORES}" \
        --rootfs "${storage}:${CT_DISK_GB}" \
        --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
        --unprivileged 1 \
        --ostype debian \
        --onboot 1 \
        --password "${password}" \
        --ssh-public-key "${sshkey}" \
        --features "nesting=1"
}

# Start a guest and wait until it is running.
pve_guest_start() {
    local host="$1" kind="$2" id="$3"
    if [ "${kind}" = "vm" ]; then
        pve_cmd "${host}" qm start "${id}"
    else
        pve_cmd "${host}" pct start "${id}"
    fi
}

# ---------------------------------------------------------------------------
# Security baseline (the security seminar exercises)
# ---------------------------------------------------------------------------

# pve_security_realm <host> <realm>
pve_security_realm() {
    local host="$1" realm="$2"
    if pve_cmd_out "${host}" pveum realm list | grep -qE "^${realm} "; then
        log_info "Realm '${realm}' already present"
        return 0
    fi
    log_info "Creating realm '${realm}'"
    # The lab has no directory server, so the built-in 'pve' realm type is
    # used under the deck's name. The exercise commands stay identical.
    pve_cmd "${host}" pveum realm add "${realm}" --type pve --comment "Proxmox seminar lab realm"
}

# pve_security_user <host> <user> <password>
pve_security_user() {
    local host="$1" user="$2" password="$3"
    if pve_cmd_out "${host}" pveum user list | grep -qF "${user}"; then
        log_info "User '${user}' already present"
        return 0
    fi
    log_info "Creating user '${user}'"
    pve_cmd "${host}" pveum user add "${user}" --password "${password}"
}

# pve_security_role <host> <role> <privs>
pve_security_role() {
    local host="$1" role="$2" privs="$3"
    if pve_cmd_out "${host}" pveum role list | grep -qE "^${role} "; then
        log_info "Role '${role}' already present"
        return 0
    fi
    log_info "Creating role '${role}' with privileges: ${privs}"
    pve_cmd "${host}" pveum role add "${role}" -privs "${privs}"
}

# pve_security_acl <host> <path> <users> <roles>
pve_security_acl() {
    local host="$1" path="$2" users="$3" roles="$4"
    log_info "Granting '${roles}' on '${path}' to '${users}'"
    pve_cmd "${host}" pveum acl modify "${path}" --users "${users}" --roles "${roles}"
}

# pve_security_token <host> <user> <token-name>
pve_security_token() {
    local host="$1" user="$2" token="$3"
    if pve_cmd_out "${host}" pveum user token list "${user}" | grep -qF "${token}"; then
        log_info "API token '${user}!${token}' already present"
        return 0
    fi
    log_info "Creating privilege-separated API token '${user}!${token}'"
    pve_cmd "${host}" pveum user token add "${user}" "${token}" --privsep 1
}

# pve_security_token_acl <host> <path> <token-id> <roles>
pve_security_token_acl() {
    local host="$1" path="$2" token="$3" roles="$4"
    log_info "Scoping token '${token}' to '${path}' with role '${roles}'"
    pve_cmd "${host}" pveum acl modify "${path}" --tokens "${token}" --roles "${roles}"
}

# pve_security_firewall_dc <host> <allow-cidr>
pve_security_firewall_dc() {
    local host="$1" cidr="$2"
    log_info "Enabling the datacenter firewall (default deny inbound)"
    pve_cmd "${host}" pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT

    # Allow the operator to reach the web UI and SSH.
    pve_cmd "${host}" pvesh create /cluster/firewall/rules \
        --action ACCEPT --type in --dport 8006 --proto tcp --source "${cidr}" \
        --comment "seminar: web UI from the operator network"
    pve_cmd "${host}" pvesh create /cluster/firewall/rules \
        --action ACCEPT --type in --dport 22 --proto tcp --source "${cidr}" \
        --comment "seminar: SSH from the operator network"

    # Corosync (KNET) needs its UDP ports between the nodes.
    pve_cmd "${host}" pvesh create /cluster/firewall/rules \
        --action ACCEPT --type in --dport "5405:5412" --proto udp \
        --source "${VPC_CIDR}" --comment "seminar: corosync/knot between nodes"

    # NFS client traffic to the shared storage.
    pve_cmd "${host}" pvesh create /cluster/firewall/rules \
        --action ACCEPT --type in --dport 2049 --proto tcp \
        --source "${VPC_CIDR}" --comment "seminar: NFS from the cluster"
}

# pve_security_vm_firewall <host> <vmid> <source-cidr> <dport>
pve_security_vm_firewall() {
    local host="$1" vmid="$2" cidr="$3" dport="$4"
    log_info "Adding a VM firewall rule for VM ${vmid}"
    pve_cmd "${host}" pvesh create "/nodes/$(hostname_on "${host}")/qemu/${vmid}/firewall/rules" \
        --action ACCEPT --type in --dport "${dport}" --proto tcp --source "${cidr}" \
        --comment "seminar: scoped workload ingress"
}

# pve_security_sdn <host> <vnet> <zone>
pve_security_sdn() {
    local host="$1" vnet="$2" zone="$3"
    if pve_cmd_out "${host}" pvesh get /cluster/sdn/vnets --output-format json | grep -qF "\"${vnet}\""; then
        log_info "SDN vnet '${vnet}' already present"
        return 0
    fi
    log_info "Creating SDN vnet '${vnet}' in zone '${zone}'"
    pve_cmd "${host}" pvesh create /cluster/sdn/vnets --vnet "${vnet}" --zone "${zone}" 2>/dev/null \
        || log_warn "Could not create the SDN vnet - SDN zones need to be configured first"
}

# Self-signed ACME certificate covering every node, so the cluster has a
# consistent TLS identity without requiring public DNS.
pve_security_acme_selfsigned() {
    local host="$1"
    shift
    local domains=""
    local node
    for node in "$@"; do
        [ -n "${domains}" ] && domains="${domains},"
        domains="${domains}${node}.seminar.local,${node}"
    done
    log_info "Issuing a self-signed cluster certificate for: ${domains}"
    pve_cmd "${host}" pvenode acme account register default "root@${PVE_DOMAIN}" 2>/dev/null || true
    pve_cmd "${host}" pvenode acme plugin add selfsigned directory 2>/dev/null || true
    pve_cmd "${host}" pvenode acme cert order --acme selfsigned --nodes "$(hostname_on "${host}")" \
        --domains "${domains}" 2>/dev/null || log_warn "ACME self-signed ordering failed (non fatal)"
}
