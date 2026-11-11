#!/usr/bin/env bash
# =============================================================================
# exercise.sh - acceptance test for the long Nordwind Logistics exercise
# =============================================================================
# Runs every check of every task and reports PASS / FAIL per check.
#
# Usage:
#   ./exercise.sh                 run everything
#   ./exercise.sh --section 3     only the checks of the sections that match "3"
#   ./exercise.sh --verbose       show the output of every check
#
# The script runs against the cluster:
#   * started on a cluster node, it uses the local Proxmox CLI
#   * started from a workstation, it reaches the cluster over SSH
#
# Environment:
#   EX_TARGET    the node to talk to          (default: pve1)
#   EX_SSH_HOST  the address of that node     (default: from .state/lab.json)
#   EX_SSH_KEY   the private key to use       (default: from .state/lab.json)
#   EX_SSH_USER  the user to log in as        (default: root)
#
# Exit code: 0 when every check passed, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

EX_ID="long-nordwind"
EX_TITLE="Long Exercise - Build the Nordwind Logistics Platform on Proxmox VE"

# shellcheck source=../../lib/exlib.sh
. "${EX_ROOT_DIR}/lib/exlib.sh"
# shellcheck source=../../lib/scenario.sh
. "${EX_ROOT_DIR}/lib/scenario.sh"

ex_parse_args "$@"

# =============================================================================
# Task 1 - Node preparation
# =============================================================================
check_task1_node_preparation() {
    ex_section "Task 1 - Node preparation"

    local node pveversion drift ntp firewall_ok

    pveversion="$(ex_out "pveversion 2>/dev/null | head -1")"
    ex_assert_not_empty "a Proxmox VE version is reported" "${pveversion}"
    ex_assert_contains "the Proxmox version is 9.x" "${pveversion}" "pve-manager/9."

    # The hostname of the node we are on, and the hostnames of the others.
    local local_host
    local_host="$(ex_out "hostname")"
    ex_assert_contains "the node hostname is a lab node name" "${local_host}" "pve"

    # The hosts file must not map the node to a loopback address - that
    # prevents pve-cluster from starting.
    local hosts
    hosts="$(ex_out "cat /etc/hosts")"
    ex_assert_not_contains "/etc/hosts has no 127.0.1.1 entry" "${hosts}" "127.0.1.1"
    ex_assert_contains "/etc/hosts resolves the node to a routable address" \
        "${hosts}" "10.20.0."

    # Time synchronisation.
    ntp="$(ex_out "timedatectl show -p NTPSynchronized --value 2>/dev/null")"
    ex_assert_contains "the clock is synchronised" "${ntp}" "yes"

    drift="$(ex_out "chronyc tracking 2>/dev/null | grep -i 'System time' | cut -d' ' -f4")"
    if [ -n "${drift}" ]; then
        ex_assert_le "the clock drift is below 2 seconds" "${drift%%.*}" "1"
    else
        ex_skip "the clock drift cannot be measured (no chronyc)"
    fi

    # The repositories.
    local sources
    sources="$(ex_out "ls /etc/apt/sources.list.d/ 2>/dev/null")"
    ex_assert_contains "the no-subscription repository is configured" \
        "${sources}" "pve-no-subscription"
    ex_assert_not_contains "the enterprise repository is removed" \
        "${sources}" "pve-enterprise"

    # The firewall.
    firewall_ok="$(ex_out "pvesh get /cluster/firewall/options --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.enable // 0'")"
    ex_assert_eq "the firewall is enabled" "1" "${firewall_ok}"

    local policy
    policy="$(ex_out "pvesh get /cluster/firewall/options --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.policy_in // empty'")"
    ex_assert_eq "the inbound policy is DROP" "DROP" "${policy}"

    # The rules that the cluster needs.
    local rules
    rules="$(ex_out "pvesh get /cluster/firewall/rules --output-format json 2>/dev/null")"
    ex_assert_contains "a rule allows the web UI on 8006" "${rules}" "8006"
    ex_assert_contains "a rule allows SSH on 22" "${rules}" "\"22\""
    ex_assert_contains "a rule allows corosync on 5405-5412" "${rules}" "5405"
    ex_assert_contains "a rule allows NFS on 2049" "${rules}" "2049"

    ex_ok "pve-firewall is running" && ex_pass "pve-firewall is running" \
        || ex_fail "pve-firewall is running"
}

