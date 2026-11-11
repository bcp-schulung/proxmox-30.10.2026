# Requirements - Topic 06: Identity, Roles and Access Control

**Topic ID:** `06-identity-rbac`

---

## The realm and the user

- [ ] A realm `ad-corp` exists.
- [ ] A user `jsmith@ad-corp` exists.
- [ ] The user is not enabled on the root ACL path with a broad role.

## The role

- [ ] A role `VM-Operator` exists.
- [ ] The role grants `VM.Console`.
- [ ] The role grants `VM.PowerMgmt`.
- [ ] The role grants `VM.Monitor`.
- [ ] The role does **not** grant `VM.Config.Disk`.
- [ ] The role does **not** grant `VM.Config.CDROM`.
- [ ] The role does **not** grant `VM.Config.Options`.
- [ ] The role does **not** grant `VM.Allocate`.
- [ ] The role does **not** grant `Sys.Audit`.
- [ ] The role does **not** grant `Sys.Modify`.

## The ACL

- [ ] An ACL grants `VM-Operator` to `jsmith@ad-corp` on `/vms/100`.
- [ ] An ACL grants `VM-Operator` to `jsmith@ad-corp` on `/vms/101`.
- [ ] No ACL grants `jsmith@ad-corp` a role on the root path `/`.
- [ ] No ACL grants `jsmith@ad-corp` a role on `/vms` (that would be all
      guests).

## The effective permissions

- [ ] `pveum user permissions jsmith@ad-corp` lists `VM.Console` on
      `/vms/100`.
- [ ] The effective permissions do **not** include `Sys.Audit`.
- [ ] The effective permissions do **not** include `VM.Config.Disk`.

## The API token

- [ ] An API token `automation@pve!terraform` exists.
- [ ] The token has privilege separation enabled.
- [ ] The token has its own ACL entry on `/vms/100`.
- [ ] The token's ACL entry grants the `VM-Operator` role.
- [ ] The token's ACL is a **separate entry** from the user's ACL.

---

## Notes

**The "does not grant" checks are the point of the exercise.** A role that
grants everything an operator needs is easy. A role that grants *exactly*
what the operator needs is the work. The verification checks the negative
cases on purpose: an over-permissive role fails the exercise.

**The token ACL must be a separate entry.** With privilege separation
enabled, Proxmox keeps the token's permissions separate from the user's.
That is what allows an automation identity to have *less* than the human it
belongs to - which is the normal case.
