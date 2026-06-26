#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

SITE_ID="${SITE_ID:-0}"
ENV_FILE="${ROOT}/.last-stack-site${SITE_ID}.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${INSTANCE_ID:?Set INSTANCE_ID or deploy via run-site.sh}"

INTERVAL="${INTERVAL:-60}"
ONCE="${ONCE:-0}"

fetch_log() {
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["if [ -f /var/log/amazon/launch-timing.log ]; then cat /var/log/amazon/launch-timing.log; else echo \"(no timing log yet)\"; fi"]' \
    --query Command.CommandId --output text)
  sleep 8
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text 2>/dev/null || echo ""
}

echo "Polling site ${SITE_ID} instance ${INSTANCE_ID} every ${INTERVAL}s"

while true; do
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  out=$(fetch_log)
  echo "$out"
  if echo "$out" | grep -q 'PHASE=BOOTSTRAP finished'; then
    echo "Done — bootstrap complete."
    exit 0
  fi
  [[ "$ONCE" == "1" ]] && exit 0
  sleep "$INTERVAL"
done
