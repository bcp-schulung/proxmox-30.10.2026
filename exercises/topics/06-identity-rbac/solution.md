# Solution - Topic 06: Identity, Roles and Access Control

**Topic ID:** `06-identity-rbac`

> **Instructor material.**

---

## 1. The realm

```bash
pveum realm add ad-corp --type pve --comment "Nordwind corporate realm"
```

> **Deviation.** The deck uses `--type ad --server ad.example.com --domain
> example.com`. The lab has no directory server, so the built-in `pve` realm
> type is used under the deck's name. Every other command is identical.

Verify:

```bash
pveum realm list
```

```
realm     type    comment
ad-corp   pve     Nordwind corporate realm
pve       pve     Proxmox VE user management
pam       pam     Linux PAM standard authentication
```

## 2. The user

```bash
pveum user add jsmith@ad-corp --password '<from the instructor>'
```

Verify:

```bash
pveum user list
```

```
User            Email             Enabled  Expire  Realm
jsmith@ad-corp  jsmith@nordwind.  yes                ad-corp
```

> **The password.** The `pveum user add` command accepts the password on the
> command line, which puts it in the shell history and in the process list.
> In production, use the `--password` option interactively (it prompts) or
> set it with `pveum user modify`. The instructor hands out the password
> separately.

## 3. The narrow role

```bash
pveum role add VM-Operator -privs "VM.Console,VM.PowerMgmt,VM.Monitor"
```

Verify:

```bash
pveum role list
```

```
Role            privileges
VM-Operator    VM.Console,VM.PowerMgmt,VM.Monitor
```

### What the three privileges do

| Privilege | Allows |
|---|---|
| `VM.Console` | Open the console, view the guest |
| `VM.PowerMgmt` | Start, stop, shutdown, reboot, suspend |
| `VM.Monitor` | Read the guest's status, the QEMU configuration, the process list |

### What the role deliberately does not have

| Missing privilege | Consequence |
|---|---|
| `VM.Config.Disk` | The operator cannot attach, detach or resize a disk |
| `VM.Config.CDROM` | Cannot mount an ISO |
| `VM.Config.Options` | Cannot change the CPU, the memory or the boot order |
| `VM.Allocate` | Cannot create or destroy a guest |
| `VM.Clone` | Cannot clone |
| `Sys.Audit` | Cannot read the cluster log |
| `Sys.Modify` | Cannot change the cluster configuration |

`VM.Allocate` is the one to watch. With it, the operator could delete a
guest. Without it, the worst they can do is power cycle something.

## 4. The ACL

```bash
pveum acl modify /vms/9201 --users jsmith@ad-corp --roles VM-Operator
pveum acl modify /vms/9202 --users jsmith@ad-corp --roles VM-Operator
```

Verify:

```bash
pveum acl list
```

```
PATH      TYPE    DATA           PRIV
/vms/9201  user    jsmith@ad-corp  VM-Operator
/vms/9202  user    jsmith@ad-corp  VM-Operator
```

### Why not on `/vms` and why not on `/`

```bash
# Too broad - every guest, including the database tier
pveum acl modify /vms --users jsmith@ad-corp --roles VM-Operator

# Far too broad - the whole cluster, including the storage and the config
pveum acl modify / --users jsmith@ad-corp --roles VM-Operator
```

The operator of a web tier should not be able to open the console of the
database. The whole point of the ACL path is to say *where* the permission
applies.

### The propagation

An ACL on `/vms/9201` propagates down to the children of VM 9201 - its disks
and its network interfaces - but never sideways to VM 9202.

## 5. The API token

```bash
pveum user token add automation@pve terraform --privsep 1
```

Expected:

```
Token ID                     Value
automation@pve!terraform     xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

> **The secret is shown once.** It cannot be read again. It can only be
> rotated:
> ```bash
> pveum user token modify automation@pve terraform --new-value
> ```
> In production the value goes straight into the secret manager of the CI
> system. It never goes into a repository - not even a private one.

### The privilege separation

```bash
pveum user token list automation@pve
```

```
tokenid    privsep  comment
terraform  1        <none>
```

Without `--privsep 1`, the token would inherit **all** the permissions of
`automation@pve`. The ACL below would then be meaningless, because the
token would already have everything.

## 6. The token ACL

```bash
pveum acl modify /vms/9201 --tokens 'automation@pve!terraform' --roles VM-Operator
```

Verify:

```bash
pveum acl list
```

```
PATH      TYPE    DATA                        PRIV
/vms/9201  user    jsmith@ad-corp             VM-Operator
/vms/9201  token   automation@pve!terraform    VM-Operator
/vms/9202  user    jsmith@ad-corp             VM-Operator
```

Two separate entries - one for the user, one for the token. That is what
privilege separation means.

### Use the token

```bash
export PVE_TOKEN="automation@pve!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN}" \
     "https://$(hostname):8006/api2/json/nodes/$(hostname)/qemu" | jq '.data[].vmid'
```

## 7. The effective permissions

```bash
pveum user permissions jsmith@ad-corp
```

```
Path              Privilege         Type
/vms/9201          VM.Console        user
/vms/9201          VM.Monitor        user
/vms/9201          VM.PowerMgmt      user
/vms/9202          VM.Console        user
/vms/9202          VM.Monitor        user
/vms/9202          VM.PowerMgmt      user
```

Three privileges on two guests. That is the whole blast radius.

## 8. The audit trail

```bash
pvesh get /cluster/log --limit 20
```

```json
{
  "data": [
    {
      "id": "abc123",
      "time": 1762760000,
      "username": "root@pam",
      "cmd": "pveum acl modify /vms/9201 --users jsmith@ad-corp --roles VM-Operator",
      "node": "pve1"
    }
  ]
}
```

Every administrative action is recorded. This is the first place to look
after an incident - and it is why the ACL changes are recorded too.

## 9. The complete sequence

```bash
pveum realm add ad-corp --type pve --comment "Nordwind corporate realm"
pveum user add jsmith@ad-corp --password '<password>'

pveum role add VM-Operator -privs "VM.Console,VM.PowerMgmt,VM.Monitor"

pveum acl modify /vms/9201 --users jsmith@ad-corp --roles VM-Operator
pveum acl modify /vms/9202 --users jsmith@ad-corp --roles VM-Operator

pveum user token add automation@pve terraform --privsep 1
pveum acl modify /vms/9201 --tokens 'automation@pve!terraform' --roles VM-Operator

pveum acl list
pveum user permissions jsmith@ad-corp
```

## 10. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `pveum role add` fails with "role already exists" | The role is there | `pveum role list` first |
| The role has more privileges than expected | A typo in the `-privs` list | `pveum role modify VM-Operator -privs "..."` |
| The user can do more than expected | An ACL on `/` or `/vms` | Check `pveum acl list` |
| The token has too many permissions | `--privsep` was not set | Delete it and recreate it |
| The token returns 401 | The secret was not copied completely | Rotate it: `pveum user token modify ... --new-value` |
| The password is in the shell history | `pveum user add --password` on the command line | Use the interactive prompt |
| The token secret cannot be read again | By design | It is stored hashed; rotate it |