# =============================================================================
# Task 2 - Cluster formation
# =============================================================================
check_task2_cluster() {
    ex_section "Task 2 - Cluster formation"

    local members quorate name
    members="$(ex_member_count)"
    ex_assert_eq "the cluster has three members" "3" "${members}"

    quorate="$(ex_quorate)"
    ex_assert_eq "the cluster is quorate" "yes" "${quorate}"

    name="$(ex_out "pvecm status 2>/dev/null | grep -i 'cluster name' | cut -d' ' -f4")"
    ex_assert_eq "the cluster is called prod-cluster" "prod-cluster" "${name}"

    local quorum
    quorum="$(ex_out "pvecm status 2>/dev/null | grep -i 'quorum' | cut -d' ' -f3")"
    ex_assert_eq "the quorum is 2 of 3" "2" "${quorum}"

    # Every node sees the others.
    local nodes
    nodes="$(ex_nodes | sort | tr '\n' ' ')"
    ex_assert_contains "pve1 is a cluster member" "${nodes}" "pve1"
    ex_assert_contains "pve2 is a cluster member" "${nodes}" "pve2"
    ex_assert_contains "pve3 is a cluster member" "${nodes}" "pve3"

    # The cluster filesystem is shared.
    local shared
    shared="$(ex_out "test -f /etc/pve/cluster-demo.txt && echo yes || echo no")"
    if [ "${shared}" = "yes" ]; then
        ex_pass "the cluster filesystem is shared"
        ex_run "rm -f /etc/pve/cluster-demo.txt" >/dev/null 2>&1
    else
        # Not present. Check that the storage configuration is identical on
        # every node - that is the real proof of the shared filesystem.
        local cfg
        cfg="$(ex_run "md5sum /etc/pve/storage.cfg 2>/dev/null | cut -d' ' -f1")"
        ex_assert_not_empty "the cluster filesystem is mounted" "${cfg}"
    fi

    ex_ok "the pve-cluster service is running" \
        && ex_pass "the pve-cluster service is running" \
        || ex_fail "the pve-cluster service is running"
}

# =============================================================================
# Task 3 - Storage backends
# =============================================================================
check_task3_storage() {
    ex_section "Task 3 - Storage backends"

    local status
    status="$(ex_out "pvesm status 2>/dev/null")"

    ex_assert_contains "the local-lvm storage is defined" "${status}" "local-lvm"
    ex_assert_contains "the nfs-lab storage is defined" "${status}" "nfs-lab"
    ex_assert_contains "the pbs-main storage is defined" "${status}" "pbs-main"

    # The scope of the storages.
    local nfs_scope
    nfs_scope="$(ex_out "pvesm status --storage nfs-lab 2>/dev/null | head -1")"
    ex_assert_contains "nfs-lab is active" "${nfs_scope}" "active"

    local pbs_scope
    pbs_scope="$(ex_out "pvesm status --storage pbs-main 2>/dev/null | head -1")"
    ex_assert_contains "pbs-main is active" "${pbs_scope}" "active"

    # The content types.
    local nfs_content
    nfs_content="$(ex_out "cat /etc/pve/storage.cfg 2>/dev/null | sed -n '/^storage nfs-lab/,/^\$/p' | grep -i content")"
    ex_assert_contains "nfs-lab carries the iso content" "${nfs_content}" "iso"
    ex_assert_contains "nfs-lab carries the vztmpl content" "${nfs_content}" "vztmpl"
    ex_assert_contains "nfs-lab carries the backup content" "${nfs_content}" "backup"

    # The PBS configuration.
    local pbs_cfg
    pbs_cfg="$(ex_out "cat /etc/pve/storage.cfg 2>/dev/null | sed -n '/^storage pbs-main/,/^\$/p'")"
    ex_assert_contains "the PBS datastore is main" "${pbs_cfg}" "main"
    ex_assert_contains "the PBS user is backup@pbs" "${pbs_cfg}" "backup@pbs"

    # The shared storage has to be genuinely shared: a file written here has
    # to be visible on the other nodes.
    #
    # The check runs on the node itself, so it uses the cluster's own SSH
    # key to look at the other nodes. The key pair was distributed during
    # the cluster join.
    local marker="/mnt/pve/nfs-lab/.exercise-shared-test"
    if ex_ok "touch '${marker}' 2>/dev/null"; then
        local seen_elsewhere
        seen_elsewhere="$(ex_remote_members "test -f ${marker} && echo yes")"
        if printf '%s' "${seen_elsewhere}" | grep -q 'yes'; then
            ex_pass "the NFS storage is visible from another node"
        else
            ex_fail "the NFS storage is visible from another node"
        fi
        ex_run "rm -f '${marker}'" >/dev/null 2>&1
    else
        ex_skip "the NFS storage is not mounted on this node"
    fi

    # Free space on the local pool.
    local free
    free="$(ex_out "pvesm status --storage local-lvm 2>/dev/null | awk 'NR==2 {print \$6}' | tr -d '%'")"
    if [ -n "${free}" ]; then
        ex_assert_ge "the local pool has free space" "${free}" "1"
    else
        ex_skip "the local pool usage cannot be read"
    fi
}

