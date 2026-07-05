# Deploy from CloudFormation only (CFN and go)

Lab operators **do not clone this repository**, run scripts on a laptop, or publish anything to S3 beforehand. They deploy from **one template file**:

`cloudformation/nested-virt-lab.yaml`

That file is self-contained: it creates the bootstrap bucket, seeds all runtime scripts via a custom resource, and launches both metal sites as nested stacks.

## What the operator does

1. Open **CloudFormation** in the AWS Console (or use CLI with `--template-url` if the file is already in S3).
2. **Create stack** → **Upload a template file** → choose `nested-virt-lab.yaml`.
3. Set parameters (EC2 key pair, VPC, four subnets, optional instance type).
4. Acknowledge **CAPABILITY_NAMED_IAM** (nested stacks create IAM roles).
5. Wait for `CREATE_COMPLETE`, then monitor progress on the metal hosts via SSM Session Manager.

**No repo checkout. No `bin/go.sh`. No `publish-release.sh`. No `config.env`.**

### Console example

Parameters you must supply:

| Parameter | Meaning |
|-----------|---------|
| `KeyName` | EC2 SSH key pair in the account/region |
| `VpcId` | Lab VPC |
| `Site0SubnetId` | Metal host subnet, AZ-a |
| `Site1SubnetId` | Metal host subnet, AZ-b |
| `Site0TransportSubnetId` | Transport /28, AZ-a |
| `Site1TransportSubnetId` | Transport /28, AZ-b |

Optional: `VpcCidr`, `AdminCidr`, `InstanceType` (default `c7i.metal-48xl`), `AssociatePublicIp`.

### CLI note

The generated template is ~75 KB. Console upload allows up to 1 MB. The CloudFormation API `--template-body` limit is 51 KB, so **CLI deploy from a local file requires uploading the template to S3 first** and using `--template-url`. Console upload is the intended “drop in and go” path.

```bash
# After CREATE_COMPLETE — watch site 0 bootstrap
aws ssm start-session --target "$(aws cloudformation describe-stacks \
  --stack-name nested-virt-lab \
  --query "Stacks[0].Outputs[?OutputKey=='Site0InstanceId'].OutputValue" --output text)"
# tail -f /var/log/amazon/launch-timing.log
```

## What happens inside the stack

```
nested-virt-lab.yaml (operator uploads once)
  ├── LabBootstrapBucket          (new bucket per stack)
  ├── ScriptSeed (Lambda)         (extracts embedded script bundle into bucket)
  ├── Site0Stack ──► site.yaml from bucket (metal host AZ-a)
  └── Site1Stack ──► site.yaml from bucket (metal host AZ-b)

Each metal host:
  UserData stub → S3 bootstrap.sh → phased bootstrap
                → nested-virt-lab-pipeline.service → lab-site-pipeline.sh
                → guests, L2, internet proofs (all scripts from stack bucket)
```

The stack tags each instance with `BootstrapBucket` so bootstrap and pipeline resolve the correct bucket (not a hardcoded account name).

## Automatic gates (on instances)

| Phase | Script | What |
|-------|--------|------|
| Bootstrap | `bootstrap.sh` | DISK → FEATURES → NIC → KVM → PEER → VALIDATE |
| Coordinate | site 0: `coordinate-peer-routing-on-host.sh` | Peer tags, GRE, `sites.env` |
| Pipeline | `lab-site-pipeline.sh` | CSE → Windows guest → L2 → internet → proofs |
| Proofs | `routing-proof-on-host.sh`, `internet-proof-on-host.sh` | L0–L2 + curl |

## Maintainer: regenerating the drop-in template

When `bootstrap.sh`, `scripts/*`, or `cloudformation/template-src.yaml` change, rebuild the artifact from a repo checkout (CI or maintainer only — not lab operators):

```bash
python3 cloudformation/build-drop-in-template.py
# writes cloudformation/nested-virt-lab.yaml
```

Commit the updated `nested-virt-lab.yaml` so operators always get a current drop-in file.

## Developer tools (optional)

`bin/go.sh`, `publish-release.sh`, and per-site `deploy-stack.sh` remain for developers working in the repo. Lab operators should use this document only.

## Teardown

```bash
aws cloudformation delete-stack --stack-name nested-virt-lab
aws cloudformation wait stack-delete-complete --stack-name nested-virt-lab
```

The bootstrap bucket is deleted with the stack (`DeletionPolicy: Delete`).
