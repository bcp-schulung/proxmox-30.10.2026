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

- [ ] `/etc/apt/sources.list.d/pve-no-subscription.list` exists and contains
      the `trixie pve-no-subscription` suite.
- [ ] `/etc/apt/sources.list.d/pve-enterprise.list` does not exist.
- [ ] `apt update` completes without an error.

## Host firewall

- [ ] The firewall is enabled (`enable: 1`).
- [ ] The inbound policy is `DROP`.
- [ ] The outbound policy is `ACCEPT`.
- [ ] A rule allows TCP port 22 (SSH).
- [ ] A rule allows TCP port 8006 (the web UI).
- [ ] A rule allows UDP 5405-5412 (corosync / KNET).
- [ ] A rule allows TCP port 2049 (NFS).
- [ ] A rule allows TCP port 8007 (the Proxmox Backup Server).
- [ ] No rule accepts traffic from `0.0.0.0/0` or `::/0`.
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

**The clock check needs a moment.** If you just enabled NTP, wait a few
seconds before you run the verification, otherwise the drift may still be
large.
