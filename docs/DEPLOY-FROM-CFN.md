# Deploy from CloudFormation

**One template file runs the entire lab** - [`cloudformation/nested-virt-lab.yaml`](../cloudformation/nested-virt-lab.yaml)

No repo clone. No laptop scripts. No pre-seeded S3 bucket. The template creates a bootstrap bucket, seeds runtime scripts via Lambda, launches both metal sites, and **starts the full on-instance pipeline automatically** after bootstrap (peer GRE → Windows L1 → Hyper-V L2 → internet proof → SSM GREEN).

Win2022.iso is downloaded over HTTPS during bootstrap (Microsoft evaluation CDN by default).

**Related:** [README](../README.md) · [Developer guide](BUILD.md) (optional clone) · [Troubleshooting](nested-virt-hiccups.md) · [Security design](SECURITY-EXCEPTIONS.md)

---

## What you do vs what runs automatically

| You | The stack / metal hosts |
|-----|-------------------------|
| Upload template + set parameters | Create bucket, seed scripts, launch 2× metal |
| Wait for `CREATE_COMPLETE` | Bootstrap, prefetch ISOs, start `nested-virt-lab-pipeline.service` |
| Poll SSM (or optional SNS email) | Security checks, Windows guest, Hyper-V L2, routing proofs, write `/nested-virt/lab/verification` |

`CREATE_COMPLETE` means **metal is up** - not ALL GREEN yet. Budget **40-90 min** after that for the pipeline (up to **4 h** worst case).

---

## Steps