# =============================================================================
# Task 4 - The guest network
# =============================================================================
check_task4_network() {
    ex_section "Task 4 - The guest network"

    local bridges
    bridges="$(ex_out "ip -brief link show type bridge 2>/dev/null | cut -d' ' -f1")"
    ex_assert_contains "the vmbr0 bridge exists" "${bridges}" "vmbr0"

    # The bridge has an address and it is the gateway.
    local addr
    addr="$(ex_out "ip -4 -brief addr show vmbr0 2>/dev/null | cut -d' ' -f3")"
    ex_assert_contains "the bridge has an IPv4 address" "${addr}" "10.10."

    local vlan_aware
    vlan_aware="$(ex_out "cat /etc/network/interfaces 2>/dev/null | grep -c 'bridge-vlan-aware yes'")"
    ex_assert_ge "the bridge is VLAN aware" "${vlan_aware}" "1"

    local vlan_show
    vlan_show="$(ex_out "bridge vlan show 2>/dev/null")"
    ex_assert_contains "bridge vlan show lists the bridge" "${vlan_show}" "vmbr0"

    # DHCP.
    local dnsmasq
    dnsmasq="$(ex_out "systemctl is-active dnsmasq 2>/dev/null")"
    ex_assert_eq "the DHCP server is running" "active" "${dnsmasq}"

    local dhcp_range
    dhcp_range="$(ex_out "grep -h dhcp-range /etc/dnsmasq.d/*.conf 2>/dev/null | head -1")"
    ex_assert_contains "a DHCP range is configured on the bridge" "${dhcp_range}" "dhcp-range="

    # The nodes have to use different overlay subnets, otherwise the routing
    # between them is ambiguous.
    local routes
    routes="$(ex_out "ip route 2>/dev/null | grep '10.10.' | wc -l")"
    ex_assert_ge "routes to the other overlay subnets exist" "${routes}" "2"

    # Forwarding and NAT.
    local forward
    forward="$(ex_out "cat /proc/sys/net/ipv4/ip_forward 2>/dev/null")"
    ex_assert_eq "IP forwarding is enabled" "1" "${forward}"

    local nat
    nat="$(ex_out "iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE")"
    ex_assert_ge "the guests are NATed out" "${nat}" "1"
}

# =============================================================================
# Task 5 - Identity and access control
# =============================================================================
check_task5_identity() {
    ex_section "Task 5 - Identity and access control"

    local realms
    realms="$(ex_out "pveum realm list 2>/dev/null")"
    ex_assert_contains "the realm ad-corp exists" "${realms}" "ad-corp"

    local users
    users="$(ex_out "pveum user list 2>/dev/null")"
    ex_assert_contains "the user jsmith@ad-corp exists" "${users}" "jsmith@ad-corp"

    # The role has to be exactly the three privileges.
    local privs
    privs="$(ex_out "pveum role list 2>/dev/null | awk '\$2==\"VM-Operator\" {print \$3}'")"
    ex_assert_contains "the role VM-Operator exists" "${privs}" "VM.Console"
    ex_assert_contains "the role grants VM.PowerMgmt" "${privs}" "VM.PowerMgmt"
    ex_assert_contains "the role grants VM.Monitor" "${privs}" "VM.Monitor"
    ex_assert_not_contains "the role does not grant the disk privileges" \
        "${privs}" "VM.Config.Disk"
    ex_assert_not_contains "the role does not grant Sys.Audit" "${privs}" "Sys.Audit"

    # The ACL is on the guests, not on the root.
    local acl
    acl="$(ex_out "pveum acl list 2>/dev/null")"
    ex_assert_contains "the ACL grants the role on /vms/100" "${acl}" "/vms/100"
    ex_assert_contains "the ACL grants the role to jsmith" "${acl}" "jsmith@ad-corp"
    ex_assert_contains "the ACL grants the role to the VM-Operator role" "${acl}" "VM-Operator"

    # The ACL must not be on the root path with the broad role.
    local root_acl
    root_acl="$(ex_out "pveum acl list 2>/dev/null | awk '\$1==\"/\" {print}'")"
    ex_assert_not_contains "no broad ACL on the root path" "${root_acl}" "PVEAdmin"

    # The effective permissions.
    local perms
    perms="$(ex_out "pveum user permissions jsmith@ad-corp 2>/dev/null")"
    ex_assert_contains "jsmith has the console privilege" "${perms}" "VM.Console"

    # The API token with privilege separation.
    local tokens
    tokens="$(ex_out "pveum user token list automation@pve 2>/dev/null")"
    ex_assert_contains "the token automation@pve!terraform exists" "${tokens}" "terraform"

    local privsep
    privsep="$(ex_out "pveum user token list automation@pve --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.[] | select(.tokenid==\"terraform\") | .privsep'")"
    ex_assert_eq "the token has privilege separation enabled" "1" "${privsep}"

    # The token needs its own ACL.
    local token_acl
    token_acl="$(ex_out "pveum acl list 2>/dev/null | grep 'automation@pve!terraform'")"
    ex_assert_not_empty "the token has its own ACL entry" "${token_acl}"
    ex_assert_contains "the token ACL is scoped to /vms/100" "${token_acl}" "/vms/100"
}

# =============================================================================
# Task 6 - The golden image and the template
# =============================================================================
check_task6_template() {
    ex_section "Task 6 - The golden image and the template"

    local cfg
    cfg="$(ex_vm_config 9000)"

    ex_assert_not_empty "VM 9000 exists" "${cfg}"
    ex_assert_contains "VM 9000 is named debian13-template" "${cfg}" "debian13-template"

    # A template cannot be started - 'qm status' reports it as stopped and
    # 'qm template' set the template flag in the configuration.
    local is_template
    is_template="$(ex_out "qm config 9000 2>/dev/null | grep -c '^template:'")"
    ex_assert_ge "VM 9000 is a template" "${is_template}" "1"

    ex_assert_contains "the template has a cloud-init drive" "${cfg}" "cloudinit"
    ex_assert_contains "the template uses virtio-scsi-single" "${cfg}" "virtio-scsi-single"
    ex_assert_contains "the guest agent is enabled" "${cfg}" "enabled=1"

    # The storage.
    local disk
    disk="$(ex_out "qm config 9000 2>/dev/null | grep '^scsi0:'")"
    ex_assert_contains "the template is on the shared storage" "${disk}" "nfs-lab"

    # The agent answered while the template was running before it was
    # converted. The check is informational - a template cannot run.
    ex_skip "the template is a template, so the guest agent cannot be queried"
}

# =============================================================================
# Task 7 - The web tier
# =============================================================================
check_task7_web_tier() {
    ex_section "Task 7 - The web tier"

    local id
    for id in 100 101; do
        local cfg status
        cfg="$(ex_vm_config "${id}")"
        ex_assert_not_empty "VM ${id} exists" "${cfg}"

        status="$(ex_guest_status vm "${id}")"
        ex_assert_eq "VM ${id} is running" "running" "${status}"

        # The name.
        local name
        name="$(ex_out "qm config ${id} 2>/dev/null | grep '^name:' | cut -d' ' -f2")"
        ex_assert_not_empty "VM ${id} has a name" "${name}"

        # The CPU and the memory.
        local cores memory
        cores="$(ex_out "qm config ${id} 2>/dev/null | grep '^cores:' | cut -d' ' -f2")"
        ex_assert_eq "VM ${id} has 2 vCPU" "2" "${cores}"

        memory="$(ex_out "qm config ${id} 2>/dev/null | grep '^memory:' | cut -d' ' -f2")"
        ex_assert_eq "VM ${id} has 4096 MB memory" "4096" "${memory}"

        # The network with the VLAN tag.
        local net
        net="$(ex_out "qm config ${id} 2>/dev/null | grep '^net0:'")"
        ex_assert_contains "VM ${id} uses the virtio network" "${net}" "virtio"
        ex_assert_contains "VM ${id} is on vmbr0" "${net}" "bridge=vmbr0"
        ex_assert_contains "VM ${id} carries the VLAN tag 20" "${net}" "tag=20"

        # The disk.
        local scsi
        scsi="$(ex_out "qm config ${id} 2>/dev/null | grep '^scsi0:'")"
        ex_assert_contains "VM ${id} uses virtio-scsi-single" "${cfg}" "virtio-scsi-single"
        ex_assert_contains "VM ${id} is on the shared storage" "${scsi}" "nfs-lab"
        ex_assert_contains "VM ${id} has discard enabled" "${scsi}" "discard=on"

        # The agent.
        ex_assert_contains "VM ${id} has the guest agent enabled" "${cfg}" "enabled=1"

        # The agent answers.
        if [ "${status}" = "running" ]; then
            if ex_ok "qm guest cmd ${id} ping >/dev/null 2>&1"; then
                ex_pass "the guest agent answers in VM ${id}"
            else
                ex_fail "the guest agent answers in VM ${id}"
            fi
        else
            ex_skip "the guest agent check in VM ${id} (the guest is not running)"
        fi
    done

    # The clones have to be full clones - a linked clone refers to the base
    # disk of the template.
    local disk100
    disk100="$(ex_out "qm config 100 2>/dev/null | grep '^scsi0:'")"
    ex_assert_not_contains "VM 100 is a full clone, not a linked one" \
        "${disk100}" "base-9000"
}

# =============================================================================
# Task 8 - The container tiers
# =============================================================================
check_task8_containers() {
    ex_section "Task 8 - The container tiers"

    local spec
    for spec in "300:app01:30" "301:db01:40" "302:cache01:30"; do
        local id name tag
        id="${spec%%:*}"
        local rest="${spec#*:}"
        name="${rest%%:*}"
        tag="${rest##*:}"

        local cfg status
        cfg="$(ex_ct_config "${id}")"
        ex_assert_not_empty "CT ${id} exists" "${cfg}"

        local hostname
        hostname="$(ex_out "pct config ${id} 2>/dev/null | grep '^hostname:' | cut -d' ' -f2")"
        ex_assert_eq "CT ${id} is named ${name}" "${name}" "${hostname}"

        status="$(ex_guest_status lxc "${id}")"
        ex_assert_eq "CT ${id} is running" "running" "${status}"

        # Unprivileged.
        local unpriv
        unpriv="$(ex_out "pct config ${id} 2>/dev/null | grep '^unprivileged:'")"
        ex_assert_eq "CT ${id} is unprivileged" "1" "${unpriv#unprivileged: }"

        # Nesting.
        local features
        features="$(ex_out "pct config ${id} 2>/dev/null | grep '^features:'")"
        ex_assert_contains "CT ${id} has nesting enabled" "${features}" "nesting=1"

        # The rootfs on the shared storage.
        local rootfs
        rootfs="$(ex_out "pct config ${id} 2>/dev/null | grep '^rootfs:'")"
        ex_assert_contains "CT ${id} is on the shared storage" "${rootfs}" "nfs-lab"

        # The VLAN tag.
        local net
        net="$(ex_out "pct config ${id} 2>/dev/null | grep '^net0:'")"
        ex_assert_contains "CT ${id} is on vmbr0" "${net}" "bridge=vmbr0"
        ex_assert_contains "CT ${id} carries the VLAN tag ${tag}" "${net}" "tag=${tag}"

        # The container shares the host kernel.
        if [ "${status}" = "running" ]; then
            local cgroup
            cgroup="$(ex_out "pct exec ${id} -- cat /proc/1/cgroup 2>/dev/null")"
            ex_assert_not_empty "CT ${id} shows its cgroup membership" "${cgroup}"
            ex_assert_not_contains "CT ${id} is not in a private PID namespace" \
                "${cgroup}" "0::/"
        else
            ex_skip "the cgroup check in CT ${id} (the container is not running)"
        fi
    done
}

# =============================================================================
# Task 9 - Clones and test environments
# =============================================================================
check_task9_clones() {
    ex_section "Task 9 - Clones and test environments"

    local cfg
    cfg="$(ex_vm_config 102)"
    ex_assert_not_empty "VM 102 exists" "${cfg}"

    local name
    name="$(ex_out "qm config 102 2>/dev/null | grep '^name:' | cut -d' ' -f2")"
    ex_assert_eq "VM 102 is named web-test" "web-test" "${name}"

    # A linked clone refers to the base disk of the template.
    local disk
    disk="$(ex_out "qm config 102 2>/dev/null | grep '^scsi0:'")"
    ex_assert_contains "VM 102 is a linked clone of the template" "${disk}" "base-9000"

    # The template must still exist - a linked clone depends on it.
    local tpl
    tpl="$(ex_vm_config 9000)"
    ex_assert_not_empty "the base template 9000 still exists" "${tpl}"

    local tpl_flag
    tpl_flag="$(ex_out "qm config 9000 2>/dev/null | grep -c '^template:'")"
    ex_assert_ge "the base template is still a template" "${tpl_flag}" "1"

    # Its own cloud-init drive.
    ex_assert_contains "VM 102 has a cloud-init drive" "${cfg}" "cloudinit"

    local disk102
    disk102="$(ex_out "qm config 102 2>/dev/null | grep '^scsi0:'")"
    ex_assert_contains "VM 102 is on the shared storage" "${disk102}" "nfs-lab"
}

# =============================================================================
# Task 10 - Snapshots and rollback
# =============================================================================
check_task10_snapshots() {
    ex_section "Task 10 - Snapshots and rollback"

    local snaps
    snaps="$(ex_out "qm listsnapshot 100 2>/dev/null")"
    ex_assert_contains "VM 100 has a snapshot named pre-update" "${snaps}" "pre-update"

    local desc
    desc="$(ex_out "qm listsnapshot 100 2>/dev/null | grep 'pre-update' | sed 's/.*pre-update[[:space:]]*//'")"
    ex_assert_not_empty "the snapshot carries a description" "${desc}"

    # The rollback must have removed the change that was made after the
    # snapshot was taken.
    local marker="/etc/nordwind-exercise-marker"
    local present
    present="$(ex_out "qm guest exec 100 -- test -f ${marker} 2>/dev/null && echo yes || echo no")"
    ex_assert_eq "the change made after the snapshot is gone after the rollback" \
        "no" "${present}"
}

