#!/usr/bin/env bash
# Ensure private subnet for KVM host ENIs (reuses win-metal-hv-nic-* from Windows project when present).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

AZ="${1:?Usage: ensure-kvm-nic-subnet.sh <availability-zone>}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export VPC_ID="${VPC_ID:?}"
export AVAILABILITY_ZONE="${AZ}"
export TAG_PREFIX="${KVM_NIC_SUBNET_TAG_PREFIX:-win-metal-hv-nic}"

python3 <<'PY'
import json, os, subprocess, sys

region = os.environ["AWS_REGION"]
vpc = os.environ["VPC_ID"]
az = os.environ["AVAILABILITY_ZONE"]
tag_name = f"{os.environ['TAG_PREFIX']}-{az}"

cidrs_json = os.environ.get("KVM_NIC_SUBNET_CIDRS", "").strip()
if cidrs_json:
    az_cidrs = json.loads(cidrs_json)
else:
    az_cidrs = {}

def aws(*args):
    return subprocess.check_output(["aws", *args, "--region", region, "--output", "json"], text=True)

def aws_text(*args):
    return subprocess.check_output(["aws", *args, "--region", region, "--output", "text"], text=True)

subnets = json.loads(aws("ec2", "describe-subnets", "--filters", f"Name=vpc-id,Values={vpc}"))["Subnets"]
for s in subnets:
    tags = {t["Key"]: t["Value"] for t in s.get("Tags", [])}
    if tags.get("Name") == tag_name and s["AvailabilityZone"] == az:
        sid = s["SubnetId"]
        print(sid)
        print(f"KVM NIC subnet exists {sid} az={az} cidr={s['CidrBlock']}", file=sys.stderr)
        sys.exit(0)

if az not in az_cidrs:
    print(
        f"ERROR: no KVM NIC subnet for {az}. Pre-create subnet tagged Name={tag_name} "
        f"or set KVM_NIC_SUBNET_CIDRS in config.env (JSON map).",
        file=sys.stderr,
    )
    sys.exit(1)
want_cidr = az_cidrs[az]

for s in subnets:
    if s["CidrBlock"] == want_cidr:
        print(f"ERROR: CIDR {want_cidr} already used by {s['SubnetId']} without tag {tag_name}", file=sys.stderr)
        sys.exit(1)

rt_id = json.loads(
    aws("ec2", "create-route-table", "--vpc-id", vpc,
        "--tag-specifications",
        f"ResourceType=route-table,Tags=[{{Key=Name,Value={tag_name}-rt}}]")
)["RouteTable"]["RouteTableId"]

subnet_id = json.loads(
    aws("ec2", "create-subnet", "--vpc-id", vpc, "--availability-zone", az,
        "--cidr-block", want_cidr,
        "--tag-specifications",
        f"ResourceType=subnet,Tags=[{{Key=Name,Value={tag_name}}},{{Key=Purpose,Value=Hyper-V-host-NICs-no-internet}}]")
)["Subnet"]["SubnetId"]

aws_text("ec2", "modify-subnet-attribute", "--subnet-id", subnet_id, "--no-map-public-ip-on-launch")
aws_text("ec2", "associate-route-table", "--route-table-id", rt_id, "--subnet-id", subnet_id)
print(subnet_id)
print(f"Created KVM NIC subnet {subnet_id} az={az} cidr={want_cidr}", file=sys.stderr)
PY
