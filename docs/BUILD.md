# How we built nested-virt

**Authoritative build log** for the two-AZ nested virtualization lab on AWS bare metal. This is the long-form artifact: what was built, why, in what order, what broke, and how we fixed it.

For a quick launch guide see [README.md](../README.md). For triage when something breaks see [nested-virt-hiccups.md](nested-virt-hiccups.md). For the color-coded network map see [network-diagram.md](network-diagram.md).

---

## What this is

A **provable** nested stack across two availability zones:

```
c7i.metal (Amazon Linux 2023)
  └── KVM (libvirt, br-default)
        └── Windows Server 2022 (Hyper-V host) @ 10.{site}.1.10
              └── Ubuntu 24.04 (Gen2 Hyper-V VM) @ 10.{site}.1.20
```

Cross-AZ routing uses **dedicated transport ENIs** (`kvm-host-nic1`) plus **GRE tunnels** because raw `10.x` lab space does not ride the VPC fabric. Each layer has an explicit proof command (`invoke-routing-proof.sh`).

**Status (June 2026):** L0, L1, and L2 proofs pass both directions on both sites.

---

## Why we built it this way

| Decision | Rationale |
|----------|-----------|
| **Bare metal (`c7i.metal-48xl`)** | Nested virt needs hardware VT-x/AMD-V without the Nitro hypervisor in the way |
| **Two sites, two AZs** | Prove routing is real cross-AZ, not localhost tricks |
| **`10.{site}.*` lab space** | Site 0 uses `10.0.*`, site 1 uses `10.1.*` — no collision when bridged via GRE |
| **Transport ENI + GRE** | VPC carries `172.31.*`; lab `10.x` must be encapsulated |
| **Windows inside KVM, Ubuntu inside Hyper-V** | The actual nested-virt story (L1 + L2), not a flat KVM-only shortcut |
| **Scripted proofs per layer** | Failures are layer-specific; you can tell L0 from L1 from L2 |
| **SSM + S3 bootstrap** | Metal hosts are reachable without relying on lab IPs during bring-up |

Borrowed patterns from [aws-metal-linux-launch](../aws-metal-linux-launch) and [aws-metal-windows-launch](../aws-metal-windows-launch): bridge naming, timing logs (`PHASE=` in `/var/log/amazon/launch-timing.log`), extra ENIs per AZ.

---

## Network architecture (summary)

Full color-coded diagram: **[network-diagram.md](network-diagram.md)**.

| Color / network | CIDR | Where |
|-----------------|------|-------|
| VPC fabric | `172.31.0.0/16` | Primary + transport ENIs |
| Transport subnet | `/28` per AZ | `kvm-host-nic1` |
| Site 0 lab | `10.0.0.0/16` | `br-default` gateway `10.0.1.1` |
| Site 1 lab | `10.1.0.0/16` | gateway `10.1.1.1` |
| GRE overlay | `gre-peer` | Encapsulates peer supernet over transport IPs |
| Hyper-V switch | `NestedVirt-Lab` | External vSwitch; extends `br-default` inside Windows |

---

## Build sequence (order matters)

### Phase 1 — Metal foundation

1. **CloudFormation** per site: `run-site.sh` / `run-both-sites.sh`
   - Instance type `c7i.metal-48xl`, AL2023
   - Primary ENI + transport ENI(s) on tagged `/28` subnets
   - Userdata runs `bootstrap.sh`

2. **`bootstrap.sh`** on each host:
   - `PHASE=DISK` → `FEATURES` → `NIC` → `NESTED` → `KVM` → `PEER` → `VALIDATE` → `COMPLETE`
   - Renames interfaces to `kvm-host-nic0`, `kvm-host-nic1`, …
   - Enables `kvm_intel.nested=1` (or AMD equivalent)
   - Creates bridges; **`br-default`** gets `10.{site}.1.1/24`
   - Policy routing on transport ENI (tables 101/102)

3. **`configure-peer-routing.sh`** (after both sites up):
   - Reads transport IPs from `kvm-host-nic1`
   - Tags instances with `PeerTransportEniIp` and `PeerLabSupernet`
   - Applies `setup-gre-tunnel.sh` + `apply-peer-routes.sh`
   - Writes `sites.env`

**Proof:** `./invoke-routing-proof.sh --layer l0` then `--layer l1`

### Phase 2 — Windows L1 guest (KVM)

4. **`deploy-hyperv-guest.sh`**
   - Uploads `provision-windows-guest.sh`, `autounattend.xml` to S3
   - SSM runs provisioning on both metal hosts

