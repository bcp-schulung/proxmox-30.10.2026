# Requirements - Topic 20: The API and Automation

**Topic ID:** `20-web-ui-automation`

---

## The API

- [ ] The API answers on `/api2/json/version`.
- [ ] The API answers on `/api2/json/cluster/resources`.
- [ ] The API answers on `/api2/json/cluster/status`.
- [ ] `pvesh` returns the same guest count as the raw API.

## The token

- [ ] The API token `automation@pve!terraform` exists.
- [ ] The token has privilege separation enabled.
- [ ] The token has its own ACL entry on `/vms/9201`.
- [ ] The token's ACL is scoped - it is not on the root path.

## The token's reach

- [ ] The token can read the cluster resources.
- [ ] The token can read the configuration of VM 9201.
- [ ] The token **cannot** read the configuration of CT 301 - the token is
      only scoped to `/vms/9201`.

## The storage

- [ ] The storage `nfs-lab` is declared with the content type `iso` - the
      API returns the content types, so they are verifiable from the
      automation side too.

---

## Notes

**The "cannot read CT 301" check is the point of the whole topic.** It
proves that the privilege separation actually limits the token. A token
that can read everything is a token with the full privileges of its user,
and the scoped ACL is decoration.

Without privilege separation, the token inherits the user's permissions
and this check fails - which is exactly what the check is for.
