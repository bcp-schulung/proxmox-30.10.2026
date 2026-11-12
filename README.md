# Proxmox VE Advanced Seminar Lab on AWS

Automation harness that builds a complete **Proxmox VE 9.2 cluster on AWS** so the
`proxmox-introduction`, `proxmox-migration` and `proxmox-security` seminar material can be
taught hands-on. It provisions the AWS infrastructure, installs and clusters the Proxmox
nodes, wires up the storage backends, and rolls out the VMs and LXC containers the
exercises need.

Everything is driven by four scripts:

| Script | Purpose |
|---|---|
| `provision.sh` | Build the lab from nothing. Resumable - re-run it after a failure and it picks up where it stopped. |
| `debug.sh` | Diagnose every layer (AWS, network, node, cluster, guest) and write a report to `logs/`. |
| `shutdown.sh` | Stop the lab for the night. Guests are shut down gracefully, instances are stopped, **nothing is destroyed**. |
| `clean.sh` | Remove the lab. `--scope cluster` resets the cluster, `--scope aws` removes the AWS resources as well. |
| `destroy.sh` | Nuke the entire setup - every instance, volume, network resource, image and the local state. One command, no scope to think about. |

---

## What you get

```
                        AWS VPC 10.20.0.0/16  (eu-central-1)
   ┌──────────────────────────────────────────────────────────────────────────┐
   │  subnet-public 10.20.0.0/24  →  internet gateway                        │
   │                                                                          │
   │    ┌──────────────┐   ┌──────────────┐   ┌──────────────┐               │
   │    │    pve1      │   │    pve2      │   │    pve3      │               │
   │    │ m8i.4xlarge  │   │ m8i.4xlarge  │   │ m8i.4xlarge  │               │
   │    │ PVE 9.2      │◄─►│ PVE 9.2      │◄─►│ PVE 9.2      │               │
   │    │ 10.20.0.11   │   │ 10.20.0.12   │   │ 10.20.0.13   │               │
   │    │ vmbr0        │   │ vmbr0        │   │ vmbr0        │               │
   │    │ 10.10.10.1   │   │ 10.10.20.1   │   │ 10.10.30.1   │               │
   │    └───┬──────┬───┘   └──────────────┘   └──────────────┘               │
   │        │      │                                                            │
   │  subnet-services 10.20.2.0/24  →  NAT gateway                            │
   │    ┌───────────┐   ┌───────────┐                                          │
   │    │  nfs1     │   │  pbs1     │   ← shared storage + backup target       │
   │    │ t3.medium │   │ t3.large  │                                          │
   │    └───────────┘   └───────────┘                                          │
   └──────────────────────────────────────────────────────────────────────────┘

   Cluster "prod-cluster" · shared storage "nfs-lab" · local storage "local-lvm"
   Templates: 9101 / 9102 / 9103 (one per node, on local-lvm)
   Guests:    9201 / 9202 / 9203 (one running per node, full clone of that node's template)
              CT 300 app01, CT 301 db01
```

## Prerequisites

| Tool | Why |
|---|---|
| **AWS CLI v2** | All infrastructure is created through the CLI. |
| **jq** | State file handling and AWS query payloads. |
| **Packer** | Builds the Proxmox VE and Proxmox Backup Server AMIs. |
| **OpenSSH client** | `ssh`, `scp`, `ssh-keygen`. |
| **curl** | Image downloads on the nodes. |

You also need AWS credentials with permission to create VPCs, subnets, security groups,
EIP/NAT gateways, EC2 instances, EBS volumes, key pairs and AMIs.

### Nested virtualization

Proxmox has to run KVM guests, which means the EC2 instance needs hardware virtualization
exposed. AWS supports this on the 8th-generation Intel families (`m8i`, `c8i`, `r8i`, and
the `m7i`/`c7i`/`r7i`/`i7i` families) and on bare metal. The instances are launched with
`--cpu-options NestedVirtualization=enabled`; `provision.sh` verifies the instance type
supports it before anything is created and fails with a clear message if it does not.

> Bare metal (`m8i.metal`) works too but costs roughly ten times as much
> (~$10.16/h vs ~$0.85/h per node).

## Quick start

