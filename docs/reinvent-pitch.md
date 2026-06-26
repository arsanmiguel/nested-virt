# re:Invent pitch: nested-virt

Working name: **nested-virt**. The crackpot layer on top of bare metal launch repos.

## What this POC proves

Nested virtualization on AWS is not a thought experiment. You can run it, prove it, and hand someone else the lab so they can too.

1. **KVM on metal works.** On `c7i.metal-48xl` you get a real hypervisor: nested virt enabled, `/dev/kvm`, bridges, guests. Regular EC2 is the wrong substrate.

2. **Hyper-V inside that stack works.** Not just "KVM boots a VM." The target is KVM host, Windows Server guest, Hyper-V role enabled, inner VM running. That is the nested part people argue about.

3. **Cross-site lab networking is provable.** Two AZs, each with its own lab space (`10.0.*` / `10.1.*`), linked over dedicated transport ENIs. Routing is checked in layers, not assumed:
   - **L0:** transport ENI to transport ENI across AZs
   - **L1:** lab bridge gateways and site lab space
   - **L2:** inner Hyper-V guest to guest (stretch goal for the session)

4. **It is repeatable.** Repo, deploy scripts, bootstrap phases, routing proofs, teardown. Someone else can stand it up, run the checks, and get the same result.

**One line:** Nested virt on AWS metal is doable. Here is the lab that proves it, and you can run it yourself.

---

## Session title options

Pick one tone:

| Title | Vibe |
|-------|------|
| **Break the Nested Virt Lab: Fix Bare Metal, KVM, and Hyper-V Under Fire** | Interactive / chaos |
| **Nested Virt on AWS Metal: We Built It, Then We Broke It on Purpose** | Candor |
| **Chaos Engineering for Nested Virtualization on EC2 Bare Metal** | re:Invent-friendly keyword |
| **Can You Fix a Three-Layer Nested Virt Stack Before I Break Something Else?** | Unhinged (recommended) |

Recommended: **Can You Fix a Three-Layer Nested Virt Stack Before I Break Something Else?**

---

## Abstract (submission, ~400 chars)

Bare metal nested virt works on AWS. Proving it once is boring. This session starts with a fully built two-AZ lab (KVM, Windows/Hyper-V, cross-site routing proofs), then breaks it on purpose with scripted chaos: dropped routes, wrong ENI bindings, guest network failures, peer discovery gone sideways. You diagnose layer by layer (L0 transport, L1 lab, L2 nested guests) and bring it back green. Leave with the lab pattern and the break/fix scripts.

---

## Long description (proposal body)

### The problem

People assume nested virtualization on AWS either does not work or is not worth trying. On standard Nitro instances you are already a guest; exposing VT-x/AMD-V through to your workload is blocked or flaky. Bare metal changes the physics: you own the box.

Building the lab once proves feasibility. **Operating it when something breaks** is what separates a demo from something you would actually run.

### What we built

**nested-virt** is a POC repo that:

- Deploys two `c7i.metal-48xl` hosts (site 0 in AZ-a, site 1 in AZ-b)
- Enables nested KVM on the Linux host
- Mirrors the bridge lab layout from existing Hyper-V metal launch work
- Wires cross-AZ transport routing on dedicated ENIs (`kvm-host-nic1`)
- Provisions Windows Server guests with Hyper-V
- Runs explicit routing proofs: L0 transport, L1 lab gateways, L2 inner guests (target)

Borrowed from `aws-metal-linux-launch` and `aws-metal-windows-launch`: metal launch, extra ENIs, timing logs, S3 bootstrap. New for this experiment: site-aware addressing (`10.{SiteId}.*`), peer route discovery, and `invoke-routing-proof.sh`.

**Session twist:** none of this gets built live. It is already up. The session is about **breaking it and fixing it**.

### The format: built, then broken

1. **Green state.** Show the lab healthy. Run `./bin/invoke-routing-proof.sh`. Everything passes. Nested stack is real. Two minutes, not twenty.

2. **Chaos monkey.** Run `./invoke-chaos-monkey.sh` (or pick a scenario). Script injects realistic failures across the routing layers and guest stack.

3. **Fix it.** Audience (volunteers, table groups, or you talking through while they shout) works the problem using the same proof scripts as diagnostics. Layer by layer until green again.

4. **Repeat.** Break something worse. Or break two things at once. See if they learned the model.

This is not "watch me deploy CloudFormation." It is "here is a nested virt stack that works, here is what failure looks like at each layer, now figure out which layer is lying to you."

### Chaos scenarios (scripted, reproducible)

Each scenario should map to a routing layer and have a known fix path:

| Scenario | What breaks | Symptom | Fix skill |
|----------|-------------|---------|-----------|
| **Stale policy route** | `fix-transport-routing.sh` inverse: wrong `ip rule` on `kvm-host-nic1` | L0 fails one direction | Read `ip rule`, match DHCP IP to policy table |
| **Peer route deleted** | Drop `10.1.0.0/16 via peer` (or reverse) | L1 local ok, cross-site dead | Re-run `bin/configure-peer-routing.sh` or manual route |
| **Transport ENI DHCP loss** | Flush `kvm-host-nic1` address | Peer discovery fails, L0 dead | `netplan apply`, dhclient, re-apply peer tags |
| **Bridge uplink wrong** | `br-cluster` off wrong NIC (or down) | Lab gateway weirdness | `ip link`, bridge port audit |
| **Guest stopped / wrong IP** | `virsh destroy`, or static IP typo in autounattend | L1-local ping fails | libvirt state, `br-default` ARP |
| **Inner Hyper-V VM off** | Stop nested guest inside Windows | L2 fail, L0/L1 still green | Teaches layer isolation |
| **Double fault** | Route gone AND guest down | Multiple proof failures | Triage: fix L0 before L2 |

Scenarios should log what they broke (`/var/log/nested-virt-chaos.log`) so you can rewind or score.

### Why this session

- **Operators** who debug nested/migration stacks under pressure, not just deploy them once
- **Architects** who need to understand which layer owns which failure mode
- **Anyone bored** by another "here is my architecture diagram" talk

### Demo narrative (45 min)

| Segment | Time | What happens |
|---------|------|--------------|
| Context | 3 min | Why metal, why nested, why two AZs. Quick. |
| Green proof | 5 min | Lab already built. `invoke-routing-proof.sh` all layers. Show stack diagram once. |
| Chaos round 1 | 5 min | Run chaos script. Proofs fail. Audience sees the error output. |
| Fix round 1 | 12 min | Walk through diagnosis: which layer? which script? bring it back green. |
| Chaos round 2 | 5 min | Harder scenario or double fault. |
| Fix round 2 | 10 min | Less hand-holding. They propose the fix. |
| Wrap | 5 min | Repo, chaos scripts, teardown, cost reality |

No live deploy. No waiting on Windows install. No praying CloudFormation finishes before your slot ends.

### Key takeaways

1. Bare metal is the right AWS substrate for nested virt.
2. Failures have layers. L0 transport, L1 lab routing, and L2 nested guests fail independently. Prove each layer separately.
3. If you cannot break it on purpose, you cannot trust it in prod.
4. Automate proof scripts first, chaos scripts second. Same tooling for green and red.

### Honest limits (say these on stage)

- L1 cross-site over raw `10.x` lab space does not ride the VPC fabric alone; GRE/IPIP between transport ENIs or accept L0-only cross-site until wired.
- Two `c7i.metal-48xl` instances are expensive. Lab is pre-built; teardown is still part of the story.
- Chaos scripts need dry runs. You will break your own lab ten times before the session.

---

## Elevator pitch (30 seconds)

"I built a two-site nested virt lab on AWS bare metal: KVM, Hyper-V, cross-AZ routing, scripted proofs at every layer. For re:Invent I do not deploy it live. I break it on purpose with chaos scripts and make you fix it. Nested virt works on metal. Knowing which layer broke when it stops working is the actual skill."

---

## Speaker notes / hook

Open: **"Everything you are about to see is already running. I am not here to deploy. I am here to break things."**

Run green proofs. Pause. **"Good. Now watch this."** Run chaos monkey.

Close: **"Take the repo. Run the proofs. Run the chaos. Fix it before finance notices the metal bill."**

---

## Assets to prepare

- [ ] Architecture diagram (two AZs, three routing layers, where chaos hits)
- [ ] **`invoke-chaos-monkey.sh`** with named scenarios + restore/rewind
- [ ] **`invoke-routing-proof.sh`** as the diagnostic (already exists; extend for L2)
- [ ] Scenario card deck (optional): audience picks "route death" vs "guest death" vs "double fault"
- [ ] Leaderboard / timer (optional): time-to-green per scenario
- [ ] Pre-session dry run checklist: lab green, chaos rewinds clean, SSM paths work
- [ ] Cost slide: metal SKU, lab left up for session week, `./bin/teardown-stacks.sh`

### Repo work before pitch (not built yet)

```
invoke-chaos-monkey.sh --scenario stale-policy-route
invoke-chaos-monkey.sh --scenario drop-peer-route
invoke-chaos-monkey.sh --scenario flush-transport-nic
invoke-chaos-monkey.sh --scenario stop-guest
invoke-chaos-monkey.sh --scenario double-fault
invoke-chaos-monkey.sh --restore          # rewind to last green snapshot
```

---

## Related docs

- [hyperv-guest.md](hyperv-guest.md) - Windows/Hyper-V guest automation
- [future-macos-metal.md](future-macos-metal.md) - sequel idea (macOS metal + microVMs)