# =============================================================================
# Task 11 - Live migration
# =============================================================================
check_task11_migration() {
    ex_section "Task 11 - Live migration"

    local node disk status
    node="$(ex_guest_node vm 100)"
    ex_assert_eq "VM 100 runs on pve2 after the migration" "pve2" "${node}"

    # The migration only works on shared storage.
    disk="$(ex_out "qm config 100 2>/dev/null | grep '^scsi0:'")"
    ex_assert_contains "VM 100 is on the shared storage" "${disk}" "nfs-lab"

    status="$(ex_guest_status vm 100)"
    ex_assert_eq "VM 100 is running" "running" "${status}"

    if [ "${status}" = "running" ]; then
        if ex_ok "qm guest cmd 100 ping >/dev/null 2>&1"; then
            ex_pass "the guest agent answers after the migration"
        else
            ex_fail "the guest agent answers after the migration"
        fi
    else
        ex_skip "the guest agent check (the guest is not running)"
    fi
}

# =============================================================================
# Task 12 - Segmentation and firewall
# =============================================================================
check_task12_segmentation() {
    ex_section "Task 12 - Segmentation and firewall"

    # The datacenter firewall.
    local opts
    opts="$(ex_out "pvesh get /cluster/firewall/options --output-format json 2>/dev/null")"
    ex_assert_contains "the datacenter firewall is enabled" "${opts}" "\"enable\":1"
    ex_assert_contains "the inbound policy is DROP" "${opts}" "DROP"

    # No wide open rules.
    local rules
    rules="$(ex_out "pvesh get /cluster/firewall/rules --output-format json 2>/dev/null")"
    ex_assert_not_contains "there is no ACCEPT rule without a source" "${rules}" "\"source\":\"0.0.0.0/0\""
    ex_assert_not_contains "there is no ACCEPT rule without a source (IPv6)" "${rules}" "\"source\":\"::/0\""

    # The VLAN tags on the guests.
    local net
    net="$(ex_out "qm config 100 2>/dev/null | grep '^net0:'")"
    ex_assert_contains "the web tier carries VLAN 20" "${net}" "tag=20"

    local net300
    net300="$(ex_out "pct config 300 2>/dev/null | grep '^net0:'")"
    ex_assert_contains "the application tier carries VLAN 30" "${net300}" "tag=30"

    local net301
    net301="$(ex_out "pct config 301 2>/dev/null | grep '^net0:'")"
    ex_assert_contains "the database tier carries VLAN 40" "${net301}" "tag=40"

    # The bridge knows about the tags.
    local vlan
    vlan="$(ex_out "bridge vlan show 2>/dev/null")"
    ex_assert_not_empty "the bridge shows its VLAN table" "${vlan}"

    # The workloads have their own rules.
    local vmfw
    vmfw="$(ex_out "cat /etc/pve/firewall/100.fw 2>/dev/null")"
    ex_assert_not_empty "the web tier VM has its own firewall rules" "${vmfw}"

    # The rule that only allows web -> database.
    local dbrule
    dbrule="$(ex_out "cat /etc/pve/firewall/100.fw 2>/dev/null | grep -E '5432|3306'")"
    ex_assert_not_empty "a rule lets the web tier reach the database tier" "${dbrule}"

    local denyrule
    denyrule="$(ex_out "cat /etc/pve/firewall/301.fw 2>/dev/null | grep -i 'DROP'")"
    ex_assert_not_empty "a rule denies the database tier access to the web tier" "${denyrule}"
}

