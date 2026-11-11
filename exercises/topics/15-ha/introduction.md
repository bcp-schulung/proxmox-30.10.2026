# Topic 15 - High Availability

**Topic ID:** `15-ha`
**Course reference:** Proxmox VE Introduction, Day 3 §5
**Duration:** 45 minutes
**Runs on:** one node

---

## 1. What you learn

Proxmox HA restarts a guest on a different node when the node it runs on
fails. It is a **restart**, not a live migration - the guest comes back on
another node, it does not move seamlessly.

## 2. The architecture

```
   CRM - Cluster Resource Manager     active on ONE node
        │
        ├── LRM - Local Resource Manager   (one per node)
        │        pve1    pve2    pve3
        │        └── watchdog-mux
        │
        └── HA Groups / Resources
```

| Component | Job |
|---|---|
| CRM | Decides what has to run where. Only one node is the active CRM. |
| LRM | Runs and stops the resources on its own node. |
| watchdog-mux | The fencing mechanism. |

### The fencing

The CRM has to be certain that a failed node is really dead before it
restarts a guest somewhere else. If the failed node were still running the
guest, both copies would be running - and a guest with a database on it
would corrupt itself.

The `watchdog-mux` provides that guarantee. It is a hardware watchdog that
the CRM pings. When the CRM stops pinging - because it crashed - the
watchdog fires and resets the node. The node comes back without the guest
running, and only then does the CRM restart the guest elsewhere.

## 3. The requirements

| Requirement | Why |
|---|---|
| **Shared storage** | The guest has to be startable on another node |
| A cluster with quorum | The CRM has to be able to decide |
| The HA resources in `/etc/pve/ha` | The CRM reads them |

The shared storage requirement is enforced:

```bash
ha-manager add vm:100 --group prod-nodes
# cannot add HA managed resource: storage 'local-lvm' is not shared
```

## 4. The HA group

```bash
ha-manager add group prod-nodes --nodes pve1,pve2,pve3
```

A group restricts where the resources in it may run. With no group, a
resource may run on any node.

```bash
ha-manager config --group prod-nodes
```

## 5. The resource

```bash
ha-manager add vm:100 --group prod-nodes --max_restart 3 --max_relocate 2
```

| Option | Meaning |
|---|---|
| `--max_restart` | How many times the CRM restarts the guest before it gives up |
| `--max_relocate` | How many times it may move the guest to another node |
| `--group` | The group that limits the nodes |
| `--state` | `started`, `stopped`, `ignored`, `disabled` |
| `--priority` | The order in which the resources are started after a failure |

## 6. The status

```bash
ha-manager status
```

```
Type     ID          Status    Last HA error
vm       100         started
ct       301         started
node    pve1         active
node    pve2         active
node    pve3         active
group  prod-nodes    active
```

## 7. The node maintenance

Before you reboot a node, take it out of the HA service:

```bash
ha-manager crm-command node-maintenance enable pve1
# wait for the resources to move
reboot
ha-manager crm-command node-maintenance disable pve1
```

Without the maintenance mode, the reboot looks like a node failure and the
CRM restarts everything unnecessarily.

## 8. What you do

1. Create the HA group `prod-nodes` with all three nodes.
2. Add VM 100, VM 101 and CT 301 to it.
3. Set the restart and relocate policies.
4. Verify the status.
5. Put a node into maintenance and back.

## 9. How it is checked

```bash
./exercise.sh
```

## 10. The reference

`solution.md`.