5. **`provision-windows-guest.sh`**
   - Validates nested KVM enabled
   - Downloads Windows Server 2022 ISO (from S3) + virtio-win ISO
   - Builds autounattend floppy with site-specific IP
   - **dnsmasq** on `br-default` with reservations for Windows (`.10`) and inner (`.20`) MACs
   - **`virt-install`** → `win-hv-nested` on `br-default`, **e1000**, MAC `52:54:00:10:00:{site}0`
   - CPU model **`Cascadelake-Server-noTSX`** (critical on 8488C — see hiccup #15)

6. **Autounattend** defers Hyper-V hypervisor install to day-2 script (hiccup #14)

**Proof:** `./invoke-routing-proof.sh --layer l1-guest` and WinRM to `.10`

### Phase 3 — Enable nested Hyper-V inside Windows

7. **`fix-kvm-nested-hyperv-xml.sh`**
   - Requires `vmx`, `kvm_hidden=on`, strips QEMU `<hyperv>` enlightenments
   - Destroy/start `win-hv-nested`; reboot Windows guest

8. **`enable-hyperv-nested-host.ps1`** (via WinRM)
   - `bcdedit /set hypervisorlaunchtype auto`
   - Install Hyper-V with subfeatures
   - Restore lab IP before reboot
   - Verify **`vmms`** → RUNNING

**Proof:** `sc.exe query vmms` inside Windows; `Get-VMSwitch`

### Phase 4 — Ubuntu L2 on Hyper-V (real nested path)

9. **`deploy-inner-ubuntu.sh`** or per-site **`deploy-real-l2.sh`**
   - Upload L2 scripts to S3; SSM runs `deploy-real-l2.sh {site}`

10. **`deploy-real-l2.sh`** orchestrates:
    - Fix KVM XML (if needed)
    - Wait for WinRM
    - Enable Hyper-V / confirm vmms
    - Remove stale **`ubuntu-inner`** from libvirt if present (must not coexist with Hyper-V inner)
    - **`deploy-inner-ubuntu-on-host.sh`**

11. **`prepare-ubuntu-inner-image.sh`** (on metal):
    - Fetch Ubuntu **24.04** cloud image → VHDX
    - **`virt-customize`**: inject static netplan by MAC into disk **before first boot**
    - Build nocloud seed ISO (`cidata`); unique `instance-id` per build
    - Serve VHDX + seed + PS1 over HTTP on `10.{site}.1.1:8090`

12. **`provision-ubuntu-inner-vm.ps1`** (inside Windows via WinRM):
    - Ensure external vSwitch **`NestedVirt-Lab`** (preserve lab IP on `vEthernet`)
    - Download VHDX + seed; create Gen2 VM **`ubuntu-inner`**
    - Static MAC `52540020{site}20`
    - Secure Boot off; **boot disk only** (seed ISO attached but not in boot order)
    - `ExposeVirtualizationExtensions $false` for plain Linux guest

**Proof:** `./invoke-routing-proof.sh --layer l2`

---

## What broke (chronological highlights)

Detailed entries live in [nested-virt-hiccups.md](nested-virt-hiccups.md). These were the big ones:

### Hyper-V never started (`vmms` missing)

Windows saw parent hypervisor (KVM). Fix: `kvm_hidden`, strip QEMU hyperv enlightenments, pass `vmx`, defer Hyper-V in autounattend, then `enable-hyperv-nested-host.ps1` after reboot.

### Boot loop after Hyper-V enable on 8488C

Skylake CPU model in KVM XML caused Automatic Repair loop. Fix: **`Cascadelake-Server-noTSX`**. See hiccup #15.

### L2 proof passes but inner is not on Hyper-V

`virsh list` shows both `win-hv-nested` and `ubuntu-inner` — inner is a libvirt sibling, not a Hyper-V child. Cross-site ping may still work; the stack is not the claimed L2 path. Fix: remove metal-side `ubuntu-inner`, confirm `Get-VM ubuntu-inner` in Windows, redeploy via `deploy-real-l2.sh`.

### Inner `.20` never pingable (Hyper-V path)

Combined failures:
- DVD-first boot order on Gen2 (guest hung; NIC `LostCommunication`)
- Force reinstall reused stale VHDX (cloud-init state poisoned)
- Ubuntu 26.04 unreliable on nested Hyper-V Gen2
- Seed-only reapply without fresh disk

Fix: HD-only boot + **`virt-customize` netplan** + Ubuntu **24.04** + `-ForceReinstall` deletes disk/seed. See hiccup #16.

### Cross-site lab routing

Raw `10.x` over transport ENI failed. Fix: **GRE** (`setup-gre-tunnel.sh`) with routes `10.{peer}.0.0/16 dev gre-peer src 10.{site}.1.1`.

### External vSwitch broke Windows `.10`

Creating vSwitch without restoring IP on `vEthernet`. Fix: capture IP before switch; `-AllowManagementOS $true`; reapply static lab IP.

### SSM script upload

S3 for-loops with `\$f` in SSM parameters → 403. Fix: **explicit `aws s3 cp` per file**.

---

## Lessons learned

1. **Prove the layer you claim.** Verify inner is on Hyper-V (`Get-VM ubuntu-inner`), not a second libvirt guest.
2. **Nested Hyper-V on KVM guests is sensitive to CPU model and enlightenments.** Treat XML as part of the contract.
3. **Lab `10.x` ≠ VPC routable.** Always encapsulate (GRE) or restrict proofs to L0-only cross-site.
4. **Cloud images on nested Hyper-V Gen2:** inject netplan with `virt-customize`; do not rely on DVD-first nocloud boot.
5. **Force reinstall must wipe disks**, not just remove the VM definition.
6. **Operational pattern:** S3 staging + SSM + WinRM + HTTP serve from lab gateway scales better than giant inline PowerShell.
7. **Timing logs:** grep `PHASE=` in `/var/log/amazon/launch-timing.log` on metal and `C:\ProgramData\nested-virt\*.log` in Windows.

---

## Script map

| Script | Runs on | Purpose |
|--------|---------|---------|
| `bootstrap.sh` | Metal | Host bridges, nested KVM, NIC rename |
| `configure-peer-routing.sh` | Laptop | Peer tags, GRE, `sites.env` |
| `deploy-hyperv-guest.sh` | Laptop | SSM Windows L1 deploy both sites |
| `provision-windows-guest.sh` | Metal | KVM Windows install |
| `fix-kvm-nested-hyperv-xml.sh` | Metal | KVM XML for nested Hyper-V |
| `enable-hyperv-nested-host.ps1` | Windows | vmms / hypervisorlaunchtype |
| `deploy-real-l2.sh` | Metal | Full L2 orchestration one site |
| `deploy-inner-ubuntu-on-host.sh` | Metal | Prepare image + WinRM inner deploy |
| `prepare-ubuntu-inner-image.sh` | Metal | VHDX + virt-customize + seed |
| `provision-ubuntu-inner-vm.ps1` | Windows | Hyper-V inner VM |
| `fix-inner-hyperv-network.sh` | Metal | Force redeploy inner (wrapper) |
| `scripts/debug/diag-hyperv-inner.sh` | Metal | L2 diagnose (`quick`/`full`) or `cleanup` before redeploy |
| `setup-gre-tunnel.sh` | Metal | GRE peer tunnel |
| `invoke-routing-proof.sh` | Laptop | Layered routing proofs |
| `experiment-nested-hyperv-cpu.sh` | Metal | CPU model sweep for vmms |

---

## Verification checklist

```bash
# From your laptop (needs sites.env + AWS creds)
./invoke-routing-proof.sh --layer all

# On metal — only Windows KVM guest
virsh list --all   # expect win-hv-nested only

# WinRM / PowerShell inside Windows
sc.exe query vmms          # RUNNING
Get-VM ubuntu-inner        # State Running
Get-VMNetworkAdapter -VMName ubuntu-inner   # Status Ok

# Inner IP
ping 10.0.1.20   # site 0
ping 10.1.1.20   # site 1
```

---

## Related docs

| Doc | Contents |
|-----|----------|
| [network-diagram.md](network-diagram.md) | Color-coded topology, packet walk, proof layers |
| [nested-virt-hiccups.md](nested-virt-hiccups.md) | 16+ tripping points with fixes |
| [hyperv-guest.md](hyperv-guest.md) | Windows guest day-2 notes |
| [reinvent-pitch.md](reinvent-pitch.md) | Session / chaos-monkey framing |
| [ROADMAP.md](ROADMAP.md) | Terraform port (next) |

---

## Tomorrow: Terraform

**Next step:** port this lab to Terraform. See [ROADMAP.md](ROADMAP.md) for scope. CloudFormation + shell scripts remain the reference implementation until TF lands.

---

*Built by Adrian SanMiguel — nested virt on AWS metal, proven layer by layer.*