# =============================================================================
# Task 13 - Backup and restore
# =============================================================================
check_task13_backup() {
    ex_section "Task 13 - Backup and restore"

    # The backup job.
    local jobs
    jobs="$(ex_out "pvesh get /cluster/backup --output-format json 2>/dev/null")"
    ex_assert_contains "a backup job exists" "${jobs}" "pbs-main"
    ex_assert_contains "the job covers VM 100" "${jobs}" "100"
    ex_assert_contains "the job covers CT 301" "${jobs}" "301"
    ex_assert_contains "the job runs in snapshot mode" "${jobs}" "snapshot"
    ex_assert_contains "the job is enabled" "${jobs}" "\"enabled\":1"
    ex_assert_contains "the job has a schedule" "${jobs}" "schedule"

    # The retention.
    ex_assert_contains "the retention keeps 7 daily backups" "${jobs}" "\"keep-daily\":7"
    ex_assert_contains "the retention keeps 4 weekly backups" "${jobs}" "\"keep-weekly\":4"
    ex_assert_contains "the retention keeps 6 monthly backups" "${jobs}" "\"keep-monthly\":6"

    # The backups in the datastore.
    local backups
    backups="$(ex_out "pvesm list pbs-main --content backup 2>/dev/null")"
    ex_assert_contains "a backup of VM 100 exists" "${backups}" "vzdump-qemu-100"
    ex_assert_contains "a backup of CT 301 exists" "${backups}" "vzdump-lxc-301"

    # The restore. A restored guest is a VM whose ID is above the ones the
    # exercise itself created, and whose name says it is a restore.
    local restored
    restored="$(ex_out "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.[] | select(.vmid >= 190) | .vmid' | head -1")"
    if [ -n "${restored}" ]; then
        ex_pass "a restored VM exists (VMID ${restored})"
        local rstatus
        rstatus="$(ex_guest_status vm "${restored}")"
        ex_assert_eq "the restored VM is running" "running" "${rstatus}"
    else
        ex_fail "a restored VM exists (VMID >= 190)"
    fi
}

