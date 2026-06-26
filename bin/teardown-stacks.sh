#!/usr/bin/env bash
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

REGION="${AWS_REGION:-us-east-1}"

delete_stack() {
  local name="$1"
  if aws cloudformation describe-stacks --stack-name "$name" --region "$REGION" >/dev/null 2>&1; then
    echo "Deleting stack ${name}..."
    aws cloudformation delete-stack --stack-name "$name" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$name" --region "$REGION" || true
  fi
}

for f in "${ROOT}"/.last-stack-site*.env; do
  [[ -f "$f" ]] || continue
  # shellcheck source=/dev/null
  source "$f"
  delete_stack "${STACK_NAME}"
done

for base in nested-virt-s0 nested-virt-s1; do
  stacks=$(aws cloudformation list-stacks --region "$REGION" --output json | python3 -c "
import json, sys
base = sys.argv[1]
for s in json.load(sys.stdin).get('StackSummaries', []):
    n = s.get('StackName', '')
    st = s.get('StackStatus', '')
    if n.startswith(base + '-') and st != 'DELETE_COMPLETE':
        print(n)
" "$base")
  while IFS= read -r s; do
    [[ -n "$s" ]] && delete_stack "$s"
  done <<< "$stacks"
done

echo "Teardown complete."
