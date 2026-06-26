# Nested-virt hiccups and fixes

Living FAQ for the **KVM → Hyper-V → Ubuntu** stack on AWS bare metal. Each entry is a real tripping point from building this lab — not theory.

**Target stack:**

```
c7i.metal (AL2023)
  └── KVM (libvirt, br-default)
        └── Windows Server VM @ 10.{site}.1.10  (Hyper-V host)
              └── Ubuntu VM @ 10.{site}.1.20   (inner guest)
```

---

## 1. "L2 is green" but it's the wrong architecture

**Symptom:** `./invoke-routing-proof.sh --layer l2` passes; inner Ubuntu at `.20` is pingable cross-site.

**Trap:** The inner VM may be a **sibling KVM guest** on `br-default`, not a child of Hyper-V. `virsh list` on the metal host shows both `win-hv-nested` and `ubuntu-inner`.

**How to tell:**

```bash
virsh list --all                    # both VMs on metal = wrong L2 path
# From Windows guest (WinRM):
Get-VM ubuntu-inner                 # should exist here for real L2
sc.exe query vmms                   # must be RUNNING
```

**Fix:** Destroy metal `ubuntu-inner`, fix nested Hyper-V (`vmms`), provision Ubuntu via `deploy-inner-ubuntu-on-host.sh` (WinRM → Hyper-V).

**Lesson:** Same lab IP + GRE routing can mask a missing hypervisor layer. Proofs must match the stack you claim.

---

## 2. Hyper-V role installs but `vmms` does not exist

**Symptom:** `Get-WindowsFeature Hyper-V` → `Installed = True`. `sc.exe query vmms` → error 1060 (service does not exist).

**Cause:** Windows is a KVM guest and still detects a parent hypervisor. The Hyper-V **management** feature installs; the **hypervisor kernel component** (`vmms`) does not.

**Fix (KVM side — required first):**

| Setting | Purpose |
|---------|---------|
| Host `kvm_intel.nested=1` | Allow nesting on metal |
| `--cpu host-passthrough,require=vmx` | Pass VT-x into Windows guest |
| `--features kvm_hidden=on,hyperv=off` | Hide KVM from guest; don't paravirt Windows as Hyper-V guest |
| XML: `<kvm><hidden state='on'/></kvm>` | Same as kvm_hidden for defined domains |
| XML: remove `<hyperv mode='custom'>` enlightenments | Stops QEMU Hyper-V paravirt confusing nested HV |
| XML: `<timer name='hypervclock' present='no'/>` | Drop hyperv clock when stripping enlightenments |

Script: `scripts/fix-kvm-nested-hyperv-xml.sh` then **reboot Windows guest**.

**Fix (Windows side — after KVM XML + reboot):**

Script: `scripts/enable-hyperv-nested-host.ps1`

- `bcdedit /set hypervisorlaunchtype auto`
- Reinstall Hyper-V with `-IncludeAllSubFeature`
- Verify `sc.exe query vmms` → `RUNNING`

**Verify:**

```powershell
sc.exe query vmms
Get-VMSwitch
Get-VM
```

---

## 3. Partial nested config (vmx yes, enlightenments still on)

**Symptom:** `virsh dumpxml` shows `<feature policy='require' name='vmx'/>` and `<kvm hidden>`, but also empty `<hyperv mode='custom'>` block and `hypervclock present='yes'`.

**Cause:** `enable-nested-hyperv.sh` ran once; enlightenments were not fully stripped, or guest was recreated with default libvirt Hyper-V opts for Windows.

**Fix:** Run `fix-kvm-nested-hyperv-xml.sh`, destroy/start `win-hv-nested`, reboot Windows, rerun `enable-hyperv-nested-host.ps1`.

---

## 4. External Hyper-V vSwitch broke Windows guest networking

**Symptom:** After `New-VMSwitch -NetAdapterName ...`, Windows guest at `.10` stops pingable; WinRM fails.

**Cause:** Binding the physical (virtio/e1000) NIC to an external switch renames/moves the management adapter to `vEthernet (SwitchName)` without preserving lab IP/gateway.

**Fix:** In `provision-ubuntu-inner-vm.ps1`:

1. Capture IP/gateway/DNS from the uplink NIC **before** switch creation.
2. Create external switch with `-AllowManagementOS $true`.
3. Re-apply static lab IP on the `vEthernet (...)` adapter if DHCP didn't restore it.

**Lesson:** Never create an external vSwitch blind on a remotely managed Windows guest.

---

## 5. Metal KVM inner VM shortcut (deploy-inner-ubuntu.sh drift)

**Symptom:** `deploy-inner-ubuntu.sh` uploads `provision-ubuntu-inner-kvm.sh` and says "Ubuntu on metal KVM".

