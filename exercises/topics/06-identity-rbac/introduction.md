# Topic 06 - Identity, Roles and Access Control

**Topic ID:** `06-identity-rbac`
**Course reference:** Proxmox VE Introduction, Day 1 §7 and Proxmox VE
Security, Day 1 §4-§6
**Duration:** 60 minutes
**Runs on:** one node (the configuration is cluster wide)

---

## 1. What you learn

Proxmox permissions combine three things:

1. a **realm** - where the identity comes from
2. a **role** - a bundle of privileges
3. an **ACL path** - where in the resource tree the role applies

```
   Realm: pam / pve / ldap / ad / oidc
      │
      ├── User: jsmith@ad-corp
      │      └── Group membership
      │             └── Role: VM-Operator  (VM.Console, VM.PowerMgmt, VM.Monitor)
      │                    └── ACL path: /vms/9201
      │                           └── Effective permission on VM 9201
      │
      └── API Token: automation@pve!terraform
             └── its own ACL, its own privileges
```

## 2. The realms

| Realm | Source | Use it when |
|---|---|---|
| `pam` | The Linux PAM stack on the node | Single node, no directory |
| `pve` | The Proxmox user database | A small cluster without a directory |
| `ldap` | An LDAP directory | The company already runs one |
| `ad` | Active Directory | The company runs AD |
| `oidc` | An OpenID Connect provider | Modern SSO |

> **Deviation in this lab.** The deck adds an Active Directory realm. There
> is no directory server here, so the built-in `pve` realm type is used
> under the deck's name `ad-corp`. Every command is identical.

The root account `root@pam` is special: it is the Linux root account, and it
bypasses the permission system entirely. It is the emergency access, and it
is also the biggest single risk in a Proxmox deployment.

## 3. The roles

Proxmox ships with these roles:

| Role | For |
|---|---|
| `PVEAdmin` | Everything. Use it carefully. |
| `PVEVMAdmin` | Full control over the guests |
| `PVEVMUser` | Guest operation, but not the guest configuration |
| `PVEAuditor` | Read only |
| `PVEVMConsole` | The console only |

The deck's advice - and it is the single highest-leverage RBAC practice - is
to **build narrow custom roles per job function**:

```bash
pveum role add VM-Operator -privs "VM.Console,VM.PowerMgmt,VM.Monitor"
```

An operator who can only open the console, power cycle and watch a guest
cannot delete a disk, cannot change the network, and cannot read the storage
credentials. The blast radius of a compromised account is the size of its
role.

## 4. The ACL paths

```
/                                  the datacenter
├── nodes                          the cluster nodes
├── storage                        the storages
├── vms                            the guests
│   ├── 9201
│   └── 9202
├── pool                           resource pools
└── sdns                           the SDN configuration
```

An ACL on `/vms/9201` applies to VM 9201. An ACL on `/vms` applies to all
guests. An ACL on `/` applies to everything - which is what `PVEAdmin` on
`/` means, and which is almost never what you want.

```bash
pveum acl modify /vms/9201 --users jsmith@ad-corp --roles VM-Operator
```

### The propagation

An ACL set on `/vms/9201` propagates to the child objects of VM 9201 - its
disks and its network interfaces. It does not propagate sideways to VM 9202.

## 5. The API token

An API token lets automation authenticate without a password anywhere:

```bash
pveum user token add automation@pve terraform --privsep 1
```

`--privsep 1` is the flag that matters. **Without privilege separation the
token inherits the full privileges of its user** - the ACL below would be
decoration. With it, the token has exactly the privileges that its own ACL
grants, and nothing else.

```bash
pveum acl modify /vms/9201 --tokens 'automation@pve!terraform' --roles VM-Operator
```

The token secret is shown **once**. After that it cannot be read again -
only rotated.

## 6. What you do

1. Create the realm `ad-corp`.
2. Create the user `jsmith@ad-corp`.
3. Create the role `VM-Operator` with exactly three privileges.
4. Grant the role on `/vms/9201` and `/vms/9202` - and nowhere else.
5. Create the privilege separated API token.
6. Give the token its own ACL.
7. Check the effective permissions of both.

## 7. How it is checked

```bash
./exercise.sh
```

## 8. The reference

`solution.md`.
