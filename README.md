# nested-virt

### Nested virtualization on AWS bare metal. Two AZs. Three hypervisor layers. One script that tells you which layer is lying.

---

> **Everything in this repo already ran green.**  
> KVM on metal → Windows with Hyper-V → Ubuntu inside that → ping across availability zones.  
> Not a diagram. Not a slide. Not "it worked once on my laptop."

If you're here because someone said *"nested virt on AWS doesn't work"* — cool. They're wrong. If you're here because someone said *"it definitely works, just trust me"* — also wrong, and worse, because **trust without proof is how you find out at 2am.**

This lab gives you **proof**. Layer by layer. Script by script. When something breaks — and something will — you'll know whether to blame the transport ENI, the GRE tunnel, the Windows guest, or the hypervisor inside the hypervisor inside the box you pay AWS way too much money for.

---

## The crackpot stack (that actually works)

```
 YOU ARE HERE ──►  c7i.metal-48xl  (Amazon Linux 2023, real VT-x, no Nitro in your way)
                         │
                    KVM / libvirt
                         │
              Windows Server 2022  @ 10.{site}.1.10
                         │
                    Hyper-V (vmms RUNNING, no copium)
                         │
              Ubuntu 24.04 Gen2    @ 10.{site}.1.20
                         │
                    ping 10.1.1.20 from the other AZ  ✓
```

**Site 0** lives in `10.0.0.0/16`. **Site 1** lives in `10.1.0.0/16`. They talk over **dedicated transport ENIs** (`kvm-host-nic1`) because the VPC fabric speaks `172.31.*`, not your lab fantasy `10.x` — so we **GRE-encapsulate** the peer supernet and stop pretending AWS is a dumb L2 switch.

Two `c7i.metal-48xl` instances. Two availability zones. **Three routing layers.** One `./invoke-routing-proof.sh`.

Full color-coded map (every CIDR, bridge, tunnel, MAC): **[docs/network-diagram.md](docs/network-diagram.md)**

---

## Why this exists (500-level, no fluff)

| Question | Answer |
|----------|--------|
| **Why bare metal?** | On normal EC2 you're already a guest. Nested virt needs the **actual CPU** — VT-x passed through, hypervisor hidden from the child, XML surgery when Windows gets sniffy. Metal or don't bother. |
| **Why KVM → Hyper-V → Linux?** | Because *that's the nested part people argue about*. One hypervisor is a Tuesday. Three layers with cross-site routing is the thesis. |
| **Why two AZs?** | So nobody can hand-wave "oh it works locally." Site 0 pings Site 1's **inner** guest IP through GRE over transport ENIs. ~2 ms. Receipts attached. |
| **Why scripted proofs?** | Because **L2 can look green while the architecture is wrong.** Same lab IP space + routing can hide a missing layer. We prove the layer you claim, not just "ping returned 0." |
| **Why so many hiccups docs?** | Because we earned every one. Sapphire Rapids CPU models. APIPA Windows guests. DVD-first boot hangs. Stale VHDX. GRE vs raw `10.x`. It's all in there. |

Borrowed bones from [aws-metal-linux-launch](../aws-metal-linux-launch) and [aws-metal-windows-launch](../aws-metal-windows-launch). The **crackpot layer on top** is mine.

---

## The proof matrix (run this, argue with me later)

This is the whole point. **Failures have layers.** Prove each one independently.

| Layer | What it actually proves | Command |
|-------|-------------------------|---------|
| **L0** | Transport ENI ↔ transport ENI across AZs (`kvm-host-nic1`, bind to transport IP) | `./invoke-routing-proof.sh --layer l0` |
| **L1** | Lab gateways `10.{site}.1.1` + Windows guests `.10` cross-site (GRE in the path) | `--layer l1` · `--layer l1-cross` |
| **L2** | Inner Ubuntu `.20` on **Hyper-V inside Windows** — local *and* cross-AZ | `--layer l2` |
| **ALL** | Full matrix. The money shot. | `--layer all` |

