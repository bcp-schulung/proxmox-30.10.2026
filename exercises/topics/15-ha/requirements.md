# Requirements - Topic 15: High Availability

**Topic ID:** `15-ha`

---

## The HA group

- [ ] An HA group `prod-nodes` exists.
- [ ] The group contains `pve1`.
- [ ] The group contains `pve2`.
- [ ] The group contains `pve3`.

## The managed resources

- [ ] VM 9201 is managed by HA.
- [ ] VM 9202 is managed by HA.
- [ ] CT 301 is managed by HA.
- [ ] All three are in the `started` state.
- [ ] All three have a configured node.

## The policies

- [ ] The restart policy is set (`max_restart` is at least 1).
- [ ] The relocate policy is set (`max_relocate` is at least 1).

## The preconditions

- [ ] The managed guests are on the shared storage - HA cannot restart a
      guest whose disk is node local.
- [ ] The cluster is quorate.

---

## Notes

**The "in the started state" check** is the one that catches the most common
mistake. A resource can be *configured* for HA and still not be started:

```
Type     ID     Status    Last HA error
vm       9201    started
vm       9202    ignored   - resource not started
```

The state `ignored` means the resource is known but deliberately not
running. The state `disabled` means the HA service does not touch it.

**The shared storage check** is the precondition that the exercise
teaches. The guest cannot be restarted on another node if the disk only
exists on one.

**The quorum check** matters because the CRM is only active on one node.
Without a quorum, there is no CRM, and nothing is restarted.