```bash
# 1. Configure (optional - the defaults work for most setups)
cp .env.example .env && $EDITOR .env

# 2. Check the harness itself (no AWS needed)
./tests/selftest.sh

# 3. Build the lab
./provision.sh

# 4. Open https://<node-ip>:8006/ and log in as root@pam
#    provision.sh prints all URLs and passwords when it finishes.

# 5. When the day is over
./shutdown.sh              # stop everything, keep it for tomorrow

# 6. When the seminar is over
./destroy.sh               # remove EVERYTHING - cluster and AWS resources
```

`provision.sh` takes roughly 25–40 minutes, most of it the two Packer builds.

## Configuration

Precedence: **environment variable > `./.env` > `config/default.env`**.

The most relevant settings:

| Variable | Default | Notes |
|---|---|---|
| `AWS_REGION` | `eu-central-1` | The region to build in. |
| `PVE_INSTANCE_TYPE` | `m8i.4xlarge` | Must support nested virtualization. |
| `PVE_NODE_NAMES` | `pve1 pve2 pve3` | Three nodes gives real quorum. |
| `PVE_CLUSTER_NAME` | `prod-cluster` | The name from the seminar material. |
| `NFS_INSTANCE_TYPE` | `t3.medium` | The shared storage server. |
| `PBS_INSTANCE_TYPE` | `t3.large` | The backup server. |
| `AWS_CALLER_IP` | auto-detected | Your public IP. SSH and the web UI are only open to it. |
| `PVE_ROOT_PASSWORD` | auto-generated | Written to `.env` (git-ignored) at the end. |

## The four scripts

### `provision.sh`

```bash
./provision.sh                  # run everything
./provision.sh --phase cluster  # only run one phase
./provision.sh --with-security  # also apply the security seminar baseline
./provision.sh --skip-ami-build # reuse the AMIs from the state file
```

Eight phases, each recorded in `.state/lab.json` so the script is resumable:

1. **foundation** - VPC, subnets, route tables, internet gateway, NAT gateway, security groups, key pair
2. **amis** - Packer builds the Proxmox VE 9.2 AMI and the PBS AMI
3. **nodes** - launches pve1–pve3, nfs1 and pbs1
4. **bootstrap** - hostname, `/etc/hosts`, LVM-thin pool, `vmbr0`, dnsmasq, NAT, chrony
5. **cluster** - `pvecm create prod-cluster` + `pvecm add` for the other nodes
6. **storage** - `local-lvm`, the shared NFS storage `nfs-lab`, the local dir storage
7. **backup** - the PBS datastore and the `backup@pbs` user, registered as `pbs-main`
8. **guests** - the Debian image and the template on each node, the running guest on each
   node, and the two containers

### `debug.sh`

```bash
./debug.sh                 # full report
./debug.sh --node pve2     # one node
./debug.sh --quick         # skip the slow probes
./debug.sh --show-log      # print the whole report
```

Walks six layers and prints `PASS` / `WARN` / `FAIL` per check. The full report lands in
`logs/debug-<timestamp>.log`. Exits non-zero if anything failed, so it can gate a CI run.

### `shutdown.sh`

```bash
./shutdown.sh            # shut the guests down, stop the instances
./shutdown.sh --guests   # only the guests
./shutdown.sh --start    # bring the lab back up
./shutdown.sh --force    # do not wait for a graceful shutdown
```

### `clean.sh`

Scoped teardown - use it when you want to keep part of the lab.

```bash
./clean.sh                       # reset the cluster, keep the instances running
./clean.sh --scope aws           # remove the AWS resources as well
./clean.sh --scope all           # everything
./clean.sh --scope all --dry-run # show what would happen
```

### `destroy.sh`

The full teardown. It removes the guests, the cluster configuration, every EC2
instance (including orphans from a failed Packer build), every EBS volume, every
network interface, security group, route table, NAT gateway, elastic IP, internet
gateway, subnet, the VPC, the key pair, both AMIs with their snapshots, and the
local state including the generated credentials.

```bash
./destroy.sh --dry-run    # show the manifest, change nothing
./destroy.sh              # destroy everything, with a confirmation
./destroy.sh --yes        # destroy everything without asking
./destroy.sh --keep-amis  # keep the AMIs so the next run starts faster
```

