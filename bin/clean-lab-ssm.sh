#!/usr/bin/env bash
# Delete lab verification SSM parameters (survive stack teardown — cause stale GREEN).
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
[[ -f "${ROOT}/config.env" ]] && source "${ROOT}/config.env"

REGION="${AWS_REGION:-us-east-1}"
PREFIX="${LAB_SSM_PREFIX:-/nested-virt/lab}"

PARAMS=(
  "${PREFIX}/verification"
  "${PREFIX}/site-0/verification"
  "${PREFIX}/site-1/verification"
)

deleted=0
for param in "${PARAMS[@]}"; do
  if aws ssm get-parameter --region "$REGION" --name "$param" >/dev/null 2>&1; then
    echo "Deleting SSM ${param}..."
    aws ssm delete-parameter --region "$REGION" --name "$param"
    deleted=$((deleted + 1))
  else
    echo "SSM ${param} — not present (ok)"
  fi
done

# Any other params under /nested-virt/lab/ (future-proof)
while IFS= read -r extra; do
  if [[ -z "$extra" ]]; then continue; fi
  case " ${PARAMS[*]} " in *" ${extra} "*) continue ;; esac
  echo "Deleting SSM ${extra}..."
  aws ssm delete-parameter --region "$REGION" --name "$extra"
  deleted=$((deleted + 1))
done < <(aws ssm get-parameters-by-path --region "$REGION" --path "${PREFIX}/" --recursive \
  --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n')

echo "SSM cleanup done (${deleted} deleted)."
