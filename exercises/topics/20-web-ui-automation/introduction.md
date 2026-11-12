# Topic 20 - The API and Automation

**Topic ID:** `20-web-ui-automation`
**Course reference:** Proxmox VE Introduction, Day 1 §5 and Proxmox VE
Security, Day 1 §6
**Duration:** 30 minutes
**Runs on:** one node

---

## 1. What you learn

Everything the web UI does is an API call. The UI is a thin client. That
means everything you can do in the browser, you can script - and everything
you can script, you can verify.

That is the foundation of every `exercise.sh` in this course.

## 2. The three interfaces

```bash
qm list                                    # the CLI
pvesh get /nodes/pve1/qemu                # the API through pvesh
curl -k -H "Authorization: PVEAPIToken=..." \
     https://pve1:8006/api2/json/nodes/pve1/qemu
```

All three return the same information. `pvesh` is a client for the REST
API, and `curl` talks to it directly.

## 3. The API token

```bash
pveum user token add automation@pve terraform --privsep 1
pveum acl modify /vms/9201 --tokens 'automation@pve!terraform' --roles VM-Operator
```

The token is the credential for the automation. It never expires, it can be
revoked, and with privilege separation it has exactly the privileges its
own ACL grants.

### The secret

```bash
export PVE_TOKEN='automation@pve!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/nodes/$(hostname)/qemu" | jq '.data[].vmid'
```

The format is `user@realm!tokenid=secret`.

> **The secret is shown once.** It is stored hashed. If it is lost, rotate
> it - there is no way to read it again.

## 4. The API structure

```
/api2/json
├── version
├── nodes
│   └── {node}
│       ├── qemu
│       │   └── {vmid}
│       │       ├── status/current
│       │       ├── config
│       │       └── firewall/rules
│       ├── lxc
│       ├── status
│       └── tasks
├── cluster
│   ├── resources
│   ├── status
│   ├── metrics
│   ├── log
│   ├── backup
│   ├── firewall/rules
│   ├── notifications/endpoints
│   ├── notifications/matchers
│   └── sdn/vnets
├── storage
│   └── {storage}
└── access
    ├── acl
    └── permissions
```

### The verbs

| Verb | Meaning |
|---|---|
| `GET` | Read |
| `POST` | Create |
| `PUT` | Update |
| `DELETE` | Remove |

`pvesh` maps them onto `get`, `create`, `set` and `delete`:

```bash
pvesh get    /cluster/resources
pvesh create /cluster/backup --storage pbs-main --vmid 9201 --schedule daily
pvesh set    /cluster/firewall/options --enable 1
pvesh delete /cluster/backup/backup-abcdef
```

## 5. The Terraform provider

The official provider talks to exactly this API:

```hcl
provider "proxmox" {
  endpoint = "https://pve1:8006/"
  api_token = "automation@pve!terraform=xxxx-xxxx"
  insecure = true
}

resource "proxmox_virtual_environment_vm" "debian13-run-pve1" {
  node_name   = "pve1"
  vm_id       = 110
  name        = "web03"
  description = "managed by terraform"
  ...
}
```

The token in the provider has to have the `PVEAuditor` role plus the
privileges for the resources it manages. That is what the privilege
separation is for.

## 6. The Ansible provider

```yaml
- name: Start the Nordwind web tier
  community.general.proxmox_kvm:
    api_host: pve1
    api_user: automation@pve!terraform
    api_token: "{{ proxmox_token }}"
    vmid: 110
    state: started
```

## 7. What you do

1. Create the API token.
2. Use it with `curl` to read the cluster resources.
3. Use it with `pvesh` to do the same.
4. Show that the token is limited to its ACL.

## 8. How it is checked

```bash
./exercise.sh
```

## 9. The reference

`solution.md`.
