# Security - nested-virt lab

Intentional security and network choices for the workshop lab.  
These are **by design** - do not remove or tighten them without an explicit architecture change.

**Related:** [README](../README.md) · [Deploy guide](DEPLOY-FROM-CFN.md) · [Troubleshooting](nested-virt-hiccups.md)

---

## CSE / security scan handoff

**What this is:** A time-bounded **workshop lab** (nested virt on bare metal). It is not a production landing zone. Findings that match the sections below are expected and documented.

**Templates in scope (scan both):**

| File | Role |
|------|------|
| [`cloudformation/nested-virt-lab.yaml`](../cloudformation/nested-virt-lab.yaml) | **Operator drop-in** - the file end users upload to CloudFormation |
| [`cloudformation/template-src.yaml`](../cloudformation/template-src.yaml) | Per-site source template (developer path; embedded in drop-in) |

**Run automated scans (Docker required; Colima on macOS):**

```bash
colima start   # if needed
./scripts/security-scan.sh
```

Reports default to `/tmp/nested-virt-security-scan/` (`latest-trivy-*.txt`, `latest-checkov-*.txt`, `latest-gitleaks.txt`, optional `latest-cfn-lint.txt`, `latest-shellcheck.txt`).

**Before filing findings, read:**

- This document (intentional SG, DNS, VNC, egress choices)
- [`.trivyignore`](../.trivyignore) - suppressed Trivy IDs with rationale in comments

**Optional manual checks:**

```bash
pip install cfn-lint   # or brew install cfn-lint
cfn-lint cloudformation/template-src.yaml cloudformation/nested-virt-lab.yaml

brew install shellcheck
shellcheck -x bin/*.sh scripts/*.sh bootstrap.sh
```

**Operational note:** Deploy only in a dedicated sandbox account/VPC. Tear down when done: `./bin/teardown-lab.sh` (deletes stack, empties bootstrap bucket, clears SSM verification parameters).

**Verification evidence:** End-to-end deploy from `nested-virt-lab.yaml` only (no laptop pipeline) reaches SSM `/nested-virt/lab/verification` with `"status": "GREEN"`. See [DEPLOY-FROM-CFN.md](DEPLOY-FROM-CFN.md).

---

## Lab DNS - DHCP only, no resolver on the metal host

**Design:** Metal hosts run lab dnsmasq on `br-default` with **`port=0`** (DHCP only). The system **`dnsmasq.service`** from `apt install dnsmasq` is **masked** so nothing listens on UDP/TCP 53 on the primary ENI.

**Implementation:** `scripts/ensure-lab-dnsmasq.sh` - `port=0`, `bind-interfaces`, `interface=br-default` only, `no-resolv`, `except-interface=kvm-host-nic*`.

**Guest DNS:** DHCP option 6 points at public resolvers (`1.1.1.1`, `1.0.0.1`). Windows guests on the static Hyper-V vSwitch get the same via `ensure-lab-guest-dns.ps1`.

**Verify on host:**

```bash
ss -ulnp | grep ':53'          # empty (or systemd-resolved on 127.0.0.53 only)
systemctl is-enabled dnsmasq   # masked/disabled
grep '^port=0' /etc/nested-virt-dnsmasq.conf
```

---

## VNC - localhost only

**Design:** libvirt guest console on **`127.0.0.1:5900`** only. Access via SSH tunnel.

**Implementation:** `scripts/ensure-lab-vnc.sh`; new guests use `listen=127.0.0.1` in `provision-windows-guest.sh`.

**Verify on host:**

```bash
ss -tlnp | grep 5900    # 127.0.0.1:5900 only, not 0.0.0.0
virsh dumpxml win-hv-nested | grep graphics
```

**Access:** `ssh -L 5900:127.0.0.1:5900 -i KEY.pem ubuntu@<metal-public-ip>` → VNC client to `localhost:5900`.

---

## Public IP on metal hosts (primary ENI)

**Design:** Only **device 0** (primary ENI) gets a stable public address via **`AWS::EC2::EIP`**. Transport ENIs (`kvm-host-nic1/2`) are on private `/28` subnets - no public IPs.

Management is **SSM-first**; public IP is break-glass SSH/VNC tunnel only.

---

## Primary metal host SG - ingress `0.0.0.0/0`

**Location:** `cloudformation/template-src.yaml` → `InstanceSecurityGroup`:

```yaml
- IpProtocol: -1
  CidrIp: 0.0.0.0/0
  Description: Lab inbound (nested-virt proof and guest traffic)
```

**Why:** Nested proof traffic (KVM → Hyper-V → inner Ubuntu) includes paths that do not always present as **`10.0.0.0/8`** on the primary ENI from AWS’s perspective (guest NAT, bridge forwarding, cross-layer probes, WinRM/ICMP during bring-up). The lab is **time-bounded**, **non-production**, and torn down after use.

**Other rules on the same SG:**

- SSH (TCP 22) limited to `AdminCidr`
- ICMP from `VpcCidr`
- All protocols from `10.0.0.0/8` (lab supernets)

**Transport ENIs** (`ExtraHostNicSecurityGroup`) remain restricted to VPC CIDR + `10.0.0.0/8` only.

---

## Egress `0.0.0.0/0` on primary SG

Required for bootstrap (S3, SSM, package repos, Windows ISO / VHDX pulls).

---

## Hardening (not lab exceptions)

The drop-in root stack (`lab-drop-in-main.yaml`) enables **S3 versioning, access logging, and KMS (CMK)**, **SNS KMS encryption**, and **Lambda X-Ray tracing** with a DLQ and concurrency limit on the one-shot seed function. Site stacks encrypt bootstrap timing log groups with the AWS managed CloudWatch Logs key (`alias/aws/logs`).

CSE scans should still flag **primary SG ingress `0.0.0.0/0`** and related lab networking (see `.trivyignore`). Other findings should be reviewed against this doc before filing.

---

## Instance type `c7i.metal-48xl`

Required for nested KVM/Hyper-V on metal. Workshop-duration capacity choice only.
