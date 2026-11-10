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
# shellcheck source=lib/ssh.sh
. "${LAB_LIB_DIR}/ssh.sh"

# Run a command on a node with proper shell quoting.
# pve_cmd <host> <command> [args...]
# The Proxmox CLI has to run as root. The Debian cloud image logs in as the
# unprivileged "admin" user, so every command is run through sudo.
pve_cmd() {
    local host="$1"; shift
    local cmd
    cmd="$(printf '%q ' "$@")"
    ssh_exec "${host}" "sudo ${cmd}"
}

# Same, but discards stdout and only reports success/failure.
pve_cmd_q() {
    local host="$1"; shift
    local cmd
    cmd="$(printf '%q ' "$@")"
    ssh_exec_q "${host}" "sudo ${cmd}"
}

# Run a Proxmox command on a node and print its stdout. stderr is passed
# through so that failures stay visible. Use this when the output has to be
# piped or parsed - pve_cmd_q swallows stdout.
pve_cmd_out() {
    local host="$1"; shift
    local cmd
    cmd="$(printf '%q ' "$@")"
    # shellcheck disable=SC2046
    ssh $(ssh_options) "${SSH_USER}@${host}" "sudo ${cmd}"
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

# pve_cluster_join <host> <seed-host> <link0-ip> <nodeid> <fingerprint>
pve_cluster_join() {
    local host="$1" seed="$2" link0="$3" nodeid="$4" fingerprint="$5"
    log_info "Joining ${host} to the cluster via ${seed}"
    pve_cmd "${host}" pvecm add "${seed}" \
        --link0 "${link0}" \
        --nodeid "${nodeid}" \
        --fingerprint "${fingerprint}" \
        --use_ssh
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
    pve_cmd "${host}" "curl -fSL --retry 3 --retry-delay 5 -o '${dest}.part' '${url}' && mv -f '${dest}.part' '${dest}'"
}

# Write a cloud-init user-data snippet to a node.
# pve_write_cloudinit <host> <vmid> <hostname> <ssh-public-key> <password>
pve_write_cloudinit() {
    local host="$1" vmid="$2" guest_hostname="$3" sshkey="$4" password="$5"
    local remote="/tmp/ci-${vmid}.yaml"
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
    printf '%s\n' "${content}" | ssh_exec "${host}" "cat > '${remote}' && chmod 600 '${remote}'"
    printf '%s' "${remote}"
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
    pve_cmd "${host}" qm importdisk "${vmid}" "${image}" "${storage}"

    pve_cmd "${host}" qm set "${vmid}" \
        --scsi0 "${storage}:vm-${vmid}-disk-0,discard=on,iothread=1" \
        --efidisk0 "${storage}:1,efitype=4m,pre-enrolled-keys=1" \
        --boot "order=scsi0" \
        --ide2 "local:cloudinit" \
        --ipconfig0 "ip=dhcp" \
        --cicustom "${ciyaml}"
}

# Convert a VM into a template.
pve_vm_make_template() {
    local host="$1" vmid="$2"
    log_info "Converting VM ${vmid} into a template"
    pve_cmd "${host}" qm template "${vmid}"
}

# Clone a template. mode: full | linked
pve_vm_clone() {
    local host="$1" src="$2" newid="$3" name="$4" storage="$5" mode="$6"
    log_info "Cloning VM ${src} -> ${newid} (${name}, ${mode} clone)"
    if [ "${mode}" = "linked" ]; then
        pve_cmd "${host}" qm clone "${src}" "${newid}" --name "${name}" --full 0 --storage "${storage}"
    else
        pve_cmd "${host}" qm clone "${src}" "${newid}" --name "${name}" --full 1 --storage "${storage}"
    fi
}

# Apply the cloud-init configuration to a clone (clones inherit the drive but
# need their own hostname and credentials).
pve_vm_set_cloudinit() {
    local host="$1" vmid="$2" guest_hostname="$3" ciyaml="$4"
    pve_cmd "${host}" qm set "${vmid}" \
        --ide2 "local:cloudinit" \
        --ipconfig0 "ip=dhcp" \
        --cicustom "${ciyaml}"
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
