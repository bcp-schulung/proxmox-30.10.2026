# Topic 16 - Monitoring and Notifications

**Topic ID:** `16-monitoring`
**Course reference:** Proxmox VE Introduction, Day 3 §7
**Duration:** 30 minutes
**Runs on:** one node

---

## 1. What you learn

Proxmox collects metrics locally and routes events to notification targets.
Two separate systems:

```
   Nodes / Guests / Storage
            │
            ▼
      pvestatd + RRD ──────────► the graphs in the web UI
            │
            ▼
   cluster/metrics/export API ──► InfluxDB / Graphite
            │
   Events ──► Notification Matchers ──► sendmail / Gotify / webhook
```

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

The per-node and per-guest metrics are behind the node and the guest paths:

```bash
pvesh get /nodes/pve1/status
pvesh get /nodes/pve1/qemu/100/status/current
pvesh get /nodes/pve1/lxc/300/status/current
```

### The metrics export

```bash
pvesh set /cluster/metrics/server/influxdb --type influxdb \
  --server influx.example.com --port 8089
```

The metrics are pushed to an external time series database, where they can
be correlated with the metrics of the applications running inside the
guests. That is the difference between "the node is busy" and "the node is
busy because the database is doing the nightly vacuum".

## 3. The notifications

The notification system is a **matcher** and a **target**.

```
   An event (a backup failed, HA moved a resource)
            │
            ▼
   A matcher - which events, and with what severity
            │
            ▼
   A target - where the notification goes
```

### The target

```bash
pvesh create /cluster/notifications/endpoints/sendmail \
  --name ops-mail --comment "Nordwind operations"
```

Other targets: `gotify`, `slack`, `webhook`, `spool` (a file on the node).

### The matcher

```bash
pvesh create /cluster/notifications/matchers/system-mail \
  --type sentry \
  --comment "all cluster notifications" \
  --notification-template all
```

The `--type sentry` sounds odd, but it is the correct name - a "sentry" is
a notification target that only holds the current state and notifies when
it changes. The type is about the notification *semantics*, not the
delivery.

### The templates

| Template | What it sends |
|---|---|
| `all` | Everything |
| `backup-fail` | Only the backup failures |
| `ha-state-changes` | Only the HA state changes |

A production setup uses narrow templates. A matcher that sends every event
gets muted, and a muted notification channel is worse than no channel - the
team stops reading it.

```bash
pvesh create /cluster/notifications/matchers/backup-failures \
  --type sentry --comment "only the backup failures" \
  --notification-template backup-fail
```

## 4. The task log

```bash
pvesh get /cluster/log --limit 50
```

Every administrative action is recorded with the user, the command and the
node. It is the first place to look after an incident.

```bash
pvesh get /cluster/log --limit 100 --output-format json | \
  jq -r '.[] | "\(.time) \(.username) \(.cmd)"'
```

## 5. What you do

1. Read the cluster status and the metrics.
2. Create a notification target.
3. Create a matcher.
4. Read the task log.
5. Verify that the operations tier workload is present.

## 6. How it is checked

```bash
./exercise.sh
```

## 7. The reference

`solution.md`.
