# Roadmap

## Next: Terraform port (target: tomorrow)

The current lab is **CloudFormation + bash + SSM + S3 bootstrap**. It works and is documented in [BUILD.md](BUILD.md). The next milestone is to express the same topology in **Terraform** without changing the proof model.

### Goals

| Area | Current | Terraform target |
|------|---------|------------------|
| Compute | CFN `deploy-stack.sh` | `aws_instance` metal × 2, AZ spread |
| Networking | CFN ENIs, SGs, `/28` transport subnets | `aws_network_interface`, routes, SG modules |
| Bootstrap | Userdata → `bootstrap.sh` | Same scripts via `templatefile` / S3 object refs |
| Peer routing | `bin/configure-peer-routing.sh` | `null_resource` + SSM or TF-managed routes after both instances exist |
| State | `.last-stack-site*.env`, `sites.env` | TF outputs → `sites.tfvars` or SSM parameters |
| Proofs | `invoke-routing-proof.sh` | Unchanged — consumes instance IDs from TF output |

### Suggested module layout

```
terraform/
  modules/
    metal-site/          # one AZ: instance, ENIs, SG, userdata
    peer-routing/        # tags + GRE route application (SSM)
  environments/
    nested-virt/         # two sites, wires modules together
  outputs.tf             # SITE_*_INSTANCE_ID, transport IPs
```

### Non-goals for v1 TF port

- Replacing WinRM / Hyper-V provisioning (stay script-driven day-2)
- Replacing GRE with VPC-native `10.x` routing (still need overlay)
- Multi-region (stay single-region, two AZs)

### Migration notes

- Keep **`invoke-routing-proof.sh`** as the acceptance test — TF apply is done when `--layer all` passes.
- Preserve **`PHASE=`** timing log contract on hosts.
- S3 bootstrap bucket can become a TF `aws_s3_bucket` + `aws_s3_object` for scripts.
- Document hiccups remain valid; TF only changes *how metal appears*, not guest nesting rules.

### Checklist

- [ ] TF module: metal site (c7i.metal-48xl, AL2023, ENIs)
- [ ] TF: transport `/28` subnet discovery (tag prefix `win-metal-hv-nic`)
- [ ] TF outputs compatible with `sites.env`
- [ ] SSM association or `null_resource` for peer GRE after both sites
- [ ] README section: `terraform apply` path alongside CFN
- [ ] Deprecate or wrap `bin/run-both-sites.sh` as thin TF wrapper

---

## Later

- **Chaos monkey** scenarios wired to [reinvent-pitch.md](reinvent-pitch.md)
- **macOS metal + microVMs** — [future-macos-metal.md](future-macos-metal.md)
- Inner-to-inner proof (ping from inside Ubuntu guest, not just metal host)
- L3 (hypervisor inside inner Ubuntu) — only if needed; not required for current proofs
