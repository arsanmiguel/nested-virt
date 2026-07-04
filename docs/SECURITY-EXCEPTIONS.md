# Security exceptions — nested-virt lab

Documented, intentional exceptions for the nested-virtualization workshop lab.  
These are **not** oversights and **must not** be “hardened away” without an explicit lab design change.

---

## CSE finding: Recursive DNS exposed (Epoxy trigger)

**Finding:** *Recursive DNS Server Exposed to Internet* (Critical, 2026-07-02)

**Cause:** `apt-get install dnsmasq` on the metal host enables **`dnsmasq.service`** on **UDP/TCP 53** with upstream recursion. Combined with lab SG ingress, CSE sees an open recursive resolver. The **lab** dnsmasq instance was already **`port=0`** (DHCP-only on `br-default`) but the **system service was not disabled**.

**Fix (in repo):** `scripts/ensure-lab-dnsmasq.sh` — masks `dnsmasq.service`, runs lab dnsmasq with `port=0`, `bind-interfaces`, `interface=br-default` only, `no-resolv`, `except-interface=kvm-host-nic*`.

**Verify on host:**

```bash
ss -ulnp | grep ':53'          # should be empty (or systemd-resolved on 127.0.0.53 only)
systemctl is-enabled dnsmasq   # masked/disabled
ps aux | grep nested-virt-dnsmasq
grep port= /etc/nested-virt-dnsmasq.conf   # port=0
```

Re-run guest provision or `./bin/go.sh --fresh` after pulling this fix.

---

Re-run guest provision or `./bin/go.sh --fresh` after pulling this fix.

---

## Public IP on metal hosts (primary ENI only)

**Design:** Only **device 0** (primary ENI in the workshop subnet) gets a public address. Transport ENIs (`kvm-host-nic1/2`) live on **private /28** subnets (`MapPublicIpOnLaunch=false`) — they never have public IPs.

**Why IPs “disappeared” after Epoxy stop/start:**

1. The template used **ephemeral** public IPs (`AssociatePublicIpAddress: true`) — AWS **releases** those on `StopInstances` and may not re-assign the same address on start (especially on multi-ENI metal).
2. **Epoxy `EC2InstanceIsolate`** stops hosts mid-run → ephemeral public IP gone.
3. A failed in-place recovery left Site 1 **running with `PublicIp: null`** while transport ENIs still had private IPs — looked like “lost public IP” but was really **lost ephemeral association on primary ENI** plus broken bootstrap networking after stop.

**Fix (in CFN):** `AWS::EC2::EIP` + `EIPAssociation` on the instance (`MetalPublicEip` in `template-src.yaml`) — stable public IP that **survives stop/start**. Stack output `PublicIp` for SSH/VNC tunnel. Management remains **SSM-first**; public IP is break-glass only.

---

## CSE finding: VNC exposed to internet (Epoxy trigger)

**Finding:** VNC / RFB listener on `0.0.0.0:5900` (Critical)

**Cause:** `virt-install --graphics vnc,listen=0.0.0.0` binds the Windows guest console to all interfaces on the metal host. With lab SG ingress, CSE sees open VNC.

**Fix (in repo):** `scripts/ensure-lab-vnc.sh` — libvirt VNC on **`127.0.0.1:5900` only**; access via SSH tunnel (`ssh -L 5900:127.0.0.1:5900 …`). New guests use `listen=127.0.0.1` in `provision-windows-guest.sh`. Verified in `./bin/go.sh` via `verify-no-public-vnc.sh`.

**Verify on host:**

```bash
ss -tlnp | grep 5900    # 127.0.0.1:5900 only, not 0.0.0.0
virsh dumpxml win-hv-nested | grep graphics
```

---

## Primary metal host SG — ingress `0.0.0.0/0`

**Location:** `cloudformation/template-src.yaml` → `InstanceSecurityGroup` → ingress rule:

```yaml
- IpProtocol: -1
  CidrIp: 0.0.0.0/0
  Description: Lab inbound (nested-virt proof and guest traffic)
```

**Status:** Approved lab exception (workshop / POC scope).

**Why it exists:**

- Nested proof traffic (KVM → Hyper-V → inner Ubuntu) includes paths that do not always present as **`10.0.0.0/8`** on the primary ENI security group from AWS’s perspective (guest NAT, bridge forwarding, cross-layer probes, WinRM/ICMP during bring-up).
- The lab is **time-bounded**, **non-production**, and torn down via `./bin/teardown-stacks.sh`.
- Management is intended via **SSM**; the wide ingress rule supports **documented routing proofs** and workshop debugging without per-session SG churn.

**Other rules on the same SG (defense in depth, not a substitute for the exception above):**

- SSH (TCP 22) limited to `AdminCidr`
- ICMP from `VpcCidr`
- All protocols from `10.0.0.0/8` (lab supernets)

**Transport ENIs** (`ExtraHostNicSecurityGroup`) remain restricted to VPC CIDR + `10.0.0.0/8` only — no `0.0.0.0/0`.

**Operational note:** Automated mitigations (e.g. Epoxy `EC2InstanceIsolate`) that fire on this rule should be **exempted for `Project=nested-virt`** — see `docs/EPOXY-CSE-EXEMPTION-REQUEST.md`. Do not remediate by removing this rule as part of pipeline or agent “cleanup.”

---

## Egress `0.0.0.0/0` on primary SG

Required for bootstrap (S3, SSM, package repos, Windows ISO / VHDX pulls). Standard for isolated lab hosts with no prod data.

---

## Instance type `c7i.metal-48xl`

Required for nested KVM/Hyper-V on metal. Cost and capacity exception for workshop duration only.
