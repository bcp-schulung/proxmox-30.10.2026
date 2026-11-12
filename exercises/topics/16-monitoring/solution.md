# Solution - Topic 16: Monitoring and Notifications

**Topic ID:** `16-monitoring`

> **Instructor material.**

---

## 1. The status

```bash
pvesh get /cluster/status
```

```json
[
  { "type": "cluster", "id": "cluster", "name": "prod-cluster", "nodes": 3, "quorate": 1 },
  { "type": "node", "id": "node/pve1", "name": "pve1", "status": "online", ... },
  { "type": "node", "id": "node/pve2", "name": "pve2", "status": "online", ... },
  { "type": "node", "id": "node/pve3", "name": "pve3", "status": "online", ... },
  { "type": "qemu", "id": "qemu/9201", "name": "debian13-run-pve1", "status": "running", ... },
  { "type": "lxc", "id": "lxc/300", "name": "app01", "status": "running", ... }
]
```

The quick health check:

```bash
pvesh get /cluster/status --output-format json | \
  jq -r '.[] | select(.status != null and .status != "online" and .status != "running") | .id + ": " + .status'
```

An empty result means everything is healthy.

## 2. The metrics

```bash
pvesh get /cluster/metrics
```

```json
{
  "cpu": 0.07,
  "loadavg": [0.15, 0.12, 0.10],
  "memory": { "used": 2147483648, "free": 6442450944 },
  "swap": { "used": 0, "free": 0 },
  "root": { "used": 8589934592, "free": 12884901888 },
  "ksm": { "shared": 0 },
  "idle": 0,
  "wait": 0.0,
  "iowait": 0.0,
  "user": 0.02,
  "system": 0.03
}
```

### Per node

```bash
pvesh get /nodes/pve1/status
```

```json
{
  "uptime": 86400,
  "loadavg": [0.15, 0.12, 0.10],
  "cpu": 0.07,
  "memory": { "used": 2147483648, "free": 6442450944 },
  "ksm": { "shared": 0 },
  "rootfs": { "used": 8589934592, "free": 12884901888 },
  "swap": { "used": 0, "free": 0 },
  "idle": 0,
  "wait": 0.0,
  "iowait": 0.0,
  "network": { "eth0": { "in": 12345678, "out": 87654321 } },
  "storage": { "local-lvm": { "used": 12884901888, "total": 268435456000 } }
}
```

### Per guest

```bash
pvesh get /nodes/pve1/qemu/100/status/current
pvesh get /nodes/pve1/lxc/300/status/current
```

```json
{
  "status": "running",
  "vmid": 9201,
  "name": "debian13-run-pve1",
  "cpu": 0.02,
  "mem": 536870912,
  "maxmem": 4294967296,
  "disk": 2147483648,
  "uptime": 7200,
  "pid": 12345,
  "agent": 1
}
```

> **`agent: 1`** - the guest agent answers. `agent: 0` means it does not,
> and the backup of that guest cannot be consistent.

## 3. The metrics export

```bash
pvesh set /cluster/metrics/server/influxdb --type influxdb \
  --server influx.example.com --port 8089
```

```bash
pvesh get /cluster/metrics/server
```

```json
{ "influxdb": { "type": "influxdb", "server": "influx.example.com", "port": 8089 } }
```

### Why export at all

The Proxmox graphs show you what the **node** did. They do not show you
what the **application** did. When the node's CPU spikes at 03:00 every
night, only a correlation with the guest's own metrics tells you whether
that is the nightly database vacuum, a backup, or an attack.

## 4. The notification target

```bash
pvesh create /cluster/notifications/endpoints/sendmail \
  --name ops-mail \
  --comment "Nordwind operations"

# The alternatives
pvesh create /cluster/notifications/endpoints/gotify \
  --name ops-gotify --server https://gotify.example.com --token '<token>'

pvesh create /cluster/notifications/endpoints/webhook \
  --name ops-webhook --url https://hooks.example.com/proxmox
```

Verify:

```bash
pvesh get /cluster/notifications/endpoints
```

```json
[
  {
    "name": "ops-mail",
    "type": "sendmail",
    "comment": "Nordwind operations",
    "enable": 1
  }
]
```

> **`sendmail` needs a local MTA.** Without one, the notification is
> written to the mail queue and never delivered. In the lab the
> notifications are verified by their configuration, not by an actual
> delivery.

## 5. The notification matcher

```bash
pvesh create /cluster/notifications/matchers/system-mail \
  --type sentry \
  --comment "all cluster notifications" \
  --notification-template all
```

Verify:

```bash
pvesh get /cluster/notifications/matchers
```

```json
[
  {
    "name": "system-mail",
    "type": "sentry",
    "comment": "all cluster notifications",
    "enable": 1,
    "notification-template": "all"
  }
]
```

### The narrow matcher

```bash
pvesh create /cluster/notifications/matchers/backup-failures \
  --type sentry \
  --comment "only the backup failures" \
  --notification-template backup-fail
```

### The rule about noise

> A matcher that sends everything gets muted, and a muted channel is worse
> than no channel.

Send the failures. Report the rest in a dashboard that people look at when
they want to.

## 6. The task log

```bash
pvesh get /cluster/log --limit 50
```

```json
[
  {
    "id": "abc123",
    "time": 1762760123,
    "username": "root@pam",
    "cmd": "pveum acl modify /vms/9201 --users jsmith@ad-corp --roles VM-Operator",
    "node": "pve1",
    "pid": 12345,
    "pstart": 12340,
    "type": "vzdump"
  }
]
```

### The readable form

```bash
pvesh get /cluster/log --limit 100 --output-format json | \
  jq -r '.[] | "\(.time | strftime("%Y-%m-%d %H:%M:%S")) \(.username) \(.cmd)"'
```

```
2026-11-10 09:15:23 root@pam pveum acl modify /vms/9201 --users jsmith@ad-corp --roles VM-Operator
2026-11-10 09:20:41 root@pam vzdump: <root@pam> started task with UPID pvesm:9201:...
```

### The log is per node

```bash
pvesh get /nodes/pve1/log --limit 20
```

The cluster-wide log merges the per-node logs. For a forensic question
about a specific action, the node-specific log has the full context.

## 7. The monitoring workload

```bash
pct status 302
pct config 302
pct exec 302 -- hostname
```

## 8. The complete sequence

```bash
# The status and the metrics
pvesh get /cluster/status
pvesh get /cluster/metrics
pvesh get /nodes/$(hostname)/status
pvesh get /nodes/$(hostname)/qemu/100/status/current

# The notification target
pvesh create /cluster/notifications/endpoints/sendmail \
  --name ops-mail --comment "Nordwind operations"

# The matcher
pvesh create /cluster/notifications/matchers/system-mail \
  --type sentry --comment "all cluster notifications" \
  --notification-template all

# The task log
pvesh get /cluster/log --limit 50
```

## 9. The common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| The matcher exists but nothing is sent | The target is not enabled | `pvesh set /cluster/notifications/endpoints/<name> --enable 1` |
| The mail never arrives | No local MTA | Install one, or use the webhook target |
| The metrics are empty | `pvestatd` is not running | `systemctl status pvestatd` |
| The guest metrics show `agent: 0` | The guest agent is not installed | Enable it in the guest |
| The log is empty on a node | The clock is wrong and the entries are sorted oddly | Check `timedatectl` |
| The exported metrics stop | The remote database is unreachable | Check the network and the credentials |
