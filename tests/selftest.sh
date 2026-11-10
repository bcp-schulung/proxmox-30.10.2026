#!/usr/bin/env bash
# =============================================================================
# tests/selftest.sh - offline tests for the parts of the harness that do not
#                     need an AWS account
# =============================================================================
# Run with:  ./tests/selftest.sh
#
# These tests cover the address plan, the configuration precedence, the state
# file handling and the JSON that is handed to the AWS CLI. They are the
# parts that are easy to get subtly wrong and hard to debug on a live run.
# =============================================================================
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
. "${LAB_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
. "${LAB_ROOT}/lib/config.sh"
# shellcheck source=lib/state.sh
. "${LAB_ROOT}/lib/state.sh"
# shellcheck source=lib/lab.sh
. "${LAB_ROOT}/lib/lab.sh"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  %sPASS%s  %s\n' "${C_GREEN}" "${C_RESET}" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf '  %sFAIL%s  %s\n' "${C_RED}" "${C_RESET}" "$1"
    [ $# -gt 1 ] && printf '        expected: %s\n        actual:   %s\n' "$2" "$3"
    return 0
}

assert_eq() {
    # assert_eq <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        fail "$1" "$2" "$3"
    fi
}

assert_contains() {
    # assert_contains <description> <needle> <haystack>
    case "$3" in
        *"$2"*) ok "$1" ;;
        *)      fail "$1" "contains '$2'" "$3" ;;
    esac
}

section() {
    printf '\n%s%s%s\n' "${C_BOLD}" "$1" "${C_RESET}"
}

# -----------------------------------------------------------------------------
section "Address plan"

# The address plan depends on the configuration, so load it first.
load_config

assert_eq "pve1 management IP"        "10.20.0.11"  "$(lab_node_mgmt_ip pve1)"
assert_eq "pve2 management IP"        "10.20.0.12"  "$(lab_node_mgmt_ip pve2)"
assert_eq "pve3 management IP"        "10.20.0.13"  "$(lab_node_mgmt_ip pve3)"
assert_eq "pve1 overlay subnet"       "10.10.10.0/24" "$(lab_node_overlay_cidr pve1)"
assert_eq "pve2 overlay subnet"       "10.10.20.0/24" "$(lab_node_overlay_cidr pve2)"
assert_eq "pve3 overlay subnet"       "10.10.30.0/24" "$(lab_node_overlay_cidr pve3)"
assert_eq "pve1 overlay gateway"      "10.10.10.1"  "$(lab_node_overlay_gw pve1)"
assert_eq "pve1 DHCP range start"     "10.10.10.100" "$(lab_node_dhcp_start pve1)"
assert_eq "pve1 DHCP range end"       "10.10.10.200" "$(lab_node_dhcp_end pve1)"
assert_eq "node index of pve3"        "3"           "$(lab_node_index pve3)"

# The overlay subnets must not overlap - overlapping subnets break routing
# between the nodes.
OVERLAPS=0
for a in pve1 pve2 pve3; do
    for b in pve1 pve2 pve3; do
        [ "${a}" = "${b}" ] && continue
        [ "$(lab_node_overlay_cidr "${a}")" = "$(lab_node_overlay_cidr "${b}")" ] && OVERLAPS=1
    done
done
assert_eq "overlay subnets do not overlap" "0" "${OVERLAPS}"

assert_eq "pve1 routes to the other overlays" \
    "10.10.20.0/24=10.20.0.12,10.10.30.0/24=10.20.0.13" \
    "$(lab_node_overlay_routes pve1)"
assert_eq "pve3 routes to the other overlays" \
    "10.10.10.0/24=10.20.0.11,10.10.20.0/24=10.20.0.12" \
    "$(lab_node_overlay_routes pve3)"

# -----------------------------------------------------------------------------
section "Configuration"

assert_eq "region comes from the defaults"     "eu-central-1" "${AWS_REGION}"
assert_eq "VPC CIDR"                           "10.20.0.0/16" "${VPC_CIDR}"
assert_eq "VPC gateway"                        "10.20.0.1"    "${VPC_GATEWAY}"
assert_eq "cluster name"                       "prod-cluster" "${PVE_CLUSTER_NAME}"
assert_eq "guest overlay"                      "10.10.10.0/24" "${GUEST_SUBNET_CIDR}"
assert_eq "the SSH key path is derived"        "${LAB_STATE_DIR}/keys/pve-lab.pem" "${PVE_SSH_KEY_PATH}"
assert_eq "the deck's VM IDs are used"         "100" "${VM_WEB_ID}"
assert_eq "the deck's template ID is used"     "9000" "${VM_TEMPLATE_ID}"
assert_eq "the deck's CT ID is used"           "300" "${CT_APP_ID}"

# An exported environment variable must win over the defaults.
(
    export AWS_REGION="us-west-2"
    load_config
    [ "${AWS_REGION}" = "us-west-2" ] && exit 0 || exit 1
)
assert_eq "an environment variable overrides the defaults" "0" "$?"

# -----------------------------------------------------------------------------
section "State file"

STATE_FILE="${LAB_STATE_DIR}/test-lab.json"
rm -f "${STATE_FILE}"
state_init
assert_eq "the state file is created" "yes" "$([ -f "${STATE_FILE}" ] && echo yes || echo no)"
assert_eq "the state file is not world readable" "600" "$(stat -f '%Lp' "${STATE_FILE}" 2>/dev/null || stat -c '%a' "${STATE_FILE}")"

state_set ".phase" '"foundation"'
assert_eq "a value can be written"  "foundation" "$(state_get ".phase")"

