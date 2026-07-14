# Nested-virt hiccups and fixes

Symptom → cause → fix index for the **KVM → Hyper-V → Ubuntu** stack on AWS bare metal.

**Related:** [README](../README.md) · [Deploy guide](DEPLOY-FROM-CFN.md) · [Developer guide](BUILD.md) · [Cost post-mortem](COST-POSTMORTEM.md) · [Security design](SECURITY-EXCEPTIONS.md)

**Target stack:**

```
c7i.metal (AL2023)
  └── KVM (libvirt, br-default)
        └── Windows Server VM @ 10.{site}.1.10  (Hyper-V host)
              └── Ubuntu VM @ 10.{site}.1.20   (inner guest)
```

---

## Quick index by phase

| Phase | # | Topic |
|-------|---|--------|
| Bootstrap | [6](#6-bootstrap-fails-on-fresh-metal-nvme-device-order) | NVMe root vs data disk order |
| Metal security | [7](#7-system-dnsmasq-listens-on-53) · [8](#8-guest-https-works-but-inner-cannot-curl) · [9](#9-vnc-bound-to-0000) | DNS, guest resolvers, VNC |
| Routing | [10](#10-cross-site-lab-routing-gre) · [11](#11-site-id--parallel-deploy-races) | GRE, site id |
| L1 Windows (KVM) | [2](#2-hyper-v-role-installs-but-vmms-does-not-exist) · [3](#3-partial-nested-config-vmx-yes-enlightenments-still-on) · [15](#15-virt-install---features-hypervoff-fails-on-al2023) · [16](#16-do-not-install-hyper-v-in-autounattend-before-kvm-xml-fix) · [17](#17-sapphire-rapids-8488c-needs-cascadelake-kvm-cpu-for-nested-hyper-v) · [14](#14-windows-guest-stuck-on-apipa-169254x-after-hyper-v-hypervisor-enable) | vmms, CPU, autounattend, APIPA |
| L2 Hyper-V inner | [1](#1-l2-proof-green-but-inner-vm-is-not-on-hyper-v) · [4](#4-external-hyper-v-vswitch-broke-windows-guest-networking) · [12](#12-l2-winrm-timeout-on-vhdx-download) · [13](#13-winrm-command-line-too-long) · [18](#18-hyper-v-inner-ubuntu-lostcommunication--no-20-ping) · [19](#19-set-vmprocessor--exposevirtualizationextensions) | Real L2 path, WinRM, inner boot |
| DHCP / reprovision | [20](#20-windows-reinstall-wipes-dnsmasq-inner-reservations) | Inner `.20` reservation |
| Operations | [22](#22-false-green-after-stack-redeploy-stale-ssm) | Stale SSM after redeploy |
| Retired paths | [5](#5-deprecated-metal-inner-deploy-path) · [21](#21-inner-ubuntu-boot-order--cloud-init-failures-retired-metal-inner-path) | Old libvirt-inner experiments |

---

## 1. L2 proof green but inner VM is not on Hyper-V

**Symptom:** `./bin/invoke-routing-proof.sh --layer l2` passes; inner Ubuntu at `.20` is pingable cross-site.

**Trap:** The inner VM may be a **libvirt guest** on `br-default`, not a child of Hyper-V. `virsh list` on the metal host shows both `win-hv-nested` and `ubuntu-inner`.

**How to tell:**

```bash
virsh list --all                    # ubuntu-inner here = not Hyper-V L2
# From Windows guest (WinRM):
Get-VM ubuntu-inner                 # should exist here for real L2
sc.exe query vmms                   # must be RUNNING
```

**Fix:** Remove libvirt `ubuntu-inner`, fix nested Hyper-V (`vmms`), provision via `deploy-inner-ubuntu-on-host.sh` (WinRM → Hyper-V).

**Lesson:** Same lab IP + GRE routing can mask a missing hypervisor layer. Proofs must match the stack you claim.

---

## 2. Hyper-V role installs but `vmms` does not exist

**Symptom:** `Get-WindowsFeature Hyper-V` → `Installed = True`. `sc.exe query vmms` → error 1060 (service does not exist).

**Cause:** Windows is a KVM guest and still detects a parent hypervisor. The Hyper-V **management** feature installs; the **hypervisor kernel component** (`vmms`) does not.

**Fix (KVM side - required first):**

| Setting | Purpose |
|---------|---------|
| Host `kvm_intel.nested=1` | Allow nesting on metal |
| `--cpu host-passthrough,require=vmx` | Pass VT-x into Windows guest |
| `--features kvm_hidden=on,hyperv=off` | Hide KVM from guest; don't paravirt Windows as Hyper-V guest |
| XML: `<kvm><hidden state='on'/></kvm>` | Same as kvm_hidden for defined domains |
| XML: remove `<hyperv mode='custom'>` enlightenments | Stops QEMU Hyper-V paravirt confusing nested HV |
| XML: `<timer name='hypervclock' present='no'/>` | Drop hyperv clock when stripping enlightenments |

Script: `scripts/fix-kvm-nested-hyperv-xml.sh` then **reboot Windows guest**.

**Fix (Windows side - after KVM XML + reboot):**

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

## 5. Deprecated metal-inner deploy path

**Symptom:** Docs or forks reference provisioning inner Ubuntu directly on metal libvirt.

**Fix:** Default path is `deploy-inner-ubuntu-on-host.sh` → Hyper-V. See hiccup #1 if `virsh list` still shows `ubuntu-inner`.

---

## 6. Bootstrap fails on fresh metal (NVMe device order)

**Symptom:** Site 0 bootstrap completes; site 1 stuck at `PHASE=REGION` or `PHASE=DISK mount failed`. No `BOOTSTRAP finished` in launch-timing log.

**Cause:** Assumed `/dev/nvme1n1` is always the 2TB data volume. On some instances **`nvme1n1` is root (200G)** and **`nvme0n1` is data**. `mount` on root partition fails under `set -e`.

**Fix:** `bootstrap.sh` `init_vm_disk` - skip devices with `/` mountpoint; select first block device **≥500GB**; tolerate already-mounted image dir.

---

## 7. System dnsmasq listens on :53

**Symptom:** Security scan flags recursive DNS on the metal host. Metal hosts may be stopped by automated remediation.

**Cause:** `apt-get install dnsmasq` enables **`dnsmasq.service`** listening on **:53** with recursion on the primary ENI. Lab config uses **`port=0`** (DHCP-only on `br-default`) but the system service must be **masked**.

**Fix:** `scripts/ensure-lab-dnsmasq.sh` - `systemctl mask dnsmasq`; lab instance binds **`br-default` only**, **`port=0`**, **`no-resolv`**. Deployed via `deploy-hyperv-guest.sh`.

**Verify:**

```bash
systemctl is-enabled dnsmasq    # masked
ss -ulnp | grep ':53'           # no public :53
grep '^port=0' /etc/nested-virt-dnsmasq.conf
```

See [SECURITY-EXCEPTIONS.md](SECURITY-EXCEPTIONS.md).

---

## 8. Guest HTTPS works but inner cannot curl

**Symptom:** Metal and cross-site L2 ping OK; Windows guest ping to `1.1.1.1` OK; `Invoke-WebRequest https://…` fails; inner `curl` fails.

**Cause:** Lab dnsmasq is `port=0` (no DNS on `10.{site}.1.1`). Windows `vEthernet (NestedVirt-Lab)` uses **static IP** (no DHCP option 6). Inner netplan pointed nameservers at the metal gateway.

**Fix:** `ensure-lab-guest-dns.ps1` (Windows → `1.1.1.1`/`1.0.0.1`), inner netplan/seed → public DNS in `prepare-ubuntu-inner-image.sh`, `./bin/invoke-routing-proof.sh --layer internet`. Existing inners without SSH password: `./bin/refresh-inner-internet.sh` (re-pull VHDX with baked netplan).

---

## 9. VNC bound to 0.0.0.0

**Symptom:** Security scan flags VNC/RFB on `0.0.0.0:5900`.

**Cause:** `virt-install --graphics vnc,listen=0.0.0.0,port=5900` in `provision-windows-guest.sh`.

**Fix:** `listen=127.0.0.1`; `scripts/ensure-lab-vnc.sh` patches existing domains; verified in `go.sh` lab security step.

**VNC access:** `ssh -L 5900:127.0.0.1:5900 -i ~/.ssh/KEY.pem ubuntu@<metal-public-ip>` then connect VNC client to `localhost:5900`.

See [SECURITY-EXCEPTIONS.md](SECURITY-EXCEPTIONS.md).

---

## 10. Cross-site lab routing (GRE)

**Symptom:** Cross-site ping to `10.x.1.x` fails; transport ENI ping works.

**Cause:** Raw `10.x` lab space doesn't ride VPC fabric. Needs GRE tunnel between transport ENIs with `src=10.{site}.1.1` on routes.

**Fix:** `scripts/setup-gre-tunnel.sh` + `apply-peer-routes.sh`.

---

## 11. Site ID / parallel deploy races

**Symptom:** Site 1 inner VM got `10.0.1.20` instead of `10.1.1.20`; apt/dpkg lock errors when Windows + inner deploy ran together.

**Fix:** Always pass explicit site id to `deploy-real-l2.sh` / `deploy-inner-ubuntu-on-host.sh`. Serialize heavy deploys per host or use `flock` on apt.

---

## 12. L2 WinRM timeout on VHDX download

**Symptom:** `deploy-real-l2.sh` reaches step 6; log shows `winrm provision guest=10.x.1.10` then `ReadTimeout` after 7200s. Hyper-V / `vmms` are fine.

**Cause:** One WinRM `run_ps` invoked `Invoke-WebRequest` for the full **~2.1GB** VHDX inside the guest. WS-Man read timeout kills the session even though HTTP transfer would eventually finish.

**Fix:** `deploy-inner-ubuntu-on-host.sh` - stage PS1 via short WinRM; start **background `curl.exe`** on the Windows guest; poll with 60s WinRM probes; provision with `-SkipDownload`. Use **`flock`** on the metal host so overlapping deploys do not delete each other's VM/disk.

Related: hiccup #13 (WinRM payload size).

---

## 13. WinRM "command line too long"

**Symptom:** Provisioning inner VM via WinRM fails on huge inline PowerShell.

**Fix:** Serve `provision-ubuntu-inner-vm.ps1` over HTTP from metal gateway (`python3 -m http.server` on `10.{site}.1.1`), download inside guest, execute locally. Inline PowerShell via WinRM (`run_ps` with script body + injected `$SiteId`). Never `& '/tmp/foo.ps1'` from the guest - that path is on the metal host.

Related: hiccup #12 (long-running WinRM during VHDX download).

---

## 14. Windows guest stuck on APIPA (169.254.x) after Hyper-V hypervisor enable

**Symptom:** `virsh` shows `win-hv-nested` running; metal host ARP shows `169.254.x.x` for Windows MAC; ping `.10` fails; WinRM dead.

**Cause:** Hyper-V hypervisor install/reboot reset NIC config; guest lost static/DHCP lab address. Hyper-V can also rebind the physical NIC to the virtual switch stack before a vSwitch exists.

**Fix:**

1. Avoid destructive `Uninstall-WindowsFeature Hyper-V` when role already installed - use `Enable-WindowsOptionalFeature` + `bcdedit` first (`enable-hyperv-nested-host.ps1` v2).
2. Script restores lab IP **before** scheduling reboot (`Restore-LabIp`).
3. Register **startup scheduled task before** `Install-WindowsFeature Hyper-V` in autounattend (order 3 task, order 4 Hyper-V) - otherwise Hyper-V reboot skips task creation.
4. Recovery on metal: restart dnsmasq, `virsh destroy && virsh start win-hv-nested`, wait for startup task (up to 10 min).
5. If still APIPA: `FORCE_REINSTALL=1 ./bin/deploy-hyperv-guest.sh`.

---

## 15. `virt-install --features hyperv=off` fails on AL2023

**Symptom:** `ERROR Unknown --features options: ['hyperv']` - Windows guest never reinstalls.

**Fix:** Use `--features kvm_hidden=on` only; strip `<hyperv>` enlightenments after define with `fix-kvm-nested-hyperv-xml.sh`.

---

## 16. Do not install Hyper-V in autounattend before KVM XML fix

**Symptom:** Fresh Windows pingable at `.10`; after `fix-kvm-nested-hyperv-xml.sh` destroy/start → APIPA; `vmms` never appears.

**Cause:** Hyper-V role installed during OOBE rebinds NICs. Rebooting the guest before nested KVM enlightenments are stripped leaves Windows without lab IP and without a working hypervisor stack.

**Fix:** Autounattend registers the startup task but **defers** Hyper-V install to `enable-hyperv-nested-host.ps1`.

---

## 17. Sapphire Rapids (8488C) needs Cascadelake KVM CPU for nested Hyper-V

**Symptom:** Windows guest boots to desktop, but enabling Hyper-V (`hypervisorlaunchtype auto`) causes boot loop / Automatic Repair. `vmms` never stays RUNNING.

**Cause:** Host CPU is Intel Xeon Platinum **8488C** (Sapphire Rapids). KVM `Skylake-Server-noTSX-IBRS` is a poor match; nested Hyper-V fails during hypervisor bring-up.

**Fix:** Use `Cascadelake-Server-noTSX` with `vmx` required, `hypervisor` disabled, `kvm_hidden=on` (`fix-kvm-nested-hyperv-xml.sh`, `provision-windows-guest.sh`). Experiment with `experiment-nested-hyperv-cpu.sh` before full deploy.

---

## 18. Hyper-V inner Ubuntu: LostCommunication / no `.20` ping

**Symptom:** `Get-VM ubuntu-inner` → Running, but `Get-VMNetworkAdapter` shows **LostCommunication**; Hyper-V integration **Heartbeat: No Contact**; metal ARP for `.20` stays INCOMPLETE.

**Cause (often combined):**

1. **DVD-first boot order** - Gen2 firmware tries to boot the nocloud seed ISO; guest never reaches a running kernel. Seed ISO must stay attached but **not** be in `-BootOrder` (boot **disk only**).
2. **Stale VHDX on force reinstall** - removing the VM but reusing `ubuntu-inner-disk.vhdx` skips cloud-init first boot; reapplying seed alone does not reconfigure the disk.
3. **Ubuntu 26.04 cloud image** - on nested Hyper-V Gen2 this stack saw persistent boot failure; **24.04 LTS** booted reliably.
4. **`ExposeVirtualizationExtensions $true`** on a plain Linux guest - not needed for L2; set **`$false`** (hiccup #19).

**Fix:**

1. `prepare-ubuntu-inner-image.sh`: **`virt-customize`** inject static netplan by MAC into the served VHDX before first boot; default **`UBUNTU_RELEASE=24.04`**.
2. `provision-ubuntu-inner-vm.ps1`: boot **disk only**; `-ForceReinstall` deletes VM **and** disk/seed artifacts before re-download.
3. Run `./scripts/fix-inner-hyperv-network.sh {site}` (force redeploy wrapper) - upload scripts to S3 with **explicit** `aws s3 cp` per file (SSM for-loops with `\$f` get 403).
4. Stuck inner VM artifacts: on metal, `./scripts/debug/diag-hyperv-inner.sh cleanup {site}` then redeploy.

**Verify:** `Get-VMNetworkAdapter` Status → **Ok**; `ping 10.{site}.1.20` from metal; `./bin/invoke-routing-proof.sh --layer l2`.

---

## 19. `Set-VMProcessor -ExposeVirtualizationExtensions`

**When needed:** Inner Ubuntu must run its **own** hypervisor (L3). Set `$true` only then.

**L2 (this lab):** Use **`$false`**. `$true` contributed to boot/NIC issues on nested Hyper-V Gen2 with Ubuntu 24.04.

**Fix location:** `provision-ubuntu-inner-vm.ps1`

---

## 20. Windows reinstall wipes dnsmasq inner reservations

**Symptom:** Inner VM boots but never gets `.20`; `grep 52:54:00:20 /etc/nested-virt-dnsmasq.conf` empty after Windows reprovision.

**Cause:** `setup_lab_dhcp()` in `provision-windows-guest.sh` overwrote dnsmasq config with Windows MAC only.

**Fix:** Always write **both** Windows (`.10`) and inner (`.20`) MAC reservations in `setup_lab_dhcp()` and `write_lab_dnsmasq()`.

---

## 21. Inner Ubuntu boot order / cloud-init failures (retired metal-inner path)

**Symptom:** Metal-side `ubuntu-inner` libvirt domain hung at boot; no `.20` IP.

**Note:** The default L2 path is Hyper-V inner (`deploy-real-l2.sh`). This entry documents the retired metal-inner approach.

**Fixes that worked before Hyper-V L2:**

- `--boot hd,menu=off` (no seed CDROM boot)
- `virt-customize` inject static netplan by MAC before first boot
- Independent disk (`qemu-img convert`) not stale backing overlay

---

## 22. False GREEN after stack redeploy (stale SSM)

**Symptom:** `./bin/monitor-lab-until-green.sh` exits immediately with GREEN, or raw `aws ssm get-parameter` shows GREEN while the new metal hosts are still bootstrapping. JSON lists **old** `instance_id` values from a torn-down stack.

**Cause:** SSM `/nested-virt/lab/verification` is **not** deleted when CloudFormation deletes `nested-virt-lab`.

**Fix:** Use `./bin/check-lab-status.sh` - it rejects GREEN when instance IDs do not match the live stack (exit 2). After teardown, run `./bin/teardown-lab.sh` (deletes stack **and** lab SSM) or `./bin/clean-lab-ssm.sh` alone. See [DEPLOY-FROM-CFN.md](DEPLOY-FROM-CFN.md#full-green-proof-run).

---

## Proof checklist (real L2)

| Check | Command / expected |
|-------|-------------------|
| Metal has Windows only (no metal inner) | `virsh list` → `win-hv-nested` only |
| Hyper-V host alive | `sc.exe query vmms` → RUNNING |
| Inner on Hyper-V | WinRM: `Get-VM ubuntu-inner` → Running |
| Inner IP | `ping 10.{site}.1.20` from metal |
| Cross-site | `./bin/invoke-routing-proof.sh --layer l2` |

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
| `bin/deploy-inner-ubuntu.sh` | Both sites, Hyper-V path |
| `scripts/debug/diag-hyperv-inner.sh` | L2 debug: `quick`, `full`, or `cleanup` |

---

*Add new entries when something bites you - keep symptom, cause, and fix together.*
