# Cost post-mortem: what this lab actually costs

**Audience:** Lab operators, finance-curious engineers, anyone wondering why nested virt on bare metal is not a "$5 afternoon."

**Account reference:** `442056872435`, `us-east-1`, Jun-Jul 2026 experiment window. Numbers from **AWS Cost Explorer** (`BoxUsage:c7i.metal-48xl`, EBS, Directory Service) cross-checked against **CFN stack history**, **local deploy logs**, and **EBS volume create timestamps**.

**Related:** [Deploy guide](DEPLOY-FROM-CFN.md) · [Troubleshooting](nested-virt-hiccups.md) · [Developer build log](BUILD.md) · [Why this exists](../why.md)

---

## TL;DR

| Expectation | Reality |
|-------------|---------|
| One clean CFN deploy → ALL GREEN | **~$150-250** compute + disks for **one** end-to-end run (~2× metal for ~1 hour CFN + ~1 hour pipeline, plus EBS during bootstrap) |
| "Fix it  until it works" lab simulation | **~$2,000+** over Jun 24 - Jul 13 from **dozens of redeploys**, metal left up overnight, failed teardowns, and **23 orphaned 2TB volumes** |
| Windows metal timing benchmark (same account, same SKU) | **~$1,700** additional (Jun 4-23) - separate experiment, same billing line item |

**The lab works.** The bill is mostly **trial-and-error tax**, not the happy-path architecture.

---

## Unit economics (us-east-1, on-demand, 2026)