**Cause:** Hyper-V path blocked by `vmms`; agent pivoted to get L2 green without completing the nested chain.

**Fix:** `deploy-inner-ubuntu.sh` must call `deploy-inner-ubuntu-on-host.sh` (Hyper-V path). Keep `provision-ubuntu-inner-kvm.sh` only as `--fallback` for routing experiments, not default L2.

---

## 6. Windows reinstall wipes dnsmasq inner reservations

**Symptom:** Inner VM boots but never gets `.20`; `grep 52:54:00:20 /etc/nested-virt-dnsmasq.conf` empty after Windows reprovision.

**Cause:** `setup_lab_dhcp()` in `provision-windows-guest.sh` overwrote dnsmasq config with Windows MAC only.

**Fix:** Always write **both** Windows (`.10`) and inner (`.20`) MAC reservations in `setup_lab_dhcp()` and `write_lab_dnsmasq()`.

---

## 7. Inner Ubuntu boot order / cloud-init failures (metal fallback path)

**Symptom:** `virsh dumpxml ubuntu-inner` shows `<boot dev='cdrom'/>` only; guest hangs; no IP.

**Fixes that worked:**

- `--boot hd,menu=off` (no seed CDROM boot)
- `virt-customize` inject static netplan by MAC before first boot
- Independent disk (`qemu-img convert`) not stale backing overlay

---

## 8. Site ID / parallel deploy races

**Symptom:** Site 1 inner VM got `10.0.1.20` instead of `10.1.1.20`; apt/dpkg lock errors when Windows + inner deploy ran together.

**Fix:** Always pass explicit site arg (`provision-ubuntu-inner-kvm.sh 1`). Serialize heavy deploys per host or use `flock` on apt.

---

## 9. WinRM "command line too long"

**Symptom:** Provisioning inner VM via WinRM fails on huge inline PowerShell.

**Fix:** Serve `provision-ubuntu-inner-vm.ps1` over HTTP from metal gateway (`python3 -m http.server` on `10.{site}.1.1`), download inside guest, execute locally.

---

## 10. Cross-site lab routing (GRE)

**Symptom:** Cross-site ping to `10.x.1.x` fails; transport ENI ping works.

**Cause:** Raw `10.x` lab space doesn't ride VPC fabric. Needs GRE tunnel between transport ENIs with `src=10.{site}.1.1` on routes.

**Fix:** `scripts/setup-gre-tunnel.sh` + `apply-peer-routes.sh` (committed in `fb8c118`).

---

## 11. `Set-VMProcessor -ExposeVirtualizationExtensions`

**When needed:** Inner Ubuntu must run its **own** hypervisor (L3). Set `$true` only then.

**L2 (this lab):** Use **`$false`**. `$true` contributed to boot/NIC issues on nested Hyper-V Gen2 with Ubuntu 24.04.

**Fix location:** `provision-ubuntu-inner-vm.ps1`

---

## 12. Windows guest stuck on APIPA (169.254.x) after Hyper-V hypervisor enable

**Symptom:** `virsh` shows `win-hv-nested` running; metal host ARP shows `169.254.x.x` for Windows MAC; ping `.10` fails; WinRM dead.

**Cause:** Hyper-V hypervisor install/reboot reset NIC config; guest lost static/DHCP lab address. Hyper-V can also rebind the physical NIC to the virtual switch stack before a vSwitch exists.

**Fix:**

1. Avoid destructive `Uninstall-WindowsFeature Hyper-V` when role already installed — use `Enable-WindowsOptionalFeature` + `bcdedit` first (`enable-hyperv-nested-host.ps1` v2).
2. Script restores lab IP **before** scheduling reboot (`Restore-LabIp`).
3. Register **startup scheduled task before** `Install-WindowsFeature Hyper-V` in autounattend (order 3 task, order 4 Hyper-V) — otherwise Hyper-V reboot skips task creation.
4. Recovery on metal: restart dnsmasq, `virsh destroy && virsh start win-hv-nested`, wait for startup task (up to 10 min).
5. If still APIPA: `FORCE_REINSTALL=1 ./deploy-hyperv-guest.sh`.

---

## 13. `virt-install --features hyperv=off` fails on AL2023

**Symptom:** `ERROR Unknown --features options: ['hyperv']` — Windows guest never reinstalls.

**Fix:** Use `--features kvm_hidden=on` only; strip `<hyperv>` enlightenments post-define with `fix-kvm-nested-hyperv-xml.sh`.

---

## 14. Do not install Hyper-V in autounattend before KVM XML fix