Resources are located by their `LabTag`, so leftovers from an interrupted run are
removed as well - the state file is not required. The script finishes by verifying
that nothing tagged with the lab tag is left in the account.

## AWS-specific design decisions

These are the places where the cloud differs from the on-premise lab the seminar material
assumes. `docs/ARCHITECTURE.md` has the full reasoning.

- **Proxmox is installed on Debian, not from the ISO.** The official installer cannot
  boot on EC2. The supported route is *Install Proxmox VE on Debian 13 Trixie*, which
  produces exactly the version the seminar targets (PVE 9.2, Debian 13.5, kernel 7.0).
- **The management interface is never bridged.** `eth0` keeps the VPC IP, so a mistake in
  the bridge configuration can never lock you out of the node.
- **`vmbr0` has no physical port.** AWS only routes to ENI-owned addresses, so a guest
  can never hold a VPC IP. The guests live on a private overlay (`10.10.x.0/24`) and the
  host provides DHCP, routing and NAT for them.
- **Each node runs its own overlay subnet** (`10.10.10/20/30.0/24`). Identical subnets on
  several nodes would collide once the nodes route between each other.
- **Storage is split.** `local-lvm` is node-local (LVM-thin on a dedicated EBS volume) and
  `nfs-lab` is shared. Live migration and HA only work on the shared storage - which is
  precisely the point the seminar makes.
- **No ZFS.** AWS does not support ZFS on EBS, so the encryption exercise uses the
  LVM-thin and NFS backends instead.

## Cost

| Resource | On-demand (eu-central-1, approx.) |
|---|---|
| 3 × `m8i.4xlarge` | ~$0.85/h each → ~$2.55/h |
| `t3.medium` (NFS) | ~$0.05/h |
| `t3.large` (PBS) | ~$0.10/h |
| NAT gateway + public IPv4 | ~$0.05/h |
| EBS (3 × 282 GB + 300 GB) | ~$0.07/h |
| **Total** | **~$2.8/h ≈ $67/day** |

`shutdown.sh` stops the instances, so nothing accrues overnight. `clean.sh --scope all`
removes everything.

## Troubleshooting

| Symptom | Action |
|---|---|
| `provision.sh` fails at a phase | Re-run it. It resumes from the last completed phase. |
| A node does not come back after the reboot | `./debug.sh --node pve1` |
| The web UI is not reachable | The security group only allows your public IP. Check `AWS_CALLER_IP` in `.env`. |
| `nested virtualization is not supported` | Pick another instance type, e.g. `c8i.4xlarge`. |
| The cluster is not quorate | `./debug.sh` - it checks the corosync ports and node-to-node SSH. |
| Guests have no address | dnsmasq must be running: `./debug.sh --node pve1` |

## Repository layout

```
provision.sh  debug.sh  shutdown.sh  clean.sh  destroy.sh   the entry points
config/default.env                            versioned defaults
.env.example                                  template for machine specific settings
lib/                                          common, config, state, aws, ssh, pve, lab
scripts/                                      node-bootstrap.sh, nfs-setup.sh, pbs-setup.sh
packer/                                       pve.pkr.hcl, pbs.pkr.hcl and the build steps
tests/selftest.sh                             offline tests (no AWS account needed)
docs/ARCHITECTURE.md                          the topology and the reasoning behind it
docs/EXERCISES.md                             the seminar exercises mapped to the lab
.state/                                       runtime state (git-ignored, contains secrets)
logs/                                         diagnostic reports (git-ignored)
```

## Security notes

- The Proxmox root password, the guest password and the PBS credentials are generated
  automatically and written to `.env` with mode `600`. `.env` and `.state/` are
  git-ignored - never commit them.
- SSH and the web UI are only reachable from `AWS_CALLER_IP`. The security group rule is
  visible in the AWS console and can be changed from `.env` before provisioning.
- All EBS volumes are encrypted at rest.
- The Proxmox firewall is **not** enabled automatically - enabling a default-deny policy
  without also writing the corosync and NFS rules would cut the cluster apart. The
  exercise in `docs/EXERCISES.md` shows how to do it safely.

## Licence

The seminar material in `proxmox-introduction/`, `proxmox-migration/` and
`proxmox-security/` belongs to its authors. The harness in this repository is provided
as-is for running those seminars.
