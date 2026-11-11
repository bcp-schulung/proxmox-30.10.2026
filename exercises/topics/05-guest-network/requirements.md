# Requirements - Topic 05: The Guest Network

**Topic ID:** `05-guest-network`

---

## The bridge

- [ ] A bridge named `vmbr0` exists.
- [ ] The bridge has an IPv4 address in the node's own overlay range
      (`10.10.x.0/24`).
- [ ] The bridge address is the default gateway for that range.
- [ ] The bridge is configured with `bridge-vlan-aware yes`.
- [ ] `bridge vlan show` lists `vmbr0`.
- [ ] The bridge has no physical port enslaved - `bridge link` shows only the
      guest interfaces.

## The DHCP server

- [ ] `dnsmasq` is running.
- [ ] The dnsmasq configuration binds to `vmbr0`.
- [ ] A DHCP range is defined in the node's own overlay range.
- [ ] The DHCP options hand out the bridge as the router and the DNS server.

## The routing

- [ ] `net.ipv4.ip_forward` is `1`.
- [ ] A static route to each of the other two overlay subnets exists.
- [ ] The routes point at the management address of the other node.

## The NAT

- [ ] A masquerade rule exists for the node's overlay range.
- [ ] A `RETURN` rule exists for the overlay range `10.10.0.0/16`, so that
      traffic between the nodes is not NATed.
- [ ] A `RETURN` rule exists for the VPC range, so that the storage servers
      see the real guest address.

## The consistency between the nodes

- [ ] The three nodes use three different overlay subnets.

---

## Notes

**The "no physical port" check is a deviation check.** It is specific to this
lab. On real hardware `bridge-ports enp1s0` is correct and expected. The
rule here is: if you add a physical port to the bridge on EC2, the node
loses its address and you lose access to it.

**The RETURN rules are the difference between "the guests can reach the
internet" and "the guests can reach each other".** A student who only
writes the masquerade rule gets a lab where the guests can ping the outside
world but cannot talk to each other across nodes - which breaks the live
migration test in a confusing way.

**The route check verifies the target.** A route to `10.10.20.0/24` has to
point at `10.20.0.33` - the management address of `pve2` - and not at
`10.10.20.1`, which is the gateway address of `pve2`'s own bridge and is not
reachable from `pve1`.
