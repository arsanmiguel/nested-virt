# Epoxy / CSE exemption request — nested-virt workshop lab

**Account:** `442056872435`  
**Region:** `us-east-1`  
**Project:** `nested-virt`  
**Requestor:** _(your name / team)_  
**Date:** 2026-07-02  

---

## Summary

We are running a **controlled nested-virtualization workshop lab** (KVM metal hosts → Windows Hyper-V guests → inner Ubuntu VMs) in account `442056872435`. After a **CSE scan**, **Epoxy `EC2InstanceIsolate` mitigations** repeatedly **stop our metal instances**, which breaks SSM and aborts multi-hour L2 deploys.

We request a **time-bounded exemption** from Epoxy `StopInstances` isolation for resources tagged for this lab.

**Root CSE finding (2026-07-02):** *Recursive DNS Server Exposed to Internet* — caused by system `dnsmasq.service` on port 53 after `apt install dnsmasq`, not the lab DHCP config. **Fixed in repo:** `scripts/ensure-lab-dnsmasq.sh` (masks system dnsmasq; lab uses `port=0` on `br-default` only). See `docs/SECURITY-EXCEPTIONS.md`.

**Security posture:** Lab SG ingress `0.0.0.0/0` remains a **documented exception** (`docs/SECURITY-EXCEPTIONS.md`). Epoxy exemption still required until the DNS fix is deployed and CSE re-scans clean.

---

## Evidence (CloudTrail)

All “User initiated” stops on nested-virt metal instances are **Epoxy automation**, not console users:

| Time (UTC) | Event | Principal | Instance |
|------------|-------|-----------|----------|
| 2026-07-02T16:48:57 | `StopInstances` | `EpoxyAccess+epoxy-mitigations-prod+EC2InstanceIsolate+73de3a16-d` | `i-01efe6e12942d4e88` |
| 2026-07-02T16:53:58 | `StopInstances` | `EpoxyAccess+epoxy-mitigations-prod+EC2InstanceIsolate+ee09723a-d` | `i-094d8355a2831af56` |

Immediately before each stop, Epoxy sets **`disableApiTermination=true`** via `ModifyInstanceAttribute`.

**Verify:**

```bash
aws cloudtrail lookup-events --region us-east-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=StopInstances \
  --start-time $(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ) \
  --max-results 20 \
  --query 'Events[?contains(Username, `Epoxy`)].{Time:EventTime,User:Username,Event:EventName}' \
  --output table
```

---

## Impact

| Symptom | Cause |
|---------|--------|
| Instances show **“User initiated”** stop | Epoxy `StopInstances` API |
| **SSM goes offline** and does not recover after start | Stop mid-run + complex multi-NIC bootstrap |
| **L2 VHDX deploy never completes** | ~45–90 min transfer interrupted by isolate |
| **CFN delete fails** | Epoxy sets `disableApiTermination` |

---

## Scope of exemption

| Resource | Identifier |
|----------|------------|
| CFN stacks | `nested-virt-s0-01`, `nested-virt-s1-01` |
| Instance type | `c7i.metal-48xl` |
| Tag | `Project = nested-virt` |
| Management | SSM Session Manager |
| Documented exceptions | `docs/SECURITY-EXCEPTIONS.md` |

---

## Requested exemption

Exclude **`EC2InstanceIsolate`** (stop + termination lock) for:

```
Account:  442056872435
Region:   us-east-1
Tag:      Project = nested-virt
Duration: [WORKSHOP START] – [WORKSHOP END + 7 days]
```

### Preferred mitigation behavior

1. **Do not** `StopInstances` on tagged lab hosts during the exemption window.
2. **Do not** set `disableApiTermination` on lab hosts.
3. If a finding must fire: **alert only** (ticket with finding ID + instance ID).

### Documented SG exception (no remediation requested)

CSE may flag **`InstanceSecurityGroup` ingress `0.0.0.0/0`**. That rule is a **documented, approved lab exception** — see `docs/SECURITY-EXCEPTIONS.md`. Please **suppress automated isolate** for `Project=nested-virt` rather than require SG removal.

---

## Compensating controls

| Control | Status |
|---------|--------|
| Time-bounded lab | Teardown via `./bin/teardown-stacks.sh` within 7 days of workshop |
| No production data | Lab-only synthetic guests |
| SSM automation | Pipeline via SSM + S3 bootstrap |
| IMDSv2 required | CFN `HttpTokens: required` |
| Encrypted EBS | Root + data volumes |
| Documented exceptions | `docs/SECURITY-EXCEPTIONS.md` |
| Audit | CloudTrail + host launch-timing logs |

---

## Copy-paste ticket / email

**Subject:** Epoxy exemption — nested-virt workshop (442056872435)

> We run a time-bounded nested-virt workshop lab in account **442056872435**, tagged **`Project=nested-virt`**, stacks **`nested-virt-s0-01`** / **`nested-virt-s1-01`**.
>
> CloudTrail shows **Epoxy `EC2InstanceIsolate`** repeatedly **stopping** instances and setting **`disableApiTermination`**, breaking SSM and multi-hour deploys.
>
> **Request:** Exempt **`Project=nested-virt`** from **`EC2InstanceIsolate`** from **[DATE]** to **[DATE]**. Alert-only preferred.
>
> **Note:** Ingress **`0.0.0.0/0`** on the lab SG is a **documented exception** (`docs/SECURITY-EXCEPTIONS.md`), not an open remediation item. Please exempt from automated isolate rather than require SG changes.
>
> Detail: `docs/EPOXY-CSE-EXEMPTION-REQUEST.md`

---

## After approval — operator checklist

1. Confirm exemption active (no Epoxy stop within 30 min of deploy).
2. Add exemption tags to CFN if security specifies key/value.
3. `./bin/go.sh --fresh`
4. Do not stop metal hosts until **ALL GREEN**.
5. `./bin/teardown-stacks.sh` within agreed window.

---

## References

- `docs/SECURITY-EXCEPTIONS.md` — documented SG and lab exceptions
- CloudTrail: `EpoxyAccessRole` / `epoxy-mitigations-prod` / `EC2InstanceIsolate`
- Pipeline: `./bin/go.sh`
- Incident log: `docs/ITERATION-LOG.md`
