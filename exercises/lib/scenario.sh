# =============================================================================
# scenario.sh - the Nordwind Logistics target infrastructure
# =============================================================================
# Sourced by the exercise scripts. It defines the naming, the addressing plan
# and the inventory of the fictional company, so that every exercise talks
# about the same infrastructure and the students can see it grow.
#
# The scenario is described in docs/SCENARIO.md.
# =============================================================================

if [ -n "${__EX_SCENARIO_SOURCED:-}" ]; then
    return 0
fi
__EX_SCENARIO_SOURCED=1

# --- the company ------------------------------------------------------------
NW_COMPANY="Nordwind Logistics"
NW_DOMAIN="nordwind.example.com"

# --- the cluster ------------------------------------------------------------
NW_CLUSTER_NAME="prod-cluster"
NW_NODE_NAMES="pve1 pve2 pve3"

# --- the network ------------------------------------------------------------
#
# The lab uses a private overlay per node, because AWS routes only to
# ENI-owned addresses. The Nordwind network plan is built on top of that:
# the tenant VLANs are carried as 802.1Q tags over the single vmbr0 bridge.
#
NW_MGMT_VLAN=10
NW_WEB_VLAN=20
NW_APP_VLAN=30
NW_DB_VLAN=40
NW_OPS_VLAN=50

NW_MGMT_CIDR="10.10.10.0/24"
NW_WEB_CIDR="10.10.20.0/24"
NW_APP_CIDR="10.10.30.0/24"
NW_DB_CIDR="10.10.40.0/24"
NW_OPS_CIDR="10.10.50.0/24"

NW_BRIDGE="vmbr0"

# --- the storage ------------------------------------------------------------
NW_STORAGE_LOCAL="local-lvm"     # node local, fast
NW_STORAGE_SHARED="nfs-lab"      # shared, enables live migration and HA
NW_STORAGE_BACKUP="pbs-main"     # backup target

# --- the guests -------------------------------------------------------------
#
# The web tier is a VM (it needs to be migrated between nodes and to run in
# HA). The application tier and the database tier are containers: they are
# Linux-only, they are trusted and they want a high density.
#
NW_VM_IDS="100 101"                          # web tier
NW_VM_NAMES="web01 web02"
NW_VM_TEMPLATE_ID="9000"
NW_VM_TEMPLATE_NAME="debian13-template"
NW_VM_TEST_ID="102"
NW_VM_TEST_NAME="web-test"

NW_CT_IDS="300 301 302"
NW_CT_NAMES="app01 db01 cache01"

NW_WEB_VM_ID="100"
NW_APP_CT_ID="300"
NW_DB_CT_ID="301"
NW_CACHE_CT_ID="302"

# --- the identities ---------------------------------------------------------
#
# The deck uses an Active Directory realm. The lab has no directory server,
# so the built-in 'pve' realm type is used under the deck's name. The
# commands are identical.
#
NW_REALM="ad-corp"
NW_USER="${NW_USER:-jsmith@ad-corp}"
NW_ROLE="VM-Operator"
NW_ROLE_PRIVS="VM.Console,VM.PowerMgmt,VM.Monitor"
NW_TOKEN_USER="automation@pve"
NW_TOKEN_NAME="terraform"

# --- the HA groups ----------------------------------------------------------
NW_HA_GROUP="prod-nodes"
NW_HA_GROUP_NODES="pve1,pve2,pve3"

# --- the backup schedule ----------------------------------------------------
NW_BACKUP_SCHEDULE="daily"
NW_BACKUP_RETENTION_DAILY=7
NW_BACKUP_RETENTION_WEEKLY=4
NW_BACKUP_RETENTION_MONTHLY=6

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# The cloud-init snippet for a Nordwind guest. Every guest gets the same
# baseline: the guest agent, a hostname and a marker file that the exercises
# use to tell a managed guest from a hand-made one.
nw_cloudinit() {
    local hostname="$1"
    local password="${2:-}"
    local sshkey="${3:-}"

    cat << EOF
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.${NW_DOMAIN}
manage_etc_hosts: true
ssh_pwauth: true
$( [ -n "${password}" ] && printf "chpasswd:\n  expire: false\n  users:\n    - name: root\n      passwd: '%s'\n      type: text\n" "${password}" )
$( [ -n "${sshkey}" ] && printf "  - name: root\n    ssh_authorized_keys:\n      - %s\n" "${sshkey}" )
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ sh, -c, "printf 'nordwind-logistics\n' > /etc/nordwind-role" ]
EOF
}

# The name of a Nordwind service directory. The students create this for the
# "infrastructure as code" part of the long exercise.
nw_service_name() {
    printf 'nordwind-%s' "$1"
}
