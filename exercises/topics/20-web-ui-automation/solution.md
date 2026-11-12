# Solution - Topic 20: The API and Automation

**Topic ID:** `20-web-ui-automation`

> **Instructor material.**

---

## 1. The API without a token

The version endpoint needs no authentication:

```bash
curl -sk https://localhost:8006/api2/json/version | jq .
```

```json
{
  "data": {
    "release": "9.2",
    "repoid": "8b3a4b2c",
    "version": "9.2.3"
  }
}
```

Everything else needs a credential.

## 2. Create the token

```bash
pveum user token add automation@pve terraform --privsep 1
```

```
Token ID                     Value
automation@pve!terraform     1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
```

> **The secret is shown once.** It is stored hashed in
> `/etc/pve/priv/tokens/`. It cannot be read again - only rotated:
> ```bash
> pveum user token modify automation@pve terraform --new-value
> ```

Then the ACL:

```bash
pveum acl modify /vms/9201 --tokens 'automation@pve!terraform' --roles VM-Operator
```

## 3. Use it

```bash
export PVE_TOKEN='automation@pve!terraform=1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d'

# The cluster resources
curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/cluster/resources" | jq '.data[] | {vmid, type, node, name}'
```

```json
{
  "vmid": 9201,
  "type": "qemu",
  "node": "pve1",
  "name": "debian13-run-pve1"
}
```

```bash
# The configuration of VM 9201
curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/nodes/$(hostname)/qemu/100/config" | jq '.data | {name, cores, memory}'
```

```json
{
  "name": "debian13-run-pve1",
  "cores": 2,
  "memory": 4096
}
```

### The same with pvesh

```bash
pvesh get /cluster/resources --output-format json | jq '.[] | {vmid, type, node}'
pvesh get /nodes/$(hostname)/qemu/100/config --output-format json | jq '{name, cores, memory}'
```

`pvesh` runs as root on the node, so it uses the node's own identity - the
`root@pam`. To use the token with `pvesh`, put it in the environment and
`pvesh` picks it up:

```bash
export PVE_TOKEN='automation@pve!terraform=...'
pvesh get /cluster/resources
```

## 4. Show the limit of the token

The token is scoped to `/vms/9201`. It cannot read the container:

```bash
curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/nodes/$(hostname)/lxc/301/config" | jq .
```

```json
{
  "data": null,
  "errors": {
    "command": "Permission check failed (/nodes/pve1/lxc/301/config)"
  }
}
```

That error is the point. The automation identity can only see what it was
granted.

```bash
# The same with a token without privilege separation
pveum user token add automation@pve terraform-full
pveum acl modify /vms/9201 --tokens 'automation@pve!terraform-full' --roles VM-Operator
# -> the token can now read everything, because it inherits the user's rights
```

## 5. The API structure

```bash
# The top level
curl -sk "https://$(hostname):8006/api2/json/" | jq '.data[] | {path, text}'
```

```json
{ "path": "cluster", "text": "cluster" }
{ "path": "nodes", "text": "nodes" }
{ "path": "access", "text": "access" }
{ "path": "storage", "text": "storage" }
{ "path": "version", "text": "version" }
```

```bash
# The cluster sub-tree
curl -sk "https://$(hostname):8006/api2/json/cluster" | jq '.data[] | .path'
```

```
backup
firewall
flags
ha
log
metrics
nextid
notices
options
resources
sdn
status
```

### The verbs in `pvesh`

```bash
# GET
pvesh get /cluster/resources

# POST
pvesh create /cluster/backup --storage pbs-main --vmid 9201 --schedule daily

# PUT
pvesh set /cluster/firewall/options --enable 1 --policy_in DROP

# DELETE
pvesh delete /cluster/backup/backup-abcdef
```

## 6. A script that uses the API

```bash
#!/bin/bash
# nordwind-status.sh - the cluster status, as JSON, for a monitoring system.
set -euo pipefail

PVE_HOST="${PVE_HOST:-pve1}"
PVE_TOKEN="${PVE_TOKEN:?the API token is required}"

api() {
    curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
         "https://${PVE_HOST}:8006/api2/json${1}"
}

api /cluster/status | jq -r '
    .data[] | select(.type=="node") |
    "\(.name)\t\(.status)\tuptime=\(.uptime // 0)"'

echo "---"

api /cluster/resources | jq -r '
    .data[] | select(.type=="qemu" or .type=="lxc") |
    "\(.vmid)\t\(.name)\t\(.node)\t\(.status)"'
```

```bash
chmod +x nordwind-status.sh
PVE_TOKEN='...' ./nordwind-status.sh
```

```
pve1	online	uptime=86400
pve2	online	uptime=86400
pve3	online	uptime=86400
---
9201	debian13-run-pve1	pve1	running
9202	debian13-run-pve2	pve2	running
300	app01	pve1	running
301	db01	pve2	running
```

## 7. Terraform

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint    = "https://pve1:8006/"
  api_token  = var.proxmox_token
  insecure    = true
}

variable "proxmox_token" {
  type      = string
  sensitive = true
}

resource "proxmox_virtual_environment_vm" "web03" {
  node_name   = "pve1"
  vm_id       = 110
  name        = "web03"
  description = "managed by terraform"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "nfs-lab"
    file_id      = "debian-13-generic-amd64.qcow2"
    import_from  = "download"
  }

  network_device {
    bridge = "vmbr0"
    tag    = 20
  }
}
```

```bash
terraform init
terraform plan
terraform apply
```

> **The token goes into the secret manager, not into the repository.**
> Terraform reads it from an environment variable or from a secret store -
> never from a committed `.tfvars` file.

## 8. Ansible

```yaml
---
- name: Manage the Nordwind web tier
  hosts: pve
  gather_facts: false
  vars:
    proxmox_api_host: pve1
    proxmox_api_user: "automation@pve!terraform"
    proxmox_api_token: "{{ lookup('env', 'PROXMOX_TOKEN') }}"

  tasks:
    - name: Start the web tier
      community.general.proxmox_kvm:
        api_host: "{{ proxmox_api_host }}"
        api_user: "{{ proxmox_api_user }}"
        api_token: "{{ proxmox_api_token }}"
        vmid: 110
        state: started

    - name: Back up the web tier
      community.general.proxmox_kvm:
        api_host: "{{ proxmox_api_host }}"
        api_user: "{{ proxmox_api_user }}"
        api_token: "{{ proxmox_api_token }}"
        vmid: 110
        backup: true
        backup_dir: /var/tmp/vzdump-qemu-110
```

## 9. The complete sequence

```bash
# The token
pveum user token add automation@pve terraform --privsep 1
pveum acl modify /vms/9201 --tokens 'automation@pve!terraform' --roles VM-Operator

# The use
export PVE_TOKEN='automation@pve!terraform=<the secret>'

curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/cluster/resources" | jq '.data[] | {vmid, name}'

# The limit
curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/nodes/$(hostname)/lxc/301/config" | jq '.errors'
```

## 10. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `Authentication failure` | The secret was truncated | Copy the whole value |
| `Permission check failed` | The token has no ACL entry | `pveum acl modify ... --tokens` |
| The token can do everything | `--privsep` was not set | Delete it and recreate it |
| `curl: (60)` or a certificate error | The certificate is self-signed | `-k`, or install the cluster certificate |
| The token secret cannot be read again | By design | It is stored hashed; rotate it |
| The token is in the shell history | It was exported on the command line | Use a secret manager or a file with mode 600 |
| Terraform says "401 Unauthorized" | The token format is wrong | `user@realm!tokenid=secret` |
