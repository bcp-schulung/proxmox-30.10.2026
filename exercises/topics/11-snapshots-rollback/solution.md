# Solution - Topic 11: Snapshots and Rollback

**Topic ID:** `11-snapshots-rollback`

> **Instructor material.**

---

## 1. Take the snapshot

```bash
qm snapshot 9201 pre-update --description "before the Nordwind 2.4 release"
```

Verify:

```bash
qm listsnapshot 9201
```

```
ID      Name        Time                 Description
9201     pre-update  2026-11-10T09:15:23Z  before the Nordwind 2.4 release
```

### The guest agent is used automatically

While the snapshot is taken, the host asks the guest agent to freeze the
filesystem. You can see it in the task log:

```bash
pvesh get /cluster/log --limit 5
```

```json
{
  "cmd": "vzdump: <root@pam> snapshot 'pre-update' for VM 9201",
  "endtime": 1762760123,
  "status": "OK"
}
```

Without the agent, the snapshot is taken without the freeze, and the
`fstrim_cloned_disks` / `fsfreeze` step does not happen.

## 2. Make a change

```bash
qm guest exec 9201 -- sh -c 'echo "release-2.4" > /etc/nordwind-version'
qm guest exec 9201 -- cat /etc/nordwind-version
# release-2.4
```

Verify that the change is there:

```bash
qm guest exec 9201 -- test -f /etc/nordwind-version && echo "changed"
```

## 3. Roll back

```bash
qm rollback 9201 pre-update
```

The guest is stopped, the disk and the memory are restored, and the guest
starts again with exactly the state it had at the snapshot.

Verify:

```bash
qm guest exec 9201 -- cat /etc/nordwind-version
# cat: /etc/nordwind-version: No such file or directory
```

The change is gone.

### The disk-only rollback

```bash
qm rollback 9201 pre-update --mode snapshot
```

This restores the disk and leaves the guest **stopped**. It is the right
choice when the guest has to be examined in a known state - during an
forensic investigation, for example.

## 4. Delete the snapshot

```bash
qm delsnapshot 9201 pre-update
qm listsnapshot 9201
```

### Why deleting matters

```bash
pvesm list nfs-lab --content images
```

A snapshot keeps the changed blocks alive. On a guest that writes heavily, a
snapshot that is never deleted consumes the space of the whole changed data
set - and the original disk cannot be freed either.

The rule:

> **A snapshot is a rollback point. A backup is a copy. Do not confuse
> them.**

## 5. The complete cycle

```bash
# Take the snapshot
qm snapshot 9201 pre-update --description "before the Nordwind 2.4 release"

# Make a change
qm guest exec 9201 -- sh -c 'echo "release-2.4" > /etc/nordwind-version'
qm guest exec 9201 -- cat /etc/nordwind-version

# Roll it back
qm rollback 9201 pre-update
qm guest exec 9201 -- cat /etc/nordwind-version      # the file is gone

# Clean up
qm delsnapshot 9201 pre-update
```

## 6. The nested snapshots

```bash
qm snapshot 9201 pre-update
qm snapshot 9201 after-patch
qm listsnapshot 9201
```

```
ID      Name        Time
9201     after-patch 2026-11-10T09:20:00Z
9201     pre-update  2026-11-10T09:15:00Z
```

Rolling back to `pre-update` discards everything after it, including
`after-patch`. The order in the list is newest first.

> **A rollback with a running snapshot fails.** If `after-patch` exists and
> you try to roll back to `pre-update`, Proxmox refuses:
> ```
> can't rollback, snapshot 'after-patch' exists - delete it first
> ```
> Delete the newer snapshots first.

## 7. The container equivalent

```bash
pct snapshot 300 before-upgrade
pct listsnapshot 300
pct rollback 300 before-upgrade
pct delsnapshot 300 before-upgrade
```

Containers are snapshotted the same way. A container snapshot does not
include the memory - a container has no memory state to capture.

## 8. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The change is still there after the rollback | The guest writes the file again on its own | Use a file that nothing rewrites |
| The rollback fails: "snapshot exists" | A newer snapshot is in the way | Delete the newer snapshot first |
| The guest is stopped after the rollback | `--mode snapshot` was used | Use the default full rollback |
| The snapshot is slow | The guest has a huge amount of dirty data | Expected - the memory has to be written |
| The storage fills up | The snapshots were never deleted | `qm delsnapshot` |
| The database is inconsistent after the rollback | The agent was not enabled | Enable the guest agent |
