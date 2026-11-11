# Requirements - Topic 13: Firewall and Segmentation

**Topic ID:** `13-firewall-segmentation`

---

## The datacenter firewall

- [ ] The datacenter firewall is enabled.
- [ ] The inbound policy is `DROP`.
- [ ] The outbound policy is `ACCEPT`.
- [ ] A rule allows the web UI (8006) from the lab network.
- [ ] A rule allows SSH (22) from the lab network.
- [ ] A rule allows corosync (UDP 5405-5412) from the lab network.
- [ ] A rule allows NFS (2049) from the lab network.

## The rule hygiene

- [ ] No rule accepts traffic from `0.0.0.0/0`.
- [ ] No rule accepts traffic from `::/0`.
- [ ] No rule accepts **all** destinations - every rule has a destination
      port.

## The segmentation

- [ ] The web tier VM 100 carries the VLAN tag `20`.
- [ ] The web tier VM 101 carries the VLAN tag `20`.
- [ ] The application tier CT 300 carries the VLAN tag `30`.
- [ ] The database tier CT 301 carries the VLAN tag `40`.
- [ ] `bridge vlan show` on the node reports the tagged VLANs.

## The guest level rules

- [ ] VM 100 has its own firewall rules - the policy is not only at the
      datacenter level.
- [ ] A rule lets the web tier reach the database tier.
- [ ] A rule denies the database tier access to the web tier.

---

## Notes

**The rule hygiene checks are the real content of this exercise.** A
firewall that accepts from `0.0.0.0/0` is not a firewall - it is a
configuration that documents an intention and does not enforce it. The
verification fails the exercise on a single such rule, no matter how many
correct rules exist.

**The guest level rules** prove that the three levels work. A rule that only
exists at the datacenter level applies to the whole cluster, including the
cluster's own traffic - which is why the guest rules belong on the guest.
