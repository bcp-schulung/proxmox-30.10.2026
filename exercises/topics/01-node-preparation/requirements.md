# Requirements - Topic 01: Node Preparation

**Topic ID:** `01-node-preparation`

State the requirements as a checklist. Every item is verified by
`exercise.sh`.

---

## Identity

- [ ] The hostname of the node is exactly `pve1`.
- [ ] `/etc/hosts` contains no `127.0.1.1` line.
- [ ] `/etc/hosts` maps `pve1` to the node's own management address
      (`10.20.0.41`).
- [ ] `getent hosts pve1` returns the management address, not `127.0.1.1`.

## Time

- [ ] `timedatectl show -p NTPSynchronized` returns `yes`.
- [ ] The clock drift against the time source is below 2 seconds.

## Package sources

- [ ] A Proxmox repository file exists in `/etc/apt/sources.list.d/`.
- [ ] The `no-subscription` repository is configured - the component
      `pve-no-subscription` and the suite `trixie` are present.
- [ ] The `enterprise` repository is absent.
- [ ] `apt update` completes without an error.

The file name is not fixed. The Proxmox installer writes
`pve-install-repo.sources`, a hand-made configuration often calls it
`pve-no-subscription.sources`. What matters is the content.

## Host firewall

The rules may live at either level, because the node level takes precedence
for the traffic that is addressed to the node itself:

- the cluster level - `/etc/pve/cluster/firewall/cluster.fw`
- the node level - `/etc/pve/nodes/<node>/host.fw`

The two levels accept **different** things, and mixing them up is the
classic mistake:

| | cluster.fw | host.fw |
|---|---|---|
| `policy_in` / `policy_out` | yes | **no** |
| `[ALIASES]` / `[GROUPS]` / `[IPSET]` | yes | **no** |
| `enable` | yes | yes |
| the rules | yes | yes |

- [ ] The node firewall file exists.
- [ ] The node firewall file is **parseable** - the API does not report a
      parse error.
- [ ] A rule allows TCP port 22 (SSH).
- [ ] A rule allows TCP port 8006 (the web UI).
- [ ] A rule allows UDP 5405-5412 (corosync / KNET).
- [ ] A rule allows TCP port 2049 (NFS).
- [ ] A rule allows TCP port 8007 (the Proxmox Backup Server).
- [ ] No rule accepts traffic from `0.0.0.0/0` or `::/0`.
- [ ] The node file carries **no** `policy_in` and **no** `policy_out`.
- [ ] The `pve-firewall` service is running.

## Platform health

- [ ] `pveversion` reports a Proxmox VE 9.x release.
- [ ] The `pveproxy`, `pvedaemon` and `pvestatd` services are running.

---

## Notes

**The `0.0.0.0/0` check is the important one.** A rule that accepts from
everywhere is a rule that does not restrict anything, and it is the most
common finding in a real security review. The operator's own address - and
the VPC for the cluster's own traffic - is what belongs in the source field.

**The parse check is the one that catches a silent failure.** A node file
that carries `policy_in` looks perfectly reasonable, but Proxmox cannot
parse it and ignores the whole file. The firewall then stays "enabled" and
enforces nothing - which is worse than having no firewall at all, because
it looks like it is working. The way to see it is the API:

```bash
pvesh get /nodes/pve1/firewall/rules
# /etc/pve/nodes/pve1/host.fw (line 4): can't parse option 'policy_in: DROP'
```

**The clock check needs a moment.** If you just enabled NTP, wait a few
seconds before you run the verification, otherwise the drift may still be
large.

**On the repository format.** Proxmox VE 9 writes the repositories in the
deb822 format as `pve-<name>.sources`. The older one-line `pve-<name>.list`
format still works and is what the older course material shows. Both are
accepted by the verification.