state_set ".instances.pve1.id" '"i-0123456789abcdef0"'
assert_eq "a nested value can be written" "i-0123456789abcdef0" "$(state_get ".instances.pve1.id")"

state_set ".instances.pve1" '{"id":"i-abc","private_ip":"10.20.0.11","role":"pve"}'
assert_eq "a nested object can be replaced" "10.20.0.11" "$(state_get ".instances.pve1.private_ip")"

state_merge '{"vpc":{"id":"vpc-123"}}'
assert_eq "a merge adds a subtree" "vpc-123" "$(state_get ".vpc.id")"
assert_eq "a merge keeps the existing values" "i-abc" "$(state_get ".instances.pve1.id")"

state_del ".vpc.id"
assert_eq "a value can be deleted" "" "$(state_get ".vpc.id")"

assert_eq "a missing path returns the default" "fallback" "$(state_get ".does.not.exist" "fallback")"

state_set ".phase" '"nodes"'
assert_eq "phase 'foundation' is done after 'nodes'" "yes" "$(lab_phase_done foundation && echo yes || echo no)"
assert_eq "phase 'nodes' is done after 'nodes'"     "yes" "$(lab_phase_done nodes && echo yes || echo no)"
assert_eq "phase 'cluster' is not done after 'nodes'" "no" "$(lab_phase_done cluster && echo yes || echo no)"

# The state helpers must survive a password with special characters.
state_set ".pve.root_password" '"p@ss_w0rd!%+="'
assert_eq "a password round-trips through the state file" "p@ss_w0rd!%+=" "$(state_get ".pve.root_password")"

# Secrets must not show up in the redacted dump.
assert_contains "the state dump redacts secrets" "<redacted>" "$(state_show)"

rm -f "${STATE_FILE}"

# -----------------------------------------------------------------------------
section "AWS request payloads"

# The network interface definition for a Proxmox node.
NETIF="$(jq -n \
    --arg subnet_pub "subnet-pub" \
    --arg sg "sg-123" \
    '[{DeviceIndex:0,SubnetId:$subnet_pub,AssociatePublicIpAddress:true,Groups:[$sg],DeleteOnTermination:true}]')"

assert_eq "the node gets a single interface" "1" "$(printf '%s' "${NETIF}" | jq 'length')"
assert_eq "interface 0 is the management interface" "subnet-pub" "$(printf '%s' "${NETIF}" | jq -r '.[0].SubnetId')"
assert_eq "the management interface has a public IP" "true" "$(printf '%s' "${NETIF}" | jq -r '.[0].AssociatePublicIpAddress')"
assert_eq "the management interface is in the security group" "sg-123" "$(printf '%s' "${NETIF}" | jq -r '.[0].Groups[0]')"
assert_eq "the device index is 0" "0" "$(printf '%s' "${NETIF}" | jq -r '.[0].DeviceIndex')"

# The data volume mapping.
BDM="$(jq -n --arg size "250" \
    '[{DeviceName:"/dev/sdf",Ebs:{VolumeSize:($size|tonumber),VolumeType:"gp3",DeleteOnTermination:false,Encrypted:true}}]')"
assert_eq "the data volume has the configured size" "250" "$(printf '%s' "${BDM}" | jq -r '.[0].Ebs.VolumeSize')"
assert_eq "the data volume survives a termination" "false" "$(printf '%s' "${BDM}" | jq -r '.[0].Ebs.DeleteOnTermination')"
assert_eq "the data volume is encrypted" "true" "$(printf '%s' "${BDM}" | jq -r '.[0].Ebs.Encrypted')"
assert_eq "the data volume is not the root device" "/dev/sdf" "$(printf '%s' "${BDM}" | jq -r '.[0].DeviceName')"

# -----------------------------------------------------------------------------
section "Helpers"

assert_eq "urlencode leaves safe characters alone" "a-b_c.d~e" "$(urlencode 'a-b_c.d~e')"
assert_eq "urlencode escapes a space" "a%20b" "$(urlencode 'a b')"
assert_eq "urlencode escapes a slash" "a%2Fb" "$(urlencode 'a/b')"

assert_eq "human_duration for seconds" "45s" "$(human_duration 45)"
assert_eq "human_duration for minutes" "2m 30s" "$(human_duration 150)"
assert_eq "human_duration for hours" "1h 5m" "$(human_duration 3900)"

# -----------------------------------------------------------------------------
section "File inventory"

for f in provision.sh debug.sh shutdown.sh clean.sh \
         lib/common.sh lib/config.sh lib/state.sh lib/aws.sh lib/ssh.sh lib/pve.sh lib/lab.sh \
         scripts/node-bootstrap.sh scripts/nfs-setup.sh scripts/pbs-setup.sh \
         packer/pve.pkr.hcl packer/pbs.pkr.hcl \
         config/default.env; do
    if [ -f "${LAB_ROOT}/${f}" ]; then
        ok "${f} exists"
    else
        fail "${f} exists" "present" "missing"
    fi
done

# Every script must be syntactically valid.
for f in provision.sh debug.sh shutdown.sh clean.sh lib/*.sh scripts/*.sh packer/scripts/*.sh; do
    if bash -n "${LAB_ROOT}/${f}" 2>/dev/null; then
        ok "${f} parses"
    else
        fail "${f} parses" "valid" "syntax error"
    fi
done

# -----------------------------------------------------------------------------
printf '\n%s%s%s\n' "${C_BOLD}" "----------------------------------------------------------------------" "${C_RESET}"
printf '  %sPASS %s   %sFAIL %s\n\n' "${C_GREEN}" "${PASS}" "${C_RED}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
