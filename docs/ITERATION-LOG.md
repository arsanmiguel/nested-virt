# Nested-virt iteration log

Running record of fixes, infra events, and redeploy attempts.

## Inner credentials (generated per VHDX build)

L2 inner SSH password is generated in `prepare-ubuntu-inner-image.sh` (same pattern as `win-guest-admin-password`):
`openssl rand` → `${STATE_DIR}/inner-ubuntu-ssh-password` (mode 600), injected via cloud-config + `virt-customize --password`.
Consumers: `ensure-inner-guest-dns.sh`, `internet-proof-on-host.sh`, `bin/go.sh`. Override with `INNER_SSH_PASS` for tests only.
After changing this, run `REFRESH_INNER_VHDX=1` / `refresh-inner-internet.sh` so Windows pulls a VHDX that matches the password file on metal.

---

## Iteration 2026-07-05 — fresh redeploy + inner internet still red

**Goal:** `./bin/go.sh --fresh` again; get `--layer internet` green; stop hardcoding inner credentials.

**Stacks (current):** `nested-virt-s0-01` (`i-0ec915771f6886c9c`, transport `172.31.96.6`), `nested-virt-s1-01` (`i-0177e5ba2334c5a50`, transport `172.31.96.23`). Prior stacks torn down.

| Phase | Status | Notes |
|-------|--------|-------|
| Teardown + deploy | done | ~50 min total |
| Bootstrap | done | |
| L0 / L1 / L2 routing | done | L2 `.20` ping ~5 min/site (not 2 hours) |
| `--layer all` (routing) | done | |
| `--layer internet` / inner curl | **FAIL** | SSH `Permission denied` on both sites |

### What was wrong → what we fixed → why

| Symptom / mistake | Root cause | Fix | File(s) |
|-------------------|------------|-----|---------|
| “L2 takes 2 hours” | Broken **refresh loop** reusing stale Windows VHDX; SSM 7200s timeout; Isengard cred expiry looked like `Pending`; `go.sh` auto-refresh when `sshpass` missing on metal | Removed auto-refresh trap; `refresh-inner-internet.sh` polling + 10800s timeout; `bootstrap.sh` installs `sshpass`; VHDX sha256 stamp + `FORCE_VHDX_PULL` | `bin/go.sh`, `bin/refresh-inner-internet.sh`, `bootstrap.sh`, `deploy-inner-ubuntu-on-host.sh`, `prepare-ubuntu-inner-image.sh` |
| Stale inner VHDX on Windows | `SkipDownload` + 0.95 size check kept old disk; metal `virt-customize` never applied to running VM | Stamp compare; invalidate Windows copy on force; `ForceReinstall` keeps staged VHDX when `-SkipDownload` | `deploy-inner-ubuntu-on-host.sh`, `provision-ubuntu-inner-vm.ps1`, `ensure-inner-guest-dns.sh` |
| Inner SSH `Permission denied` | Hardcoded `ubuntu`/`ubuntu`; cloud image disables password auth; password not reliably baked | Generated creds per VHDX build; `virt-customize --password` (not `chpasswd` — PAM fails offline); cloud-config `plain_text_passwd` + seed ISO | `prepare-ubuntu-inner-image.sh`, consumers below |
| Hardcoded inner password | Same pattern Windows already had (`win-guest-admin-password`) but missing for L2 | `openssl rand` → `${STATE_DIR}/inner-ubuntu-ssh-password` (600); all SSH callers read file | `prepare-ubuntu-inner-image.sh`, `ensure-inner-guest-dns.sh`, `internet-proof-on-host.sh`, `bin/go.sh`, `deploy-inner-ubuntu-on-host.sh` |
| Refresh failed immediately “missing password file” | `ensure-inner-guest-dns.sh` called `load_inner_pass` **before** prepare/deploy generated the file | If `REFRESH_INNER_VHDX=1` and no file → full VHDX refresh first | `ensure-inner-guest-dns.sh` |
| Refresh deploy OK but SSH still wrong | **Double prepare:** refresh ran `prepare` then `deploy` ran `prepare` again → password file overwritten; SSH check used **stale** pass from first prepare | Refresh only calls `deploy`; `load_inner_pass` **after** deploy; retry inner curl 12×10s | `ensure-inner-guest-dns.sh` |
| SSM inner test exit 252 | Shell loop `set -- $pair` passed whole string as one instance ID | Use `IFS=: read` with colon-separated fields | (ops / test scripts) |
| `virt-customize chpasswd` failed | `pam_chauthtok(): Authentication token manipulation error` on Ubuntu cloud base offline | Use `virt-customize --password ubuntu:password:…` instead | `prepare-ubuntu-inner-image.sh` |

**Still open:** Run `refresh-inner-internet.sh --wait` per site after upload; confirm inner `curl checkip` with generated pass; then `./bin/invoke-routing-proof.sh --layer internet` and `--layer all`. Commit consolidation on branch `fix/fresh-deploy-blockers` when green.

**Refresh attempt 2026-07-05 ~03:21–03:32 UTC** (`refresh-inner-internet.sh --wait` site 0 → site 1, all latest script fixes uploaded):

| Site | Deploy / Hyper-V | Ping `.20` | SSH + curl |
|------|------------------|------------|------------|
| 0 | OK (VM recreated) | OK | FAIL `Permission denied` |
| 1 | OK (`INNER_UBUNTU_OK`) | OK | FAIL (same) |

Password file present on metal (16-char generated, mode 600). Blocker was **Ubuntu 24.04 cloud image has no `ubuntu` user until cloud-init runs** — offline `virt-customize --password` was a no-op. **Fix (2026-07-05):** bake `ubuntu` user + `chpasswd -e` hash + ed25519 `authorized_keys` offline; disable cloud-init (`/etc/cloud/cloud-init.disabled`); `-SkipSeed` on Hyper-V provision; SSH key auth for all proof scripts; deploy waits for SSH not ping.

**Cross-refs:** `README.md` → *Lessons learned*; `docs/nested-virt-hiccups.md` (#6b, #6c inner SSH/DNS).

---

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
| **Inner credentials** | `prepare-ubuntu-inner-image.sh`, `ensure-inner-guest-dns.sh`, `internet-proof-on-host.sh`, `bin/go.sh` | Generated `${STATE_DIR}/inner-ubuntu-ssh-password`; no hardcoded `ubuntu`/`ubuntu` |
| **Refresh password sync** | `ensure-inner-guest-dns.sh` | Single prepare via deploy only; load pass after deploy; retry inner curl |
| **virt-customize password** | `prepare-ubuntu-inner-image.sh` | Bake `ubuntu` user + `chpasswd -e`; no user in base cloud image |
| **Inner SSH key auth** | `prepare-ubuntu-inner-image.sh`, proof scripts | ed25519 key → `authorized_keys`; primary auth path on metal |
| **Skip nocloud seed** | `provision-ubuntu-inner-vm.ps1`, `deploy-inner-ubuntu-on-host.sh` | `-SkipSeed` when credentials baked offline; disable cloud-init |

See also `README.md` → *Lessons learned (post–CSE hardening)* and `docs/nested-virt-hiccups.md`.