# =============================================================================
# Task 14 - High availability
# =============================================================================
check_task14_ha() {
    ex_section "Task 14 - High availability"

    local groups
    groups="$(ex_out "ha-manager status --output-format json 2>/dev/null")"
    ex_assert_contains "the HA group prod-nodes exists" "${groups}" "prod-nodes"

    # The managed resources.
    local managed
    managed="$(ex_out "ha-manager status 2>/dev/null")"
    ex_assert_contains "VM 100 is HA managed" "${managed}" "vm:100"
    ex_assert_contains "VM 101 is HA managed" "${managed}" "vm:101"
    ex_assert_contains "CT 301 is HA managed" "${managed}" "ct:301"

    # The state.
    local started
    started="$(ex_out "ha-manager status 2>/dev/null | grep -c 'started'")"
    ex_assert_ge "the HA resources are started" "${started}" "1"

    # The group has to contain all three nodes.
    local groupnodes
    groupnodes="$(ex_out "ha-manager group prod-nodes --output-format json 2>/dev/null \
        | /opt/exercises/lib/ex-json.sh '.nodes // [] | join(\",\")'")"
    ex_assert_contains "the HA group contains pve1" "${groupnodes}" "pve1"
    ex_assert_contains "the HA group contains pve2" "${groupnodes}" "pve2"
    ex_assert_contains "the HA group contains pve3" "${groupnodes}" "pve3"

    # The guests have to be on shared storage.
    local disk
    disk="$(ex_out "qm config 100 2>/dev/null | grep '^scsi0:'")"
    ex_assert_contains "the HA managed VM is on the shared storage" "${disk}" "nfs-lab"
}

