# nested-virt

Nested virtualization on AWS bare metal: **KVM on Amazon Linux 2023**, with **Hyper-V inside a Windows guest**, across **two availability zones** with explicit, provable routing.

Borrowed from [aws-metal-linux-launch](../aws-metal-linux-launch) and [aws-metal-windows-launch](../aws-metal-windows-launch): metal launch, extra ENIs, bridge lab layout, timing logs. This repo is the crackpot layer on top.

## Architecture

```
 AZ-a (site 0)                              AZ-b (site 1)
┌─────────────────────────┐                ┌─────────────────────────┐
│ c7i.metal-48xl (AL2023) │   VPC routing  │ c7i.metal-48xl (AL2023) │
│  kvm-host-nic0 → NAT    │◄──────────────►│  kvm-host-nic0 → NAT    │
│  kvm-host-nic1 → /28 ENI│  172.31.96.x   │  kvm-host-nic1 → /28 ENI│
│  br-default 10.0.1.0/24 │                │  br-default 10.1.1.0/24 │
│    └─ Windows + Hyper-V │                │    └─ Windows + Hyper-V │
│         └─ inner VM     │                │         └─ inner VM     │
└─────────────────────────┘                └─────────────────────────┘
```

**Routing layers**

| Layer | Path | Proof |
|-------|------|-------|
| L0 | `kvm-host-nic1` ENI ↔ ENI (cross-AZ) | `invoke-routing-proof.sh --layer l0` |
| L1 | Site lab bridges (`10.{site}.0.0/16`) via peer ENI | `--layer l1` |
| L2 | Nested Hyper-V guest ↔ guest | `--layer l2` (manual / future) |

Each site uses **`10.{SiteId}.*`** lab space so two hosts do not collide on `10.0.250.1/24`.

## Quick start

```bash
cp config.local.env.example config.local.env   # KEY_NAME
./run-both-sites.sh
./poll-timing.sh                                 # after bootstrap
./configure-peer-routing.sh                      # wire cross-site routes
./invoke-routing-proof.sh
```

Single site:

```bash
SITE_ID=0 AVAILABILITY_ZONE=us-east-1a ./run-site.sh
```

Teardown:

```bash
./teardown-stacks.sh
```

## Bootstrap phases

`DISK` → `FEATURES` → `NIC` → `NESTED` → `KVM` → `PEER` → `VALIDATE` → `COMPLETE`

Log: `/var/log/amazon/launch-timing.log` (`PHASE=` lines, same pattern as metal launch repos).

## Hyper-V guest (next step)

See [docs/hyperv-guest.md](docs/hyperv-guest.md). Host bootstrap stops at KVM + routing; Windows/Hyper-V is day-2 on `br-default`.

**Later:** macOS metal + microVMs — see [docs/future-macos-metal.md](docs/future-macos-metal.md).

## Layout

```
nested-virt/
  bootstrap.sh
  userdata-stub.sh
  run-site.sh
  run-both-sites.sh
  configure-peer-routing.sh
  invoke-routing-proof.sh
  poll-timing.sh
  teardown-stacks.sh
  config.env
  sites.env.example
  cloudformation/
  docs/hyperv-guest.md
```

## Related repos

| Repo | Role |
|------|------|
| `aws-metal-linux-launch` | KVM host baseline, bridge naming, NIC subnet helper |
| `aws-metal-windows-launch` | Hyper-V lab network layout (mirrored in bridges) |

---

**Adrian SanMiguel** (adrianrs)
