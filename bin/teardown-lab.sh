#!/usr/bin/env bash
# Teardown drop-in nested-virt-lab stack + empty bootstrap bucket + clean lab SSM.
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
[[ -f "${ROOT}/config.env" ]] && source "${ROOT}/config.env"

REGION="${AWS_REGION:-us-east-1}"
STACK="${LAB_STACK_NAME:-nested-virt-lab}"

unlock_stack() {
  local name="$1" iids iid
  iids=$(aws cloudformation describe-stack-resources --stack-name "$name" --region "$REGION" \
    --query 'StackResources[?ResourceType==`AWS::EC2::Instance`].PhysicalResourceId' --output text 2>/dev/null || true)
  for iid in $iids; do
    if [[ -z "$iid" || "$iid" == "None" ]]; then continue; fi
    aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$iid" \
      --no-disable-api-termination 2>/dev/null || true
  done
}

empty_bootstrap_bucket() {
  local bucket
  bucket=$(aws cloudformation describe-stack-resources --stack-name "$STACK" --region "$REGION" \
    --query 'StackResources[?LogicalResourceId==`LabBootstrapBucket`].PhysicalResourceId' --output text 2>/dev/null || true)
  if [[ -z "$bucket" || "$bucket" == "None" ]]; then return 0; fi
  echo "Emptying s3://${bucket}/ ..."
  aws s3 rm "s3://${bucket}" --recursive --region "$REGION" || true
}

delete_stack() {
  if ! aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" >/dev/null 2>&1; then
    echo "Stack ${STACK} not found."
    return 0
  fi
  local st
  st=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text)
  if [[ "$st" == "DELETE_COMPLETE" ]]; then return 0; fi

  echo "Teardown ${STACK} (${st})..."
  unlock_stack "$STACK"
  for nested in $(aws cloudformation list-stack-resources --stack-name "$STACK" --region "$REGION" \
    --query 'StackResourceSummaries[?ResourceType==`AWS::CloudFormation::Stack`].PhysicalResourceId' \
    --output text 2>/dev/null); do
    if [[ -n "$nested" && "$nested" != "None" ]]; then unlock_stack "$nested"; fi
  done

  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
  if ! aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null; then
    echo "Delete stalled — emptying bootstrap bucket and retrying..."
    empty_bootstrap_bucket
    aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
    aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" || {
      echo "Stack delete still failed — check CloudFormation console." >&2
      exit 1
    }
  fi
  echo "Stack ${STACK} deleted."
}

"${BIN}/go.sh" --teardown 2>/dev/null || true
delete_stack
"${BIN}/clean-lab-ssm.sh"
echo "Lab teardown complete (stack + SSM)."
