# Requirements - Topic 16: Monitoring and Notifications

**Topic ID:** `16-monitoring`

---

## The metrics

- [ ] `pvesh get /cluster/status` returns a readable status.
- [ ] `pvesh get /cluster/metrics` returns current metrics.
- [ ] The node status is readable (`/nodes/<node>/status`).
- [ ] The guest status is readable.

## The notifications

- [ ] A notification endpoint exists.
- [ ] A notification matcher exists.
- [ ] The matcher refers to a notification template.

## The task log

- [ ] `pvesh get /cluster/log --limit 50` returns entries.
- [ ] The log entries carry the user and the command.

## The monitoring workload

- [ ] The operations tier workload CT 302 `cache01` exists.
- [ ] CT 302 is running.

---

## Notes

**The task log check is a security check.** The log is the audit trail. A
cluster whose administrative actions are not recorded cannot answer the
question "who did this" after an incident - and the ACL exercise is only
half as valuable without it.
