# The Proxmox VE Exercises

The teaching material for the **Proxmox VE Introduction** and the
**Proxmox VE Advanced** seminars.

There are two kinds of exercise material here:

1. **One long exercise** - two days of guided work in which the students
   build the complete infrastructure for a fictional company on their own
   Proxmox cluster.
2. **Twenty topic examples** - one clean, self-contained example per
   topic. The instructor shows them; the students use them as a reference.

Every exercise consists of exactly four parts:

| Part | For the student | For the instructor |
|---|---|---|
| `introduction.md` | The topic, the background, what to do | The same - it is shown first |
| `requirements.md` | The checklist of what has to be true | What the verification checks |
| `solution.md` | The reference, after the attempt | The complete command sequence |
| `exercise.sh` | The self-check | The acceptance test |

---

## The layout

```
exercises/
├── README.md                     this file
├── validate.sh                   the static check of the whole tree
├── deploy.sh                     install the material onto the nodes
│
├── lib/
│   ├── exlib.sh                  the assertion framework and the transport
│   └── scenario.sh               the Nordwind Logistics definitions
│
├── docs/
│   └── SCENARIO.md               the fictional company
│
├── long-exercise/
│   └── nordwind-platform/        the two day exercise
│       ├── introduction.md
│       ├── requirements.md
│       ├── solution.md
│       ├── exercise.sh           the acceptance test
│       └── reset.sh              put the lab back to its pre-exercise state
│
└── topics/
    ├── 01-node-preparation/          ├── 11-snapshots-rollback/
    ├── 02-platform-architecture/     ├── 12-live-migration/
    ├── 03-cluster-formation/         ├── 13-firewall-segmentation/
    ├── 04-storage-backends/          ├── 14-backup-pbs/
    ├── 05-guest-network/             ├── 15-ha/
    ├── 06-identity-rbac/             ├── 16-monitoring/
    ├── 07-template-cloning/          ├── 17-troubleshooting/
    ├── 08-vm-lifecycle/              ├── 18-resource-management/
    ├── 09-lxc-containers/            ├── 19-updates-maintenance/
    └── 10-clone-strategies/          └── 20-web-ui-automation/
```

---

## The scenario: Nordwind Logistics

A fictional freight and warehousing company with a customer portal, an
internal dispatch system, a warehouse database, a tracking cache and a
monitoring stack.

The tier model is what the students reason about:

| Tier | VLAN | Guest type | Why |
|---|---|---|---|
| Web | 20 | VM | must be live-migratable and highly available |
| Application | 30 | LXC | Linux only, trusted, many of them |
| Database | 40 | LXC | stateful, needs its own backup schedule |
| Operations | 50 | LXC | monitoring, no customer traffic |

The full description is in [`docs/SCENARIO.md`](docs/SCENARIO.md).

Keeping one company across all the exercises means the students see the
infrastructure grow instead of seeing twenty unrelated demos, and every
number (VLAN ID, VMID, hostname) stays the same from one exercise to the
next.

---

## The long exercise

**Two days.** The students build the whole Nordwind platform on a cluster
that starts empty.

- **Day 1** - the cluster (tasks 1-5) and the workloads (tasks 6-8)
- **Day 2** - the workload management (9-11), the protection (12-14) and
  the operations (15-16)

See [`long-exercise/nordwind-platform/introduction.md`](long-exercise/nordwind-platform/introduction.md)
for the day plan and the grading, and
[`requirements.md`](long-exercise/nordwind-platform/requirements.md) for the
task list.

### Running it

```bash
# Install the material onto the lab nodes
./deploy.sh

# On the node, as the instructor
cd /opt/exercises/long-exercise/nordwind-platform
./reset.sh --all        # put the lab back into its pre-exercise state
./exercise.sh           # the acceptance test
```

### The reset

`reset.sh` removes everything the exercise created - the cluster
configuration, the storages, the guests, the identities, the firewall rules
and the backup jobs - and leaves the three nodes as standalone Proxmox
installations with their network already configured.

The data on the NFS server and on the PBS datastore is **not** touched.

```bash
./reset.sh --all            # everything
./reset.sh --guests         # only the guests
./reset.sh --identity       # only the users, roles and tokens
./reset.sh --cluster        # only dissolve the cluster
./reset.sh --dry-run        # show the plan
```

---

## The topic examples

One directory per topic. The instructor shows the `introduction.md`, the
students work through the `requirements.md`, and both use the
`exercise.sh`.

