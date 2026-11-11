# Solution - Topic 15: High Availability

**Topic ID:** `15-ha`

> **Instructor material.**

---

## 1. The HA group

```bash
ha-manager add group prod-nodes --nodes pve1,pve2,pve3
```

Verify:

```bash
ha-manager group prod-nodes
```

```json
{
  "nodes": ["pve1", "pve2", "pve3"],
  "comment": "",
  "disabled": 0
}
```

> **What a group does.** A group restricts the nodes on which the resources
> in it may run. A resource without a group may run on any node. For the
> Nordwind web tier, the group is what keeps the guest on the production
> nodes and off a node that is being rebuilt.

## 2. The resources

```bash
ha-manager add vm:100 --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add vm:101 --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add ct:301 --group prod-nodes --max_restart 3 --max_relocate 2
```

Verify:

```bash
ha-manager status
```

```
Type     ID          Status    Last HA error
vm       100         started
vm       101         started
ct       301         started
node    pve1         active
node    pve2         active
node    pve3         active
group  prod-nodes    active
```

## 3. The refusal

```bash
ha-manager add vm:103 --group prod-nodes
# cannot add HA managed resource: storage 'local-lvm' is not shared
```

This is the lesson of the whole topic. **HA restarts a guest on a different
node. That only works when every node can see the disk.**

The fix:

```bash
qm move_disk 103 scsi0 nfs-lab --target-directory vm-103-disk-0
ha-manager add vm:103 --group prod-nodes --max_restart 3 --max_relocate 2
```

## 4. The policies

| Option | Meaning | The value used here |
|---|---|---|
| `--max_restart` | How often the CRM restarts the guest on the same node | 3 |
| `--max_relocate` | How often it may move the guest to another node | 2 |
| `--state` | `started`, `stopped`, `ignored`, `disabled` | `started` |
| `--priority` | The start order after a failure | default |

The distinction matters:

- a **restart** is the CRM restarting the guest on the node it crashed on
- a **relocate** is the CRM moving the guest to a different node

A guest that crashes because of a software bug should be restarted on the
same node - relocating it would hide the bug and the data would follow.
A guest on a node that failed has to be relocated.

## 5. The configuration file

```bash
cat /etc/pve/ha/status.cfg
cat /etc/pve/ha/groups.cfg
cat /etc/pve/ha/resources.cfg
```

```ini
# resources.cfg
vm: 100
    group prod-nodes
    max_restart 3
    max_relocate 2
    state started

ct: 301
    group prod-nodes
    max_restart 3
    max_relocate 2
    state started
```

The HA configuration lives in the cluster filesystem, so it is replicated
like everything else.

## 6. The node maintenance

```bash
# Before a reboot
ha-manager crm-command node-maintenance enable pve1
```

```
requesting node maintenance for node 'pve1'
```

The CRM waits until the resources have moved away, then it stops managing
that node.

```bash
ha-manager status
# node    pve1         maintenance
```

```bash
reboot

# After the reboot
ha-manager crm-command node-maintenance disable pve1
```

> **Without the maintenance mode**, a reboot looks exactly like a node
> failure. The CRM restarts everything unnecessarily, and the guests that
> did not have to move, move.

## 7. Watching a failover

```bash
# On another node
watch -n 1 ha-manager status
```

Then stop the node that runs a guest:

```bash
# On the operator workstation
aws ec2 stop-instances --instance-ids <pve2-instance-id>

# Or, from the lab harness
./shutdown.sh --node pve2
```

The sequence:

```
1. The CRM notices that the LRM of pve2 is gone
2. The fencing makes sure pve2 is really down
3. The CRM relocates the guest to a healthy node
4. The guest starts there
```

With `--max_relocate 2`, the guest is moved at most twice. After that the
CRM gives up and reports an error - which is the right behaviour, because a
guest that fails to start on a second node probably has a problem of its
own.

## 8. The HA and the backup - a note for the students

HA and the backup solve different problems:

| | HA | Backup |
|---|---|---|
| Protects against | A node failure | Data loss, corruption, a mistake |
| Speed | Seconds to minutes | Hours to days |
| Granularity | The whole guest | The guest at a point in time |
| Needs | Shared storage | Nothing - a PBS can be offsite |

A guest on shared storage that is HA managed **still needs a backup**. HA
restarts a guest; it does not undo a mistake that was made inside the
guest.

## 9. The complete sequence

```bash
# The group
ha-manager add group prod-nodes --nodes pve1,pve2,pve3

# The resources
ha-manager add vm:100 --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add vm:101 --group prod-nodes --max_restart 3 --max_relocate 2
ha-manager add ct:301 --group prod-nodes --max_restart 3 --max_relocate 2

# The status
ha-manager status

# The maintenance
ha-manager crm-command node-maintenance enable pve1
ha-manager crm-command node-maintenance disable pve1
```

## 10. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `cannot add HA managed resource: storage is not shared` | The disk is on `local-lvm` | `qm move_disk` to the shared storage |
| The status shows `ignored` | The resource was added with `--state ignored` | `ha-manager config --vm 100 --state started` |
| The status shows `disabled` | The HA service does not touch the resource | `ha-manager config --vm 100 --state started` |
| Nothing happens after a node failure | The cluster has no quorum | `pvecm status` |
| The guests moved during a planned reboot | No maintenance mode | `ha-manager crm-command node-maintenance enable` |
| The guest is on the wrong node | The resource has no group | `--group prod-nodes` |
| `HA service is not running` | The `pve-ha` service is stopped | `systemctl start pve-ha` on all nodes |
