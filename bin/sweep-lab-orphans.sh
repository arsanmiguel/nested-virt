#!/usr/bin/env bash
# Delete nested-virt lab resources that can survive CloudFormation stack delete.
# Safe to run after teardown-lab.sh or go.sh --teardown.
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
[[ -f "${ROOT}/config.env" ]] && source "${ROOT}/config.env"

REGION="${AWS_REGION:-us-east-1}"
PROJECT_TAG="${NESTED_VIRT_PROJECT_TAG:-nested-virt}"
export AWS_REGION="$REGION"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

tagged_nested_virt() {
  local arn="$1"
  python3 - "$arn" "$PROJECT_TAG" <<'PY'
import json, subprocess, sys
arn, project = sys.argv[1], sys.argv[2]
region = __import__("os").environ.get("AWS_REGION", "us-east-1")
out = subprocess.check_output(
    ["aws", "ec2", "describe-tags", "--region", region,
     "--filters", f"Name=resource-id,Values={arn}", "--output", "json"],
    text=True,
)
tags = {t["Key"]: t["Value"] for t in json.loads(out).get("Tags", [])}
stack = tags.get("aws:cloudformation:stack-name", "")
if tags.get("Project") == project or tags.get("NestedVirtManaged") == "lab":
    sys.exit(0)
if tags.get("NestedVirt") == "lab":
    sys.exit(0)
if stack.startswith("nested-virt"):
    sys.exit(0)
sys.exit(1)
PY
}

delete_available_volumes() {
  local id deleted=0 failed=0
  log "sweep orphan EBS volumes (Project=${PROJECT_TAG}, NestedVirt=lab, or nested-virt stack tag)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if tagged_nested_virt "$id"; then
      log "delete volume ${id}"
      if aws ec2 delete-volume --region "$REGION" --volume-id "$id" 2>/dev/null; then
        deleted=$((deleted + 1))
      else
        failed=$((failed + 1))
        log "WARN failed volume ${id}"
      fi
    fi
  done < <(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text | tr '\t' '\n')
  log "volumes deleted=${deleted} failed=${failed}"
}

delete_available_enis() {
  local id deleted=0
  log "sweep orphan ENIs"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if tagged_nested_virt "$id"; then
      log "delete eni ${id}"
      aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$id" 2>/dev/null && \
        deleted=$((deleted + 1)) || log "WARN failed eni ${id}"
    fi
  done < <(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text | tr '\t' '\n')
  log "enis deleted=${deleted}"
}

delete_lab_snapshots() {
  local id deleted=0
  log "sweep EBS snapshots"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if tagged_nested_virt "$id"; then
      log "delete snapshot ${id}"
      aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$id" 2>/dev/null && \
        deleted=$((deleted + 1)) || log "WARN failed snapshot ${id}"
    fi
  done < <(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
    --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' '\n')
  log "snapshots deleted=${deleted}"
}

delete_log_groups() {
  local name deleted=0
  log "sweep CloudWatch log groups /nested-virt/*"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    log "delete log group ${name}"
    aws logs delete-log-group --region "$REGION" --log-group-name "$name" 2>/dev/null && \
      deleted=$((deleted + 1)) || log "WARN failed log group ${name}"
  done < <(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix /nested-virt/ \
    --query 'logGroups[].logGroupName' --output text 2>/dev/null | tr '\t' '\n')
  log "log groups deleted=${deleted}"
}

delete_stale_cfn_stacks() {
  local name st deleted=0
  log "sweep nested-virt CFN stacks not DELETE_COMPLETE"
  while IFS=$'\t' read -r name st; do
    [[ -n "$name" ]] || continue
    [[ "$st" == "DELETE_COMPLETE" ]] && continue
    log "delete stack ${name} (${st})"
    aws cloudformation delete-stack --region "$REGION" --stack-name "$name" 2>/dev/null && \
      deleted=$((deleted + 1)) || log "WARN failed stack ${name}"
  done < <(aws cloudformation list-stacks --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE ROLLBACK_FAILED \
      CREATE_FAILED UPDATE_ROLLBACK_COMPLETE DELETE_FAILED REVIEW_IN_PROGRESS \
    --query 'StackSummaries[?starts_with(StackName, `nested-virt`)]. [StackName, StackStatus]' \
    --output text 2>/dev/null)
  log "stacks delete requested=${deleted}"
}

main() {
  delete_stale_cfn_stacks
  delete_available_volumes
  delete_available_enis
  delete_lab_snapshots
  delete_log_groups
  log "orphan sweep complete"
}

main "$@"