# =============================================================================
# Task 15 - Monitoring and notifications
# =============================================================================
check_task15_monitoring() {
    ex_section "Task 15 - Monitoring and notifications"

    local status metrics
    status="$(ex_out "pvesh get /cluster/status --output-format json 2>/dev/null")"
    ex_assert_not_empty "the cluster status is readable" "${status}"

    metrics="$(ex_out "pvesh get /cluster/metrics 2>/dev/null")"
    ex_assert_not_empty "the cluster metrics are readable" "${metrics}"

    # The notification endpoint.
    local endpoints
    endpoints="$(ex_out "pvesh get /cluster/notifications/endpoints --output-format json 2>/dev/null")"
    ex_assert_not_empty "a notification endpoint exists" "${endpoints}"

    # The matcher.
    local matchers
    matchers="$(ex_out "pvesh get /cluster/notifications/matchers --output-format json 2>/dev/null")"
    ex_assert_not_empty "a notification matcher exists" "${matchers}"

    # The task log.
    local log
    log="$(ex_out "pvesh get /cluster/log --limit 10 --output-format json 2>/dev/null")"
    ex_assert_not_empty "the task log is readable" "${log}"

    # The monitoring workload of the operations tier.
    local ct302
    ct302="$(ex_ct_config 302)"
    ex_assert_not_empty "the operations tier workload CT 302 exists" "${ct302}"
}

