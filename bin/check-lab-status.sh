#!/usr/bin/env bash
# Read definitive lab verification (SSM + optional S3). Exit 0 only when status is GREEN
# and site instance_ids match the live nested-virt-lab stack (rejects stale SSM after teardown).
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
[[ -f "${ROOT}/config.env" ]] && source "${ROOT}/config.env"

REGION="${AWS_REGION:-us-east-1}"
PARAM="${LAB_VERIFICATION_PARAM:-/nested-virt/lab/verification}"
STACK="${LAB_STACK_NAME:-nested-virt-lab}"

json="$(aws ssm get-parameter --region "$REGION" --name "$PARAM" \
  --query Parameter.Value --output text 2>/dev/null || true)"

if [[ -z "$json" || "$json" == "None" ]]; then
  bucket=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='BootstrapBucket'].OutputValue" --output text 2>/dev/null || true)
  if [[ -n "$bucket" && "$bucket" != "None" ]]; then
    json=$(aws s3 cp "s3://${bucket}/nested-virt/lab-verification/lab.json" - --region "$REGION" 2>/dev/null || true)
  fi
fi

if [[ -z "$json" ]]; then
  echo "LAB STATUS: UNKNOWN (no verification record — pipeline may still be running)"
  exit 2
fi

# Reject stale GREEN from a prior stack (SSM param survives teardown).
stack_ids=""
if aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" >/dev/null 2>&1; then
  stack_ids=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?ends_with(OutputKey, `InstanceId`)].OutputValue' --output text 2>/dev/null | tr '\t' ' ')
fi
if [[ -n "$stack_ids" && "$stack_ids" != "None" ]]; then
  stale=$(echo "$json" | STACK_IDS="$stack_ids" python3 -c "
import json, os, sys
data = json.load(sys.stdin)
expected = set(os.environ.get('STACK_IDS', '').split())
if not expected:
    sys.exit(0)
found = {s.get('instance_id') for s in data.get('sites', []) if s.get('instance_id')}
if data.get('status') == 'GREEN' and found and not found.issubset(expected):
    print('stale')
" 2>/dev/null || true)
  if [[ "$stale" == stale ]]; then
    echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"
    echo ""
    echo "LAB STATUS: UNKNOWN (stale verification — instance IDs do not match stack ${STACK})"
    exit 2
  fi
fi

echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"
status=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','UNKNOWN'))")

echo ""
echo "LAB STATUS: ${status}"

if [[ "$status" == GREEN ]]; then
  exit 0
fi
exit 1
