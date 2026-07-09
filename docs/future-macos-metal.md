# Future: macOS metal + microVMs

Not in scope for the Linux POC - captured so we do not forget the crackpot sequel.

## EC2 Mac (mac1.metal / future SKUs)

Same repo pattern as `aws-metal-linux-launch`: bare metal substrate, no Nitro guest nesting fight. Hypothesis:

- **Host:** macOS on EC2 Mac metal
- **Layer 1:** Apple's Virtualization.framework or QEMU (Apple Silicon virt)
- **Layer 2:** Linux KVM guest inside QEMU, or Linux microVM (Firecracker-style) where the stack allows
- **Dev angle:** reproducible microVM lab in the cloud that feels local - fast boot, snapshot, throwaway envs

## Why devs might care

| Idea | Hook |
|------|------|
| microVM on metal | Sub-second-ish boot dev boxes, CI runners, security sandboxes |
| Cross-platform nested stack | Same routing proof matrix, different hypervisor (KVM vs Apple virt) |
| re:Invent part 2 | "We did Hyper-V in KVM on Linux metal. Then we did it on a Mac." |

## Open questions (when we pick this up)

- Nested virt flags on Apple Silicon EC2 Mac - what is actually exposed?
- Licensing / Apple EULA constraints for automated macOS guests
- Whether **microVM** (Firecracker, Cloud Hypervisor) or **full VM** is the right dev UX on Mac
- Shared repo layout: `nested-virt/` stays Linux-first; `nested-virt-macos/` fork or `--platform darwin` in bootstrap

## Related Apple-local tooling (not AWS)

Developer Macs already run Lima, Colima, Docker Desktop VMs - the interesting delta is **metal in AWS** with **provable routing** and **nested hypervisor stacks**, not another local Docker wrapper.

---

*Add notes here when the Linux POC is green.*