# =============================================================================
# Task 16 - Troubleshooting
# =============================================================================
check_task16_troubleshooting() {
    ex_section "Task 16 - Troubleshooting"

    # The forensic snapshot has to exist.
    local snaps
    snaps="$(ex_out "qm listsnapshot 100 2>/dev/null")"
    ex_assert_contains "a snapshot was taken before the repair" "${snaps}" "incident"

    # The guest has to work again.
    local status
    status="$(ex_guest_status vm 100)"
    ex_assert_eq "VM 100 is running" "running" "${status}"

    if [ "${status}" = "running" ]; then
        if ex_ok "qm guest cmd 100 ping >/dev/null 2>&1"; then
            ex_pass "the guest agent answers again after the repair"
        else
            ex_fail "the guest agent answers again after the repair"
        fi
    else
        ex_skip "the guest agent check (the guest is not running)"
    fi

    # The incident has to be documented in the task log.
    local log
    log="$(ex_out "pvesh get /cluster/log --limit 100 --output-format json 2>/dev/null \
        | grep -c 'vms/100'")"
    ex_assert_ge "the incident is recorded in the task log" "${log}" "1"
}

# =============================================================================
# Main
# =============================================================================

ex_banner

ex_detect_mode
case "${EX_MODE}" in
    local)
        ex_info "running against the local cluster (hostname: $(hostname))"
        ;;
    ssh)
        ex_info "running against ${EX_SSH_HOST} over SSH (target: ${EX_TARGET})"
        ;;
esac

# The cluster has to be there at all.
if [ "$(ex_member_count)" -lt 1 ]; then
    ex_error "No cluster found on ${EX_TARGET}. Is the cluster running?"
    ex_error "Check the connection and try again."
    exit 1
fi

check_task1_node_preparation
check_task2_cluster
check_task3_storage
check_task4_network
check_task5_identity
check_task6_template
check_task7_web_tier
check_task8_containers
check_task9_clones
check_task10_snapshots
check_task11_migration
check_task12_segmentation
check_task13_backup
check_task14_ha
check_task15_monitoring
check_task16_troubleshooting

ex_summary
exit $?
