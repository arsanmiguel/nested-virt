# Nested-virt iteration log

Running record of fixes, infra events, and redeploy attempts.

## Iteration 2026-07-04 — full `./bin/go.sh --fresh` validated ALL GREEN

**Goal:** Real top-to-bottom test after post-CSE script fixes (not resume on old stacks).

**Stacks:** `nested-virt-s0-01` (`i-0279c2260aba26e6b`), `nested-virt-s1-01` (`i-0ea12071c2ba97f0d`)

| Phase | Status | Notes |
|-------|--------|-------|
| Teardown | done | Prior s0-02/s1-01 removed |
| Deploy both | done | New CFN stacks, EIP on primary ENI |
| Bootstrap | done | Site 1 needed NVMe disk-selection fix mid-run |
| Peer routing | done | GRE + `sites.env` |
| CSE hardening | done | DNS masked, VNC localhost |
| L0 / L1-local | done | |
| Windows guests | done | virtio wget fallback + cache |
| L1 cross/guest | done | |
| L2 Hyper-V inner | done | Async VHDX transfer; L2 up ~5 min |
| `--layer all` | **GREEN** | 2026-07-04 ~04:54 UTC |

**Script changes this iteration:** `bootstrap.sh` (data disk detection + mount tolerance), `deploy-inner-ubuntu-on-host.sh` (async VHDX), `ensure-lab-dnsmasq.sh` (DHCP DNS), `ensure-lab-image-cache.sh`, `provision-windows-guest.sh`, `provision-ubuntu-inner-vm.ps1`, `bin/wait-deps.sh` (L2 wait 120).

---

## Running fixes (branch `fix/fresh-deploy-blockers`)

| Fix | File(s) | Why |
|-----|---------|-----|
| **Single pipeline** | `bin/go.sh`, `bin/wait-deps.sh` | One entry: `--fresh`, idempotent `run`, inline CSE verify |
| **CSE DNS** | `scripts/ensure-lab-dnsmasq.sh` | Mask system dnsmasq; lab `port=0`; DHCP DNS → public resolvers |
| **CSE VNC** | `scripts/ensure-lab-vnc.sh` | `listen=127.0.0.1` |
| **Stable EIP** | `cloudformation/template-src.yaml` | EIP on `PrimaryHostNic` |
| **ISO cache** | `scripts/ensure-lab-image-cache.sh`, `bootstrap.sh` | S3 + data EBS cache; virtio wget fallback |
| **L2 VHDX** | `scripts/deploy-inner-ubuntu-on-host.sh` | Short WinRM + background curl; flock |
| **Data disk** | `bootstrap.sh` | NVMe order: pick ≥500GB non-root device |
| **Guest virtio** | `scripts/provision-windows-guest.sh` | Subshell cache fetch; install-phase validation |

See also `README.md` → *Lessons learned (post–CSE hardening)* and `docs/nested-virt-hiccups.md`.
