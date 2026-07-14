#!/usr/bin/env bash
# Delete all SSM parameters under /nested-virt/ (lab verification + per-site cwagent paths).
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
[[ -f "${ROOT}/config.env" ]] && source "${ROOT}/config.env"

REGION="${AWS_REGION:-us-east-1}"
ROOT_PREFIX="${NESTED_VIRT_SSM_ROOT:-/nested-virt}"

deleted=0
token=""
while true; do
  args=(aws ssm get-parameters-by-path --region "$REGION" --path "$ROOT_PREFIX" --recursive --output json)
  [[ -n "$token" ]] && args+=(--next-token "$token")
  json=$("${args[@]}" 2>/dev/null || echo '{"Parameters":[]}')
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    echo "Deleting SSM ${name}..."
    aws ssm delete-parameter --region "$REGION" --name "$name"
    deleted=$((deleted + 1))
  done < <(python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(p['Name'] for p in d.get('Parameters',[])))" <<<"$json")
  token=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('NextToken') or '')" <<<"$json")
  [[ -n "$token" ]] || break
done

echo "SSM cleanup done (${deleted} deleted under ${ROOT_PREFIX}/)."