| Resource | Unit price (approx) | Per deploy / per day | Notes |
|----------|---------------------|----------------------|-------|
| **`c7i.metal-48xl`** | **~$4.09/hr** | **~$98/day** per host | Two sites = **~$196/day** if both run 24×7 |
| **EBS gp3** (metal layout) | ~$0.08/GB-mo + IOPS | **~$50-120/run** while attached | Root + data + Windows VHDX staging; **orphan volumes keep billing after stack delete** |
| **AWS Directory Service** (Microsoft AD) | ~$80/mo (2 DCs) | **~$2.60/day** | Used for Windows domain-join experiments; not required for CFN-only nested-virt path |
| **S3 bootstrap buckets** | pennies | negligible | `nested-virt-bootstrap-*` / stack seed bucket - keep them |
| **CloudFormation / SSM** | free tier | negligible | Verification params survive teardown if you skip cleanup ([hiccup #22](nested-virt-hiccups.md#22-false-green-after-stack-redeploy-stale-ssm)) |

**One honest GREEN run (2× metal, ~2 hr CFN + ~1 hr pipeline, teardown same day):** budget **$200-350** all-in if you actually tear down.

**Leave 2× metal up over a weekend:** **~$400-600** before you touch a keyboard again.

---

## What we spun up (inventory vs bill)

| Infrastructure | Count (peak) | Role in lab | Cost driver |
|----------------|--------------|-------------|-------------|
| `c7i.metal-48xl` (site 0 + site 1) | 2 per stack | KVM host, GRE transport, pipeline runner | **#1** - hourly while `running` |
| Transport ENIs + `/28` subnets | 2 per site | Cross-AZ GRE outer header | Pennies (EC2-Other) |
| EBS on metal (200GB-5TB layout) | 6+ disks × 2 hosts | Windows VHDX, data, inner VM seeds | **#2** - size × hours; **orphans after bad delete** |
| `nested-virt-lab` CFN stack | 15+ create/delete cycles | Drop-in operator path | Each cycle = new disks + 2× metal hours |
| Per-site stacks (`nested-virt-s0-*`, `s1-*`) | 20+ (dev era) | Pre-CFN developer path | Same SKU, more partial failures |
| SSM `/nested-virt/lab/verification` | 1 (stale risk) | GREEN proof | Free; **false confidence** if instance IDs drift |
| Directory `arstestdirectory.com` | 1 | Windows domain join (metal launch repos) | ~$118 over experiment window |
| Orphan **2TB gp3 volumes** | **23** (Jul 2-14) | Failed/partial teardown | **~$40-120/day** tail after metal was gone |

**Billing source of truth:** `897` **`BoxUsage:c7i.metal-48xl` instance-hours** = **~$3,119** Jun 1 - Jul 14 (includes Windows metal benchmark in the same usage type).

---

## Spend vs activity (trial and error)

Daily infra spend (EC2 compute + EBS + Directory) mapped to what we were doing:

| Window | ~Daily burn | What was happening |
|--------|-------------|-------------------|
| Jun 4-16 | $70-280 | **Windows metal** bootstrap tuning (`win-c7i-metal-fs-*`), failed deploys, **metal left running** between fixes |
| Jun 11-12 | spikes | **20-run timing benchmark** - deploy/bootstrap/delete loop (~90 min × 20) |
| Jun 24-30 | **~$130/day** | **Nested-virt born** - per-site stacks, routing proofs, first Hyper-V pain |
| Jul 1-3 | **$92 → $196/day** | Multi-site redeploys, GRE/routing races, **parallel experiments** |
| Jul 4-8 | **~$140-160/day** | Drop-in CFN template, **ALL GREEN proof runs**, CSE hardening regressions, teardown/redeploy loops |
| Jul 9 | **~$120/day** | Last GREEN validation; stack still up part of day |
| Jul 10-13 | **~$43/day** | **Metal gone** - only **orphan 2TB EBS** still billing |
| Jul 14 | cleanup | Deleted 23 orphan volumes + Directory Service |

**Pattern:** Spend tracks **hours × hosts**, not "number of successful GREENs." A failed bootstrap that runs 2 hours then gets abandoned costs almost as much as a success.

---

## Trial-and-error multipliers (what we learned the hard way)

1. **Two metal hosts always.** Nested-virt is a **two-AZ lab**. Every "quick test" is 2× `c7i.metal-48xl`. There is no cheap single-site mode on this SKU.

2. **Redeploy ≠ free.** CloudFormation delete does not guarantee every EBS volume dies. We accumulated **23× 2048GB `available` volumes** - classic **"stack gone, disks forgotten"** leak.

3. **Stale GREEN lies.** SSM verification params **survive stack teardown**. We burned cycles trusting GREEN from a **previous** instance ID set ([hiccup #22](nested-virt-hiccups.md#22-false-green-after-stack-redeploy-stale-ssm)). Fix: `./bin/check-lab-status.sh` or JSON `instance_id` match against live stack outputs.

4. **False layer success.** Routing proof can pass while L2 is wrong (libvirt shortcut vs real Hyper-V inner). Same IPs, wrong stack - hours of debug ([hiccup #1](nested-virt-hiccups.md#1-l2-proof-green-but-inner-vm-is-not-on-hyper-v)).

5. **Expired creds ≠ torn down.** At least once, **expired AWS credentials** made teardown scripts report "stack not found" while **2× metal kept billing**. Always verify in console or CLI after teardown.

6. **Directory Service is a silent line item.** Windows metal join experiments kept **Microsoft AD** alive for weeks (~$80/mo). Not needed for the drop-in nested-virt CFN path if you skip domain join.

7. **Document or pay again.** Every undocumented fix became a **re-learn tax** on the next redeploy. The [hiccups index](nested-virt-hiccups.md#quick-index-by-phase) exists because we paid for each entry in the table above.

---

## Where the logs live (start here when shit is weird)

Use this order: **billing symptom → time window → log source → hiccup entry**.

| Symptom | First checks | Deep dive |
|---------|--------------|-----------|
| "Stack says GREEN but behavior is wrong" | `aws ssm get-parameter --name /nested-virt/lab/verification` - compare `instance_id` to stack outputs | [Hiccup #22](nested-virt-hiccups.md#22-false-green-after-stack-redeploy-stale-ssm), `./bin/check-lab-status.sh` |
| "Cross-site ping fails" | On metal: `/var/log/amazon/launch-timing.log`, `invoke-routing-proof.sh --layer l0/l1` | [Hiccups #10-11](nested-virt-hiccups.md#10-cross-site-lab-routing-gre) |
| "Windows up but no Hyper-V / vmms" | `virsh dumpxml win-hv-nested`, guest `sc.exe query vmms` | [Hiccups #2-3, #15-17](nested-virt-hiccups.md#2-hyper-v-role-installs-but-vmms-does-not-exist) |
| "Inner .20 pingable but not on Hyper-V" | `virsh list --all` vs `Get-VM` on Windows | [Hiccup #1](nested-virt-hiccups.md#1-l2-proof-green-but-inner-vm-is-not-on-hyper-v) |
| "Bootstrap stuck / phase never completes" | SSM → `launch-timing.log`, phase file under `/var/lib/nested-virt/` | [BUILD.md](BUILD.md), [Hiccup #6](nested-virt-hiccups.md#6-bootstrap-fails-on-fresh-metal-nvme-device-order) |
| "Bill spiked overnight" | Cost Explorer daily → `BoxUsage:c7i.metal-48xl`; EC2 → `available` EBS volumes | This doc, [DEPLOY teardown](DEPLOY-FROM-CFN.md#teardown) |

**Operator artifacts (cloned repo):**

```bash
./bin/check-lab-status.sh          # rejects stale SSM GREEN
./bin/monitor-lab-until-green.sh   # poll until verified
./bin/teardown-lab.sh              # stack + bootstrap bucket + SSM cleanup
tail -f /tmp/nested-virt-go-fresh.log   # developer pipeline (if using go.sh)
```

**On each metal host:** `/var/log/amazon/launch-timing.log` (`PHASE=*` lines) is the canonical bootstrap/pipeline timeline.

---

## Cost guardrails for lab takers

1. **Teardown is part of the lab.** `./bin/teardown-lab.sh` (or delete `nested-virt-lab` stack + empty seed bucket + run `./bin/clean-lab-ssm.sh`). Do not "leave it up for tomorrow."

2. **Verify delete, don't assume it.** After teardown:
   ```bash
   ./bin/teardown-lab.sh   # stack + SSM + orphan sweep (EBS, ENI, /nested-virt/ logs)
   ```
   Or manually: no `c7i.metal-48xl` running, no `available` volumes tagged `Project=nested-virt`.

3. **One deploy, one debug session.** If bootstrap fails, **delete the stack** before trying a different fix unless you are actively on the box via SSM.

4. **Budget one GREEN, not one commit.** A single successful end-to-end run is **~$200-350**. Planning "10 iterations" = **$2k+** - that is normal for this SKU, not a billing bug.

5. **Read before redeploying.** [nested-virt-hiccups.md](nested-virt-hiccups.md) is the FAQ we paid for. Symptom match → fix → avoid another full metal cycle.

---

## What worked (worth the money)

| Outcome | Evidence | Doc |
|---------|----------|-----|
| Drop-in **`nested-virt-lab.yaml`** - no laptop pipeline | Multiple CFN-only runs → ALL GREEN in ~42 min wall clock | [DEPLOY-FROM-CFN.md](DEPLOY-FROM-CFN.md) |
| Layered routing proofs (L0/L1/L2) | Caught GRE vs libvirt shortcut bugs | [network-diagram.md](network-diagram.md) |
| SSM GREEN with instance ID guard | Stops false "done" after redeploy | [Hiccup #22](nested-virt-hiccups.md#22-false-green-after-stack-redeploy-stale-ssm) |
| Sapphire Rapids → `cascadelake` KVM CPU for nested Hyper-V | vmms actually starts | [Hiccup #17](nested-virt-hiccups.md#17-sapphire-rapids-8488c-needs-cascadelake-kvm-cpu-for-nested-hyper-v) |
| Teardown script empties bootstrap bucket | Fixes `DELETE_FAILED` stacks | [DEPLOY-FROM-CFN.md](DEPLOY-FROM-CFN.md#teardown) |

---

## What did not work (and what it cost)

| Failure mode | Symptom | Typical waste | Write-up |
|--------------|---------|---------------|----------|
| Metal-inner Ubuntu shortcut | L2 "green" without Hyper-V | Days of false progress | [Hiccup #1](nested-virt-hiccups.md#1-l2-proof-green-but-inner-vm-is-not-on-hyper-v), [#5](nested-virt-hiccups.md#5-deprecated-metal-inner-deploy-path) |
| Hyper-V in autounattend before KVM fix | APIPA / dead vmms | 1-2 metal cycles per attempt | [Hiccups #14-16](nested-virt-hiccups.md#14-windows-guest-stuck-on-apipa-169254x-after-hyper-v-hypervisor-enable) |
| Stale SSM after redeploy | "GREEN" but new stack broken | Hours of monitoring nothing | [Hiccup #22](nested-virt-hiccups.md#22-false-green-after-stack-redeploy-stale-ssm) |
| Partial stack delete | CFN gone, 2TB volumes remain | **~$40-120/day** per wave | Template now uses `DeleteOnTermination: true`; `./bin/sweep-lab-orphans.sh` mops tagged orphans |
| CSE hardening without regression deploy | Assumptions broke pipeline | Full 2× metal redeploy loops | [BUILD.md](BUILD.md) iteration notes |
| Windows metal benchmark (parallel) | 20× `c7i.metal-48xl` in 36 hr | **~$1,700** (Jun) | `aws-metal-windows-launch/timing-benchmark-tfc20.log` |

---

## Reproduce these numbers yourself

```bash
# Metal spend + hours
aws ce get-cost-and-usage \
  --time-period Start=2026-06-01,End=2026-07-15 \
  --granularity MONTHLY \
  --metrics UnblendedCost UsageQuantity \
  --filter '{"And":[{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}},{"Dimensions":{"Key":"USAGE_TYPE","Values":["BoxUsage:c7i.metal-48xl"]}}]}'

# Daily burn (EC2 + EBS + Directory)
aws ce get-cost-and-usage \
  --time-period Start=2026-06-01,End=2026-07-15 \
  --granularity DAILY \
  --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute","EC2 - Other","Amazon Elastic Block Store","AWS Directory Service"]}}'
```

Console: **Billing → Cost Explorer → Group by Service / Usage type → Daily**.

---

## Bottom line for curious parties

Nested virt on **`c7i.metal-48xl`** is a **capacity lab**, not a Lambda. The architecture is defensible; the **~$2,200 nested-virt experiment bill** is mostly:

- **897 metal instance-hours** of trying, breaking, fixing, and reproving
- **Trial-and-error redeploys** at 2× metal per attempt
- **Storage leaks** when teardown was incomplete
- **Parallel Windows metal work** in the same account if you're looking at **~$3,800+** total Jun-Jul

Treat **teardown + volume audit + SSM cleanup** as lab steps 7-9. Treat **[nested-virt-hiccups.md](nested-virt-hiccups.md)** as the FAQ you read **before** clicking Create Stack again. That is the cheapest fix we have.