1. **Download or pull** [`cloudformation/nested-virt-lab.yaml`](../cloudformation/nested-virt-lab.yaml) from this repo.
2. **Deploy**
 - **Console:** CloudFormation → **Create stack** → **Upload a template file** → choose the YAML.
 - **CLI:** Upload the YAML to S3, then `create-stack` with `--template-url` (see [CLI note](#cli-note) below).
3. **Parameters:** EC2 key pair, VPC, four subnets (metal + transport `/28` per AZ). Optional: instance type, `WindowsIsoDownloadUrl`.
4. Acknowledge **`CAPABILITY_NAMED_IAM`** (nested stacks create IAM roles).
5. Wait for **`CREATE_COMPLETE`**, then the on-instance pipeline (~**40-90 min** typical; budget **4 h**).
6. **Verify ALL GREEN** (see [Verify ALL GREEN](#verify-all-green) below).

---

## Parameters

| Parameter | Meaning |
|-----------|---------|
| `KeyName` | EC2 SSH key pair in the account/region |
| `VpcId` | Lab VPC |
| `Site0SubnetId` | Metal host subnet, AZ-a |
| `Site1SubnetId` | Metal host subnet, AZ-b |
| `Site0TransportSubnetId` | Transport /28, AZ-a |
| `Site1TransportSubnetId` | Transport /28, AZ-b |
| `AssociatePublicIp` | Optional public IP on primary ENI (default `true`) |
| `InstanceType` | Default `c7i.metal-48xl` |
| `RootNotifyEmail` | Optional - SNS email when lab reaches ALL GREEN (confirm subscription) |
| `WindowsIsoDownloadUrl` | HTTPS URL for Win2022.iso (default: [Microsoft Server 2022 eval ISO](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022), build 20348, ~5 GB) |

Metal hosts need outbound HTTPS (443) to download the ISO. Override `WindowsIsoDownloadUrl` to use your own mirror if needed.

---

## CLI note

The generated template is ~80 KB. Console upload allows up to 1 MB. The CloudFormation API `--template-body` limit is 51 KB, so **CLI deploy from a local file requires uploading the template to S3 first** and using `--template-url`.

Example:

```bash
aws s3 cp cloudformation/nested-virt-lab.yaml s3://YOUR_BUCKET/nested-virt-lab.yaml

aws cloudformation create-stack \
  --stack-name nested-virt-lab \
  --template-url https://YOUR_BUCKET.s3.YOUR_REGION.amazonaws.com/nested-virt-lab.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=KeyName,ParameterValue=YOUR_KEY \
    ParameterKey=VpcId,ParameterValue=vpc-xxx \
    ParameterKey=Site0SubnetId,ParameterValue=subnet-xxx \
    ParameterKey=Site1SubnetId,ParameterValue=subnet-xxx \
    ParameterKey=Site0TransportSubnetId,ParameterValue=subnet-xxx \
    ParameterKey=Site1TransportSubnetId,ParameterValue=subnet-xxx
```

---

## Verify ALL GREEN

When the pipeline finishes, **site 0** writes SSM `/nested-virt/lab/verification` with `"status": "GREEN"`.

```bash
aws ssm get-parameter --name /nested-virt/lab/verification \
  --region YOUR_REGION --query Parameter.Value --output text | python3 -m json.tool
```

Also written to S3 (stack bootstrap bucket), per-site SSM parameters, and CloudWatch metric `NestedVirt/LabVerification`. Set `RootNotifyEmail` for an SNS alert when GREEN.

### Stale SSM after redeploy

The verification parameter is **not** deleted when the stack is torn down. After a redeploy, confirm `instance_id` values in the JSON match your new stack before trusting GREEN.

If you cloned the repo:

```bash
./bin/check-lab-status.sh       # exit 0 = GREEN matching live stack; 2 = stale or still running
./bin/monitor-lab-until-green.sh   # poll until GREEN or RED
```

Poll manually until the record appears:

```bash
until status=$(aws ssm get-parameter --name /nested-virt/lab/verification \
  --region YOUR_REGION --query Parameter.Value --output text 2>/dev/null); do
  echo "$(date -u +%H:%M:%S) waiting..."
  sleep 300
done
echo "$status" | python3 -m json.tool
```

---

## What happens inside the stack

```
nested-virt-lab.yaml
  ├── LabBootstrapBucket
  ├── ScriptSeed (Lambda) → runtime scripts in bucket
  ├── Site0Stack → metal host AZ-a
  └── Site1Stack → metal host AZ-b

Each metal host:
  bootstrap → prefetch Win2022.iso + virtio-win.iso
          → lab pipeline (DNS/VNC checks, Windows L1, Hyper-V L2, internet, verification)
          → SSM/S3 GREEN or RED
```

---

## Teardown

**Cost note:** Metal and orphaned EBS bill while stacks exist - and sometimes after delete. See [COST-POSTMORTEM.md](COST-POSTMORTEM.md) for unit economics and post-teardown volume checks.

**Cloned repo (recommended):** deletes stack, dev site stacks, lab SSM under `/nested-virt/`, and sweeps tagged orphans (EBS, ENI, log groups):

```bash
./bin/teardown-lab.sh
```

This removes **stack-managed resources** plus anything tagged `Project=nested-virt`, `NestedVirt=lab`, `NestedVirtManaged=lab`, or `aws:cloudformation:stack-name` starting with `nested-virt`. EBS volumes inherit lab tags at launch (`PropagateTagsToVolumeOnCreation`) and bootstrap re-applies tags on first boot. It does **not** delete your shared `nested-virt-bootstrap-*` script bucket or VPC/subnets you pass as parameters.

**Console / CLI only:**

```bash
aws cloudformation delete-stack --stack-name nested-virt-lab
aws cloudformation wait stack-delete-complete --stack-name nested-virt-lab
./bin/clean-lab-ssm.sh
./bin/sweep-lab-orphans.sh
```

---

## Full GREEN proof run

For a clean submission demo (no stale SSM from a prior deploy):

```bash
# 1. Tear down stack and wipe lab verification SSM
./bin/teardown-lab.sh

# 2. Confirm SSM is gone (should error or ParameterNotFound)
aws ssm get-parameter --name /nested-virt/lab/verification --region YOUR_REGION 2>&1 || true

# 3. Deploy (console upload or CLI via S3 - see Steps above)
# 4. Poll until definitive GREEN (rejects stale SSM automatically)
./bin/monitor-lab-until-green.sh

# 5. Proof artifact
./bin/check-lab-status.sh
aws ssm get-parameter --name /nested-virt/lab/verification \
  --region YOUR_REGION --query Parameter.Value --output text | python3 -m json.tool
```

`check-lab-status.sh` exit **0** only when `"status": "GREEN"` **and** `instance_id` values match the live `nested-virt-lab` stack.

---

## Maintainer notes

- Regenerate drop-in template after script changes: `python3 cloudformation/build-drop-in-template.py`
- In-repo development (per-site stacks, `go.sh`): [BUILD.md](BUILD.md)
- **CSE / security scan:** `./scripts/security-scan.sh` and [SECURITY-EXCEPTIONS.md](SECURITY-EXCEPTIONS.md#cse--security-scan-handoff)
