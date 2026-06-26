# Nested Virtualization on AWS

## Production-Grade Nested Hypervisors, Cross-AZ Networking, and Failure-Domain Validation

> **Modernization is a business strategy. Continuity is an operational requirement.**
>
> Sometimes those timelines don't match.

---

# Why this exists

*The long version: [why.md](why.md).*

Every architecture conference (yes, even this one) tells you to modernize.

Most of the time, that's exactly the right answer.

**Operative phrase: most of the time.**

Sometimes the datacenter lease expires in 90 days...except Brad in Ops misread the email and it's actually 19.

Sometimes your company gets acquired and corporate's message is simple:

> **"Move it."**

Sometimes HR doesn't care how elegant your future architecture is.

They care that payroll runs Monday morning.

Sometimes you inherit a twenty-year-old monolith with no source code, undocumented dependencies, and a business that cannot tolerate downtime.

Every company has a Tony.

Tony has been there for thirty years.

Tony knows why that one cron job exists.

Tony knows the emergency workaround from 2003 that somehow became "the process."

Then Tony retires.

Tony's documentation fits on half a napkin; his retirement plan is to come back as a consultant.

Tony offers you one piece of advice as he walks out: "Just rewrite it. :) "

Congratulations, you're Tony now.

This repository exists because every organization eventually has to answer the same two questions:

> **Do we keep depending on Tony...or do we build ourselves a bridge?**
>
> **How do we buy ourselves enough time to do this *****right*****?**

It represents thousands of hours spent designing, migrating, validating, and troubleshooting enterprise virtualization platforms over the last 26 years.

None of it was hypothetical.

Most of it hurt.

---

# What this is

This is **not** another nested virtualization proof of concept.

This is a production-grade laboratory demonstrating that a legacy virtualization estate can be lifted into AWS, preserved intact, validated end-to-end, and intentionally broken to prove every failure domain independently.

Nested virtualization isn't the destination.

It's the bridge.

It buys you time.

Time to understand.

Time to document.

Time to stabilize.

Time to modernize correctly instead of desperately.

Because if the business doesn't survive the migration...

...there won't be anything left to modernize.

---

# What you're actually looking at

The lab spans two Availability Zones using EC2 bare metal and intentionally layers multiple virtualization technologies together.

[![End-to-end nested-virt topology — two AZs, KVM, Hyper-V, Ubuntu, GRE overlay](docs/diagrams/end-to-end.png?v=be1aa5f)](docs/diagrams/end-to-end.svg)

*Click the diagram to open the full-size vector SVG. Mermaid + packet-level detail in [docs/network-diagram.md](docs/network-diagram.md).*

Every layer can be independently validated.

Every layer can be independently broken.

Every layer has proof.

Proof that it works.

Proof when it doesn't.

Proof why.

---

# Why nested virtualization?

Because reality isn't greenfield.

Anyone who's spent enough time in infrastructure knows these are all true.

* There are workloads that cannot be refactored before the business deadline.
* There are operating systems that cannot simply be containerized.
* There are applications whose vendors no longer exist.
* There are environments where "modernize first" is a luxury.

Nested virtualization provides an operational escape hatch.

Move first.

Stabilize.

Then modernize on **your** timeline - not the building owner's.

---

# The real goal

The virtualization stack isn't the interesting part.

**Failure isolation is.**

Production outages rarely happen because one thing broke.

They happen because five independent layers all insist the other four are wrong.

Hypervisor.

Guest.

Bridge.

Routing.

Overlay.

Storage.

Probably DNS.

Somewhere between Layer 0 and Layer 2...

...reality diverges from your mental model.

This repository exists to prove exactly where.

Not guess. 

**Prove.**

---

# What this repository teaches

This isn't a deployment guide.

It's an operational guide.

You'll learn how to:

* Build a production-grade nested virtualization environment across Availability Zones.
* Validate every infrastructure layer independently.
* Introduce controlled failures throughout the stack.
* Prove root cause using repeatable diagnostics instead of assumptions.
* Separate infrastructure failures from guest failures.
* Understand where nested virtualization helps - and where it absolutely does not.

---

# Scars Earned

Everything documented here was learned the expensive way.

In 26 years of doing this professionally, I've advised countless customers on whether nested virtualization belonged anywhere near production.

Most got nervous the moment we reached the networking discussion.

Honestly?

That was probably the right instinct.

One tiny mistake later...

* Hyper-V refuses to cooperate.
* GRE overlays flap or disappear.
* Bridge forwarding silently dies.
* MTU mismatches create packet loss that looks like everything except MTU.
* Cloud-init helpfully rewrites your network configuration.
* False-positive health checks send you chasing ghosts.
* Someone's IaC or change management software eradicates your infrastructure
* Nested virtualization exposes edge cases I hadn't seen in 26 years—and Reddit, Stack Overflow, or your favorite AI assistant probably won't save you.

I've spent thousands of hours proving assumptions wrong, validating configurations like this, and hunting the real fault instead of the obvious one.

Every proof script in this repository exists because production eventually demanded it.

Usually around **2:18 AM on a Sunday.**

---

# Who this is for

This repository is for my people.

Infrastructure engineers.

Platform teams.

Cloud architects.

Consultants.

Technical Account Managers.

Field CTOs.

Anyone responsible for impossible migrations with impossible deadlines.

**The people who don't have the luxury of pretending every workload starts cloud-native.**

---

# Who this is not for

If you're looking for a quick nested virtualization tutorial...

There are better repositories.

Because here be dragons. Nasty ones.

If you're looking for a production-grade migration laboratory that proves—not assumes—every layer of a complex virtualization stack...

Welcome home, the dragon is awake. 

We'll start by proving Layer 0 isn't lying.

---

> *Automation doesn't eliminate complexity.*
>
> *It amplifies your understanding of it—or your misunderstanding of it.*
>
> **Production doesn't care which one it is.**

