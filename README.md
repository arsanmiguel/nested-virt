# nested-virt

**Nested virtualization on AWS bare metal — provable end-to-end routing across two availability zones.**

KVM on `c7i.metal-48xl` (Amazon Linux 2023) → Windows Server 2022 with Hyper-V → Ubuntu 24.04 inner VM. Lab networks in `10.{site}.*` linked cross-AZ over dedicated transport ENIs and GRE. Every layer has a scripted proof.

| Doc | What it is |
|-----|------------|
| **[docs/BUILD.md](docs/BUILD.md)** | **How it was built** — sequence, decisions, lessons, script map |
| **[docs/network-diagram.md](docs/network-diagram.md)** | **Color-coded network topology** — every CIDR, bridge, tunnel, guest |
| **[docs/nested-virt-hiccups.md](docs/nested-virt-hiccups.md)** | **Triage FAQ** — 16+ real failures and fixes |
| **[docs/ROADMAP.md](docs/ROADMAP.md)** | **Next: Terraform port** (planned) |
| [docs/hyperv-guest.md](docs/hyperv-guest.md) | Windows / Hyper-V day-2 |
| [docs/reinvent-pitch.md](docs/reinvent-pitch.md) | Session / chaos-monkey pitch |

---

## Why this exists

Bare metal gives you real hardware VT-x. Nested virt (KVM → Hyper-V → Linux) is the hard part. Cross-AZ lab routing on top is the crackpot part.

This repo proves both **work on AWS** and gives you **layered diagnostics** when they do not:

| Layer | What it proves | Command |
|-------|----------------|---------|
| **L0** | Transport ENIs (`kvm-host-nic1`) ping across VPC | `./invoke-routing-proof.sh --layer l0` |
| **L1** | Lab gateways `10.{site}.1.1` and Windows `.10` cross-site | `--layer l1` / `l1-cross` |
| **L2** | Inner Ubuntu `.20` on Hyper-V inside Windows | `--layer l2` |
| **All** | Full matrix | `--layer all` |

See the **[network diagram](docs/network-diagram.md)** for color-coded topology and packet paths.

---

## Architecture (one glance)

```
 AZ-a (site 0)                              AZ-b (site 1)
┌─────────────────────────┐   GRE over    ┌─────────────────────────┐
│ c7i.metal-48xl (AL2023) │   transport   │ c7i.metal-48xl (AL2023) │
│  kvm-host-nic0 → VPC    │◄─────────────►│  kvm-host-nic0 → VPC    │
│  kvm-host-nic1 → /28    │   172.31.*    │  kvm-host-nic1 → /28    │
│  br-default 10.0.1.1    │               │  br-default 10.1.1.1    │
│    └─ Windows .10       │               │    └─ Windows .10       │
│         └─ Ubuntu .20   │               │         └─ Ubuntu .20   │
└─────────────────────────┘               └─────────────────────────┘
```

- **Site 0** lab: `10.0.0.0/16` (gateway `10.0.1.1`, Windows `.10`, inner `.20`)
- **Site 1** lab: `10.1.0.0/16` (gateway `10.1.1.1`, Windows `.10`, inner `.20`)
- **GRE** `gre-peer` encapsulates peer supernet because VPC does not carry raw `10.x`

Full detail: [docs/network-diagram.md](docs/network-diagram.md)

---

## Prerequisites

- AWS account with **c7i.metal-48xl** quota in **two AZs** (e.g. `us-east-1a`, `us-east-1b`)
- VPC with private `/28` transport subnets tagged `win-metal-hv-nic-{az}` (see [aws-metal-windows-launch](../aws-metal-windows-launch))
- EC2 key pair, AWS CLI, Session Manager access to instances
- **Windows Server 2022 ISO** in S3 (for L1 guest install)
- Local: `bash`, `aws`, `jq` (optional), SSH key for metal host

---

## Quick start

### 1. Configure

