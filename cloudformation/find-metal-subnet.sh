#!/usr/bin/env bash
# Metal capacity helper for Amazon Linux 2023.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

MODE="${1:-}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export VPC_ID="${VPC_ID:?}"
export INSTANCE_TYPE="${INSTANCE_TYPE:-c7i.metal-48xl}"
export PREFERRED_SUBNET_ID="${PRIVATE_SUBNET_ID:-}"
export TARGET_AVAILABILITY_ZONE="${TARGET_AVAILABILITY_ZONE:-${AVAILABILITY_ZONE:-}}"

python3 <<PY
import json, os, subprocess, sys

mode = "${MODE}"
region = os.environ["AWS_REGION"]
vpc = os.environ["VPC_ID"]
itype = os.environ["INSTANCE_TYPE"]

az_rank = {az: i for i, az in enumerate(
    ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1f", "us-east-1d", "us-east-1e"]
)}

def aws(*args):
    return subprocess.check_output(["aws", *args, "--region", region, "--output", "json"], text=True)

ami = json.loads(
    aws("ssm", "get-parameter", "--name",
        "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64")
)["Parameter"]["Value"]

offered_az = {
    o["Location"]
    for o in json.loads(
        aws("ec2", "describe-instance-type-offerings", "--location-type", "availability-zone",
            "--filters", f"Name=instance-type,Values={itype}")
    )["InstanceTypeOfferings"]
}

want_az = os.environ.get("TARGET_AVAILABILITY_ZONE", "").strip()

subnets = json.loads(aws("ec2", "describe-subnets", "--filters", f"Name=vpc-id,Values={vpc}"))["Subnets"]
candidates = []
for s in subnets:
    az = s["AvailabilityZone"]
    if want_az and az != want_az:
        continue
    if az not in offered_az:
        continue
    tags = {t["Key"]: t["Value"] for t in s.get("Tags", [])}
    if tags.get("Purpose") == "Hyper-V-host-NICs-no-internet":
        continue
    if (tags.get("Name") or "").startswith("win-metal-hv-nic-"):
        continue
    if (tags.get("Name") or "").startswith("linux-metal-kvm-nic-"):
        continue
    if tags.get("Project") == "nested-virt":
        continue
    sid = s["SubnetId"]
    rank = az_rank.get(az, 99)
    deprioritize = 1 if az == "us-east-1d" else 0
    candidates.append((deprioritize, rank, az, sid, s.get("MapPublicIpOnLaunch", False)))

candidates.sort()
if not candidates:
    print("ERROR: no subnets in VPC offer", itype, file=sys.stderr)
    sys.exit(1)

def dry_run_ok(sid: str) -> bool:
    cmd = [
        "aws", "ec2", "run-instances", "--region", region,
        "--dry-run", "--image-id", ami, "--instance-type", itype,
        "--subnet-id", sid, "--count", "1",
        "--metadata-options", "HttpTokens=required,HttpEndpoint=enabled",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = (r.stdout or "") + (r.stderr or "")
    return "DryRunOperation" in out

if mode == "--list-ordered":
    for _, _, az, sid, pub in candidates:
        print(f"{sid} {az} public={pub}")
    sys.exit(0)

print(f"Probing {len(candidates)} subnet(s) for {itype} capacity (dry-run)...", file=sys.stderr)
for _, _, az, sid, pub in candidates:
    if dry_run_ok(sid):
        print(f"SUBNET_ID={sid}")
        print(f"AZ={az}")
        print(f"MapPublicIpOnLaunch={pub}")
        print(f"OK dry-run passed subnet={sid} az={az}", file=sys.stderr)
        sys.exit(0)
    print(f"skip {sid} ({az}): insufficient capacity (dry-run)", file=sys.stderr)

print("ERROR: no subnet with metal capacity in this VPC", file=sys.stderr)
sys.exit(1)
PY