| # | Topic | Course reference |
|---|---|---|
| 01 | Node preparation | Introduction D1 §4 |
| 02 | The platform architecture | Introduction D1 §2, §3 |
| 03 | Cluster formation | Introduction D1 §6 |
| 04 | Storage backends | Introduction D1 §8, D3 §2 |
| 05 | The guest network | Introduction D1 §9 |
| 06 | Identity, roles and access control | Introduction D1 §7, Security D1 §4-§6 |
| 07 | The golden image and templates | Introduction D2 §4 |
| 08 | The VM lifecycle | Introduction D2 §2, §3 |
| 09 | LXC containers | Introduction D2 §5, §6 |
| 10 | Clone strategies | Introduction D2 §4 |
| 11 | Snapshots and rollback | Introduction D2 §8 |
| 12 | Live migration | Introduction D2 §8 |
| 13 | Firewall and segmentation | Security D2 §2, §3 |
| 14 | Backup and restore with PBS | Introduction D3 §3, §4 |
| 15 | High availability | Introduction D3 §5 |
| 16 | Monitoring and notifications | Introduction D3 §7 |
| 17 | Troubleshooting | Introduction D3 §8 |
| 18 | Resource management | Introduction D2 §7 |
| 19 | Updates and maintenance | Introduction D3 §6 |
| 20 | The API and automation | Introduction D1 §5, Security D1 §6 |

Topics 02, 18, 19 and 20 are supplementary - they are taught as standalone
exercises rather than as numbered tasks of the long exercise.

---

## How the exercise scripts work

### The transport

The scripts run in two places:

| Where | How |
|---|---|
| **On a cluster node** | The local Proxmox CLI. Detected automatically. |
| **On the workstation** | SSH to the cluster. The target comes from the lab harness state file. |

```bash
./exercise.sh                          # auto-detect
EX_TARGET=pve2 ./exercise.sh          # a different node
EX_SSH_HOST=10.20.0.41 ./exercise.sh  # an explicit address
EX_SSH_KEY=/path/to/key ./exercise.sh # an explicit key
```

### The output

```
--- The cluster
[ PASS ] the cluster has three members
[ PASS ] the cluster is quorate
[ FAIL ] the quorum is 2
         expected '2', got '1'

----------------------------------------------------------------------
Result  28 passed, 1 failed, 0 skipped

Failed checks:
  - the quorum is 2

The exercise is NOT complete. See solution.md for the expected result.
```

The exit code is `0` when every check passed and `1` otherwise, so the
script can gate a CI run.

### The options

```bash
./exercise.sh --verbose            # show the output of every check
./exercise.sh --section 3          # only the sections that match "3"
./exercise.sh --help
```

---

## The static validation

`validate.sh` checks the whole tree without a cluster:

```bash
./validate.sh
```

It verifies that

- every exercise directory has the four parts
- every `exercise.sh` is executable and parses
- every `exercise.sh` has balanced quotes
- every `exercise.sh` avoids the two shell traps that break a long
  substitution (an `awk {print $N}` inside a `$( )`, and a `)` inside the
  quoted argument of a command substitution)
- every topic referenced by the long exercise exists, and every topic
  directory is mentioned by the long exercise

```
----------------------------------------------------------------------
All 191 checks passed.
```

Run it after every change to the material.

---

## The deviations from the on-premise lab

The lab runs on AWS, and AWS breaks several assumptions of the course
material. Every deviation is deliberate and is called out in the exercise
that it affects.

| Deviation | Why | Where it shows up |
|---|---|---|
| The management interface is not bridged | AWS drops traffic whose source MAC is not registered on the ENI. A bridge that owns its MAC address would take the node offline. | Topics 05, the long exercise |
| The guests live on a private overlay | AWS only routes to ENI-owned addresses. A guest can never hold a VPC address. | Topics 05, 09 |
| No ZFS | The kernel refuses ZFS on an EBS block device. | Topics 04, 07 |
| No Ceph | A hyper-converged cluster needs three dedicated OSD nodes with real disks. | Topics 04, 15 |
| No Active Directory | There is no directory server in the lab. The built-in `pve` realm type is used under the deck's name `ad-corp`. | Topic 06 |
| Self-signed ACME instead of Let's Encrypt | Let's Encrypt needs a public DNS name and port 80. | - |
| The VLANs are a design exercise, not a routing one | The lab's dnsmasq serves one address range per node. | Topic 13 |

Each of these is discussed with the students in its context, so they know
what it is and what it would look like in production.

---

## Before the seminar

```bash
# 1. Build the lab
cd .. && ./provision.sh

# 2. Install the material on the nodes
cd exercises && ./deploy.sh

# 3. Put the lab into its pre-exercise state
ssh root@<pve1> '/opt/exercises/long-exercise/nordwind-platform/reset.sh --all'

# 4. Check that the material is intact
ssh root@<pve1> '/opt/exercises/validate.sh'
```

## During the seminar

```bash
# The instructor checks a student's work
ssh root@<pve1> '/opt/exercises/topics/03-cluster-formation/exercise.sh'

# The instructor checks the whole platform
ssh root@<pve1> '/opt/exercises/long-exercise/nordwind-platform/exercise.sh'
```

## After the seminar

```bash
cd .. && ./shutdown.sh      # stop the lab, keep it for the next one
cd .. && ./destroy.sh       # remove everything
```