```bash
cp config.local.env.example config.local.env   # set KEY_NAME
cp cloudformation/parameters.example.json cloudformation/parameters.json
# Edit config.env if VPC/subnet IDs differ from defaults
```

### 2. Launch both metal sites

```bash
./run-both-sites.sh
```

Poll bootstrap on each host:

```bash
./poll-timing.sh                    # or SITE_ID=0 ./poll-timing.sh
# On host: grep PHASE= /var/log/amazon/launch-timing.log
```

Expected phases: `DISK` → `FEATURES` → `NIC` → `NESTED` → `KVM` → `PEER` → `VALIDATE` → `COMPLETE`

### 3. Wire cross-site routing

```bash
./configure-peer-routing.sh         # writes sites.env, sets up GRE
```

### 4. Prove L0 + L1 (no guests yet)

```bash
./invoke-routing-proof.sh --layer l0
./invoke-routing-proof.sh --layer l1
```

### 5. Deploy Windows L1 guests (KVM)

Upload ISO to S3, then:

```bash
WINDOWS_ISO_S3_URI=s3://your-bucket/Win2022.iso ./deploy-hyperv-guest.sh
```

Wait for `10.{site}.1.10` pingable; WinRM on port 5985. Password on host: `/var/lib/nested-virt/win-guest-admin-password`

### 6. Enable nested Hyper-V + L2 inner Ubuntu

```bash
./deploy-inner-ubuntu.sh            # both sites, real L2 path
# Or one site: SSM run scripts/deploy-real-l2.sh {0|1} on metal
```

This runs: KVM XML fix → `vmms` → Hyper-V Ubuntu @ `.20`

### 7. Prove everything

```bash
./invoke-routing-proof.sh --layer all
```

**Success looks like:** cross-site ping to `10.1.1.20` from site 0 and `10.0.1.20` from site 1 (~1–2 ms).

---

## Single-site / teardown

```bash
SITE_ID=0 AVAILABILITY_ZONE=us-east-1a ./run-site.sh
./teardown-stacks.sh
```

---

## Recovery shortcuts

| Problem | Script / doc |
|---------|----------------|
| Inner `.20` down | `./scripts/fix-inner-hyperv-network.sh {site}` via SSM on metal |
| `vmms` not running | [hiccups #2, #15](docs/nested-virt-hiccups.md) + `fix-kvm-nested-hyperv-xml.sh` |
| Two libvirt VMs (`win-hv-nested` + `ubuntu-inner`) | [hiccup #1](docs/nested-virt-hiccups.md) — inner must be on Hyper-V |
| Cross-site lab dead | [hiccup #10](docs/nested-virt-hiccups.md) — GRE / peer routes |

Full build narrative and chronological debug log: **[docs/BUILD.md](docs/BUILD.md)**

---

## Repo layout

```
nested-virt/
  bootstrap.sh                 # Metal host bring-up
  configure-peer-routing.sh      # GRE + sites.env
  deploy-hyperv-guest.sh         # Windows L1 (both sites)
  deploy-inner-ubuntu.sh         # Ubuntu L2 on Hyper-V (both sites)
  invoke-routing-proof.sh        # Layered proofs
  run-both-sites.sh              # CFN deploy site 0 + 1
  cloudformation/                # Stack templates (→ Terraform tomorrow)
  scripts/                       # Provision + fix scripts (S3 + SSM)
  docs/
    BUILD.md                     # ← authoritative build write-up
    network-diagram.md           # ← color-coded topology
    nested-virt-hiccups.md       # ← triage FAQ
    ROADMAP.md                   # ← Terraform port plan
```

---

## Related repos

| Repo | Role |
|------|------|
| [aws-metal-linux-launch](../aws-metal-linux-launch) | KVM host baseline, bridge naming |
| [aws-metal-windows-launch](../aws-metal-windows-launch) | Hyper-V lab network / transport subnets |

---

## Next up

**Terraform port** — same topology, declarative infra. See [docs/ROADMAP.md](docs/ROADMAP.md).

---

**Adrian SanMiguel** — nested virt on AWS metal, layer by layer.