**Symptom:** Fresh Windows pingable at `.10`; after `fix-kvm-nested-hyperv-xml.sh` destroy/start → APIPA; `vmms` never appears.

**Cause:** Hyper-V role installed during OOBE rebinds NICs. Rebooting the guest before nested KVM enlightenments are stripped leaves Windows without lab IP and without a working hypervisor stack.

**Fix:** Autounattend registers the startup task but **defers** Hyper-V install to `enable-hyperv-nested-host.ps1`.

**Fix:** Inline PowerShell via WinRM (`run_ps` with script body + injected `$SiteId`). Never `& '/tmp/foo.ps1'` from the guest — that path is on the metal host.

---

## 15. Sapphire Rapids (8488C) needs Cascadelake KVM CPU for nested Hyper-V

**Symptom:** Windows guest boots to desktop, but enabling Hyper-V (`hypervisorlaunchtype auto`) causes boot loop / Automatic Repair. `vmms` never stays RUNNING.

**Cause:** Host CPU is Intel Xeon Platinum **8488C** (Sapphire Rapids). KVM `Skylake-Server-noTSX-IBRS` is a poor match; nested Hyper-V fails during hypervisor bring-up.

**Fix:** Use `Cascadelake-Server-noTSX` with `vmx` required, `hypervisor` disabled, `kvm_hidden=on` (`fix-kvm-nested-hyperv-xml.sh`, `provision-windows-guest.sh`). Experiment with `experiment-nested-hyperv-cpu.sh` before full deploy.

---

## 16. Hyper-V inner Ubuntu: LostCommunication / no `.20` ping

**Symptom:** `Get-VM ubuntu-inner` → Running, but `Get-VMNetworkAdapter` shows **LostCommunication**; Hyper-V integration **Heartbeat: No Contact**; metal ARP for `.20` stays INCOMPLETE.

**Cause (often combined):**

1. **DVD-first boot order** — Gen2 firmware tries to boot the nocloud seed ISO; guest never reaches a running kernel. Seed ISO must stay attached but **not** be in `-BootOrder` (same lesson as metal KVM hiccup #7).
2. **Stale VHDX on force reinstall** — removing the VM but reusing `ubuntu-inner-disk.vhdx` skips cloud-init first boot; reapplying seed alone does not reconfigure the disk.
3. **Ubuntu 26.04 cloud image** — on nested Hyper-V Gen2 this stack saw persistent boot failure; **24.04 LTS** booted reliably.
4. **`ExposeVirtualizationExtensions $true`** on a plain Linux guest — not needed for L2; set **`$false`**.

**Fix:**

1. `prepare-ubuntu-inner-image.sh`: **`virt-customize`** inject static netplan by MAC into the served VHDX before first boot; default **`UBUNTU_RELEASE=24.04`**.
2. `provision-ubuntu-inner-vm.ps1`: boot **disk only**; `-ForceReinstall` deletes VM **and** disk/seed artifacts before re-download.
3. Run `./scripts/fix-inner-hyperv-network.sh {site}` (force redeploy wrapper) — upload scripts to S3 with **explicit** `aws s3 cp` per file (SSM for-loops with `\$f` get 403).

**Verify:** `Get-VMNetworkAdapter` Status → **Ok**; `ping 10.{site}.1.20` from metal; `./invoke-routing-proof.sh --layer l2`.

---

## Proof checklist (real L2)

| Check | Command / expected |
|-------|-------------------|
| Metal has Windows only (no metal inner) | `virsh list` → `win-hv-nested` only |
| Hyper-V host alive | `sc.exe query vmms` → RUNNING |
| Inner on Hyper-V | WinRM: `Get-VM ubuntu-inner` → Running |
| Inner IP | `ping 10.{site}.1.20` from metal |
| Cross-site | `./invoke-routing-proof.sh --layer l2` |

---

## Script map

| Script | Layer |
|--------|-------|
| `bootstrap.sh` | Metal: nested KVM, bridges |
| `provision-windows-guest.sh` | L1 Windows on KVM |
| `fix-kvm-nested-hyperv-xml.sh` | KVM XML for nested Hyper-V |
| `enable-hyperv-nested-host.ps1` | Windows: vmms / hypervisor launch |
| `prepare-ubuntu-inner-image.sh` | VHDX + seed on metal |
| `provision-ubuntu-inner-vm.ps1` | L2 Ubuntu on Hyper-V |
| `deploy-inner-ubuntu-on-host.sh` | Orchestrate L2 on one site |
| `deploy-inner-ubuntu.sh` | Both sites, Hyper-V path |
| `provision-ubuntu-inner-kvm.sh` | **Fallback only** — metal KVM shortcut |

---

*Updated during live debugging — add new entries when something bites you.*