**Green L2 cross-site looks like:**

```text
Site 0 metal ──► ping 10.1.1.20  ──►  ttl=63, ~1.5 ms
Site 1 metal ──► ping 10.0.1.20  ──►  ttl=63, ~2 ms
Routing proof PASSED (l2).
```

That's an inner VM, inside Hyper-V, inside a KVM guest, on metal, **in another availability zone**. If that sentence doesn't make you slightly unwell, you're not paying attention.

**Verify you're not fooling yourself on L2:**

```bash
virsh list --all          # should show win-hv-nested ONLY
# inside Windows (WinRM):
Get-VM ubuntu-inner       # State: Running
sc.exe query vmms         # RUNNING
```

Inner on Hyper-V, not a second libvirt guest. [Hiccup #1](docs/nested-virt-hiccups.md) if you cheat and the ping still works.

---

## Architecture at a glance

```
  AZ-a (site 0)                              AZ-b (site 1)
 ┌──────────────────────────┐    GRE over    ┌──────────────────────────┐
 │ c7i.metal-48xl           │    172.31.*     │ c7i.metal-48xl           │
 │  nic0 → VPC / SSM / SSH  │◄═══════════════►│  nic0 → VPC / SSM / SSH  │
 │  nic1 → transport /28    │   gre-peer      │  nic1 → transport /28    │
 │  br-default  10.0.1.1    │                 │  br-default  10.1.1.1    │
 │    └─ Windows    .10     │                 │    └─ Windows    .10     │
 │         └─ Ubuntu  .20   │                 │         └─ Ubuntu  .20   │
 └──────────────────────────┘                 └──────────────────────────┘
```

- **Gateways:** `10.0.1.1` / `10.1.1.1` (dnsmasq, HTTP serve for inner deploy, GRE endpoint)
- **Guests:** Windows `.10`, inner Ubuntu `.20` (static MACs, netplan injected via `virt-customize`)
- **Hyper-V switch:** `NestedVirt-Lab` external vSwitch — lab L2 extended *inside* the Windows guest

---

## Bring it up (for operators, not tourists)

### Prerequisites

- **`c7i.metal-48xl` quota** in two AZs (e.g. `us-east-1a` + `us-east-1b`)
- VPC + per-AZ **`/28` transport subnets** tagged `win-metal-hv-nic-{az}`
- EC2 key pair, AWS CLI, **SSM** to the hosts
- **Windows Server 2022 ISO** in S3
- Acceptance that metal is **not free** and this lab is **not subtle**

### 1 · Configure

```bash
cp config.local.env.example config.local.env    # KEY_NAME
cp cloudformation/parameters.example.json cloudformation/parameters.json
# config.env — VPC/subnet IDs if not using defaults
```

### 2 · Launch both sites

```bash
./run-both-sites.sh
./poll-timing.sh
# host: grep PHASE= /var/log/amazon/launch-timing.log
# DISK → FEATURES → NIC → NESTED → KVM → PEER → VALIDATE → COMPLETE
```

### 3 · Wire cross-AZ (GRE + peer tags)

```bash
./configure-peer-routing.sh    # writes sites.env
./invoke-routing-proof.sh --layer l0
./invoke-routing-proof.sh --layer l1
```

### 4 · Windows L1 (KVM guest + Hyper-V host)

```bash
WINDOWS_ISO_S3_URI=s3://your-bucket/Win2022.iso ./deploy-hyperv-guest.sh
# wait for 10.{site}.1.10 + WinRM :5985
# password: /var/lib/nested-virt/win-guest-admin-password on metal
```

### 5 · Ubuntu L2 (Hyper-V inner guest)

```bash
./deploy-inner-ubuntu.sh
# KVM XML fix → vmms → Hyper-V ubuntu-inner @ .20
```

### 6 · Prove it or go home

```bash
./invoke-routing-proof.sh --layer all
```

**Teardown before finance notices:**

```bash
./teardown-stacks.sh
```

Single site only: `SITE_ID=0 AVAILABILITY_ZONE=us-east-1a ./run-site.sh`

---

## When it breaks (it will)

We didn't write 16 hiccups for sport. Highlights:

| Symptom | Likely layer | Start here |
|---------|--------------|------------|
| Cross-AZ transport dead | L0 | `kvm-host-nic1` IP, policy routes, SG |
| Lab gateway unreachable cross-site | L1 | GRE tunnel, `configure-peer-routing.sh` |
| `.10` gone / APIPA / WinRM dead | L1 guest | [hiccup #12](docs/nested-virt-hiccups.md), dnsmasq, vSwitch |
| `vmms` missing / boot loop after Hyper-V | Nested enable | [hiccup #2, #15](docs/nested-virt-hiccups.md) — **Cascadelake CPU on 8488C** |
| `.20` down, NIC `LostCommunication` | L2 | [hiccup #16](docs/nested-virt-hiccups.md), `fix-inner-hyperv-network.sh` |
| L2 ping works but `virsh` shows two VMs | Wrong layer | [hiccup #1](docs/nested-virt-hiccups.md) |

**Full war stories:** [docs/nested-virt-hiccups.md](docs/nested-virt-hiccups.md)  
**How we actually built it:** [docs/BUILD.md](docs/BUILD.md)  
**Tomorrow:** [docs/ROADMAP.md](docs/ROADMAP.md) — Terraform port (CFN + bash stays reference until then)

---

## re:Invent angle

Session pitch lives in [docs/reinvent-pitch.md](docs/reinvent-pitch.md). Short version:

> *Everything you are about to see is already running. I am not here to deploy. I am here to break things.*

Green proofs first. Chaos second. Audience fixes layer by layer. Same scripts for diagnose and verify. **If you can't break it on purpose, you can't trust it in prod.**

Recommended title energy: **"Can You Fix a Three-Layer Nested Virt Stack Before I Break Something Else?"**

---

## Repo map

```
nested-virt/
  run-both-sites.sh              # two AZs, let's go
  configure-peer-routing.sh      # GRE + sites.env
  deploy-hyperv-guest.sh         # Windows on KVM
  deploy-inner-ubuntu.sh         # Ubuntu on Hyper-V (both sites)
  invoke-routing-proof.sh        # THE diagnostic
  bootstrap.sh                   # metal phases (PHASE= logs)
  scripts/                       # fix-kvm-xml, enable-hyperv, virt-customize, WinRM PS1…
  docs/
    BUILD.md                     # authoritative build log
    network-diagram.md           # color-coded topology
    nested-virt-hiccups.md       # triage FAQ
    ROADMAP.md                   # Terraform next
    reinvent-pitch.md            # session deck in prose
```

---

## Honest limits (say these out loud)

- **Two metal instances cost real money.** Build it, prove it, tear it down.
- **Lab `10.x` does not magically ride VPC.** That's why GRE exists. Read [network-diagram.md](docs/network-diagram.md).
- **Nested Hyper-V on KVM is picky.** CPU model, hidden KVM, no spurious QEMU hyperv enlightenments. We documented the scars.
- **Chaos monkey scripts** are on the roadmap — proofs exist today; break/fix loop is the session format.

---

## Related repos

| Repo | Role |
|------|------|
| [aws-metal-linux-launch](../aws-metal-linux-launch) | KVM host baseline, bridges, NIC naming |
| [aws-metal-windows-launch](../aws-metal-windows-launch) | Transport subnets, Hyper-V lab layout |

---

**Adrian SanMiguel** · [github.com/arsanmiguel/nested-virt](https://github.com/arsanmiguel/nested-virt)

Nested virt on AWS metal works. **Proving which layer broke when it stops** — that's the skill. Take the repo. Run the proofs. Fix it before the pager goes off.
